import 'dart:async';

import 'package:amap_flutter_location/amap_flutter_location.dart';
import 'package:amap_flutter_location/amap_location_option.dart';
import 'package:flutter/foundation.dart';

import 'api_keys.dart';
import 'location_budget.dart';
import 'amap_service.dart' show GeoPoint;

/// 高德定位服务
///
/// 相比 geolocator（依赖 Google Location Service，小米等国内设备常失败），
/// 高德定位走**基站 + WiFi + GPS 混合定位**，把周边 WiFi/基站指纹发到高德服务端匹配，
/// 室内也能定位，WiFi 场景精度可达十几米~几十米（微信/QQ 同款原理）。
///
/// ## ⚡ 共享缓存与并发去重（2026-09-26 加）
///
/// 五个页面（地点 / 路线 / 台风 / 摄影 / 设置）都会在 `initState` 里
/// 「预热定位」，各自直接调用本方法 —— 实测**一次冷启动并发发起 4 次定位**
/// （logcat 里同一毫秒出现 4 条「开始定位」），纯属浪费电量与流量。
///
/// 现在两层收敛：
/// 1. **结果缓存**：[cacheTtl] 内直接复用上次结果，不再重新定位；
/// 2. **并发去重**：已有定位在飞时，后续调用**共享同一个 Future**，
///    不会各发一次（缓存为空时的启动瞬间正是这种情况）。
///
/// 用户**主动**点「当前位置 / 用当前位置」时应传 `forceRefresh: true`
/// （跳过缓存、单独发起），这是用户明确要求重新定位的场景。
class AmapLocationService {
  static bool _keyInitialized = false;

  /// 最近一次成功定位的结果与时刻（各页面共享）
  static GeoPoint? _cached;
  static DateTime? _cachedAt;

  /// 进行中的定位请求 —— 供并发调用共享
  static Future<GeoPoint?>? _inflight;

  /// 缓存有效期
  ///
  /// 3 分钟足够覆盖「在一个页面里来回切」的典型用法，
  /// 又不会让用户在一个地方停留很久后拿到明显过期的位置。
  static const Duration cacheTtl = Duration(minutes: 3);

  /// 清空缓存（换城市、或需要强制重取的场景）
  static void clearCache() {
    _cached = null;
    _cachedAt = null;
  }

  /// 单次定位，带超时
  ///
  /// [forceRefresh] 为 true 时忽略缓存与进行中的请求，单独发起一次定位 ——
  /// 用户点「用当前位置」这类明确要求重新定位的入口应传 true。
  ///
  /// ⚠️ 多个并发调用若共享同一次定位，**以最先发起者的 timeout 为准**；
  /// 超时只是保护性上限，不影响正常路径。
  static Future<GeoPoint?> locate({
    Duration timeout = const Duration(seconds: 15),
    bool forceRefresh = false,
  }) {
    if (!forceRefresh) {
      final c = _cached;
      final at = _cachedAt;
      if (c != null && at != null) {
        final age = DateTime.now().difference(at);
        if (age < cacheTtl) {
          debugPrint('[高德定位] 复用缓存（${age.inSeconds}s 前）');
          return Future.value(c);
        }
      }
      final flying = _inflight;
      if (flying != null) {
        debugPrint('[高德定位] 复用进行中的定位请求');
        // 复用别人的请求，**失败就是失败** —— 不再各自重试。
        //
        // 曾经在这里加过「未成功则按本次 timeout 重试」，实测反而更糟：
        // 首个请求若超时，3 个复用者会同时重试，又变回 4 次并发定位
        // （日志：开始定位 5 次）。而「预热定位」失败本来就有 IP 定位兜底，
        // 用户**主动**点「当前位置」走的是 forceRefresh，单独发起、不受影响。
        return flying;
      }
    }

    late final Future<GeoPoint?> future;
    future = _locateInner(timeout: timeout).whenComplete(() {
      if (identical(_inflight, future)) _inflight = null;
    });
    if (!forceRefresh) _inflight = future;
    return future;
  }

  /// 真正发起一次高德定位
  static Future<GeoPoint?> _locateInner({required Duration timeout}) async {
    final location = AMapFlutterLocation();
    final completer = Completer<GeoPoint?>();
    StreamSubscription<Map<String, Object>>? sub;

    try {
      // ===== 内置 Key 的每日配额守卫 =====
      //
      // 高德「在线定位」是账号级共享配额，内置 Key 时全体公测用户共用一份。
      // 没有服务端做不了全局统计，但单机自我约束能挡住最危险的滥用
      // （连点 / 循环定位 / 异常重试）。用户自填了 Key 则完全不限。
      if (!await LocationBudget.canSpend()) {
        debugPrint('[高德定位] 今日内置 Key 配额已用完'
            '（${LocationBudget.dailyLimit} 次/天）→ 降级');
        // 过期缓存也比没有强 —— 位置通常还在同一城区
        final stale = _cached;
        if (stale != null) {
          debugPrint('[高德定位] 使用过期缓存位置');
          return stale;
        }
        return null; // 无缓存 → 调用方走 IP 定位兜底
      }

      // ===== 记账 =====
      //
      // ⚠️ 必须在**真正发起定位之前**调用，且**不能**只在成功回调里记 ——
      // 超时和失败的请求在高德那边同样消耗配额。
      //
      // 真机复验发现的坑（2026-10-01）：这里原本漏了 spend()，只有上面的
      // canSpend() 判断，于是「今日已用」永远是 0 → canSpend() 永远为真 →
      // 每天 20 次的上限**完全形同虚设**。界面上看着有额度面板，实际不拦。
      await LocationBudget.spend();

      if (!_keyInitialized) {
        // 高德 Key：Android 平台 Key（地图 SDK 与定位 SDK 共用同一个）
        // 用户自填的优先，否则用内置的（见 ApiKeys）
        AMapFlutterLocation.setApiKey(ApiKeys.amapAndroid, '');
        _keyInitialized = true;
      }

      debugPrint('[高德定位] 开始定位…');
      final option = AMapLocationOption()
        ..onceLocation = true // 单次定位
        ..needAddress = true // 需要逆地理地址
        ..desiredAccuracy = DesiredAccuracy.Best; // 高精度混合定位
      location.setLocationOption(option);

      sub = location.onLocationChanged().listen((result) {
        debugPrint('[高德定位] 收到结果: $result');
        final lat = (result['latitude'] as num?)?.toDouble();
        final lon = (result['longitude'] as num?)?.toDouble();
        // 高德失败时可能返回 0,0，需过滤
        if (lat != null && lon != null && lat != 0 && lon != 0) {
          if (!completer.isCompleted) {
            final city = (result['city'] as String?)?.trim();
            final district = (result['district'] as String?)?.trim();
            final name = [city, district].where((e) => e != null && e.isNotEmpty).join();
            completer.complete(GeoPoint(
              lat: lat,
              lon: lon,
              name: name.isEmpty ? '当前位置' : name,
            ));
          }
        }
      });

      location.startLocation();
      final point = await completer.future.timeout(timeout, onTimeout: () {
        debugPrint('[高德定位] 超时 ${timeout.inSeconds}s（检查 Key 是否勾选「Android定位SDK」）');
        return null;
      });
      // 只有成功结果才进缓存 —— 失败/超时不该被后续调用复用
      if (point != null) {
        _cached = point;
        _cachedAt = DateTime.now();
      }
      return point;
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
      try {
        location.stopLocation();
        location.destroy();
      } catch (_) {
        // 忽略清理异常
      }
    }
  }
}
