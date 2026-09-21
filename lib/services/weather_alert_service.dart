import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_settings.dart';
import 'open_meteo.dart';

/// 天气变化提醒 + 每日次日预报推送
///
/// 两类提醒（可在设置页开关）：
/// · **每小时变化提醒**：拉一次当前天气，与上次快照比对，有明显变化才通知
/// · **每日次日预报**：约 24:00 拉次日预报并发通知
///
/// 设计要点：
/// · 前后台共用同一套逻辑（[checkAndNotify]），前台定时器与后台任务都调它；
/// · 用「上次快照」做差分，避免每小时都轰炸用户；
/// · 通知渠道分开（变化提醒 / 每日预报），用户可以在系统里单独关掉某一类。
class WeatherAlertService {
  WeatherAlertService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static const _channelChange = 'weather_change';
  static const _channelDaily = 'weather_daily';
  static const _changeId = 1001;
  static const _dailyId = 1002;

  /// 变化判定的阈值 —— 低于这些幅度就不打扰用户
  static const double tempDeltaC = 3.0; // 温度变化 ≥3℃
  static const int popDeltaPct = 30; // 降水概率变化 ≥30%
  static const double precipDeltaMm = 0.3; // 降水量变化 ≥0.3mm

  // ==================== 初始化 ====================

  static Future<void> init() async {
    if (_inited) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    try {
      await _plugin.initialize(settings: settings);
      _inited = true;
    } catch (e) {
      debugPrint('[提醒] 通知插件初始化失败: $e');
    }
  }

  /// 请求通知权限（Android 13+ 必须）
  static Future<bool> requestPermission() async {
    await init();
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission();
      return granted ?? true;
    } catch (e) {
      debugPrint('[提醒] 请求通知权限失败: $e');
      return false;
    }
  }

  static Future<bool> hasPermission() async {
    await init();
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await android?.areNotificationsEnabled() ?? true;
    } catch (_) {
      return true;
    }
  }

  // ==================== 发通知 ====================

  static Future<void> _notify({
    required int id,
    required String channelId,
    required String channelName,
    required String title,
    required String body,
  }) async {
    await init();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(body),
      ),
    );
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
      );
      debugPrint('[提醒] 已通知：$title / $body');
    } catch (e) {
      debugPrint('[提醒] 通知失败: $e');
    }
  }

  // ==================== 核心：检查并提醒 ====================

  /// 快照：用于判断「天气有没有变化」
  static Map<String, dynamic> _snapshotOf({
    required int? weatherCode,
    required double? temp,
    required double? precip,
    required int? pop,
  }) =>
      {
        'wc': weatherCode,
        't': temp == null ? null : double.parse(temp.toStringAsFixed(1)),
        'p': precip == null ? null : double.parse(precip.toStringAsFixed(2)),
        'pop': pop,
      };

  /// 拉一次天气并视情况发通知
  ///
  /// 返回一段说明文字（供设置页展示"上次检查"的结果）。
  static Future<String> checkAndNotify({bool force = false}) async {
    final loc = await AppSettings.alertLocation();
    if (loc == null) return '尚未设置提醒地点';

    final hourlyOn = await AppSettings.hourlyAlertEnabled();
    final dailyOn = await AppSettings.dailyAlertEnabled();
    if (!hourlyOn && !dailyOn) return '提醒均已关闭';

    final now = DateTime.now();

    // ---- 每日次日预报（约 24:00；这里取 23:00 之后触发，且当天只发一次）----
    if (dailyOn) {
      final last = await AppSettings.lastDailyPush();
      final alreadyPushedToday =
          last != null && last.year == now.year && last.month == now.month && last.day == now.day;
      if (now.hour >= 23 && !alreadyPushedToday) {
        final txt = await _pushDailyForecast(loc.lat, loc.lon, loc.name);
        await AppSettings.setLastDailyPush(now);
        return txt;
      }
    }

    // ---- 每小时变化提醒 ----
    if (!hourlyOn) return '仅每日预报已开启（未到推送时间）';

    final lastCheck = await AppSettings.lastHourlyCheck();
    if (!force &&
        lastCheck != null &&
        now.difference(lastCheck).inMinutes < 55) {
      return '距上次检查不足 55 分钟，跳过';
    }

    final r = await _fetchCurrent(loc.lat, loc.lon);
    if (r == null) return '天气数据获取失败';

    final cur = _snapshotOf(
      weatherCode: r.weatherCode,
      temp: r.temp,
      precip: r.precip,
      pop: r.pop,
    );
    final lastRaw = await AppSettings.lastSnapshot();
    await AppSettings.setLastHourlyCheck(now);
    await AppSettings.setLastSnapshot(jsonEncode(cur));

    if (lastRaw == null) return '已记录基准（下次起才会比对变化）';

    Map<String, dynamic>? last;
    try {
      last = jsonDecode(lastRaw) as Map<String, dynamic>;
    } catch (_) {
      return '已更新（上次快照解析失败）';
    }

    final reasons = _diff(last, cur);
    if (reasons.isEmpty) return '天气无明显变化';

    await _notify(
      id: _changeId,
      channelId: _channelChange,
      channelName: '天气变化提醒',
      title: '${loc.name} 天气有变化',
      body: reasons.join('；'),
    );
    return '已提醒：${reasons.join('；')}';
  }

  /// 比对两次快照，返回变化描述（空 = 无值得提醒的变化）
  static List<String> _diff(Map<String, dynamic> last, Map<String, dynamic> cur) {
    final out = <String>[];

    final wcLast = last['wc'] as int?;
    final wcCur = cur['wc'] as int?;
    if (wcLast != null && wcCur != null && wcLast != wcCur) {
      out.add('天气现象 ${_wcText(wcLast)} → ${_wcText(wcCur)}');
    }

    final tLast = (last['t'] as num?)?.toDouble();
    final tCur = (cur['t'] as num?)?.toDouble();
    if (tLast != null && tCur != null && (tCur - tLast).abs() >= tempDeltaC) {
      out.add('气温 ${tLast.toStringAsFixed(0)}℃ → ${tCur.toStringAsFixed(0)}℃');
    }

    final popLast = last['pop'] as int?;
    final popCur = cur['pop'] as int?;
    if (popLast != null && popCur != null && (popCur - popLast).abs() >= popDeltaPct) {
      out.add('降水概率 $popLast% → $popCur%');
    }

    final pLast = (last['p'] as num?)?.toDouble() ?? 0;
    final pCur = (cur['p'] as num?)?.toDouble() ?? 0;
    if ((pCur - pLast).abs() >= precipDeltaMm) {
      out.add('降水 ${pLast.toStringAsFixed(1)} → ${pCur.toStringAsFixed(1)} mm/h');
    }

    return out;
  }

  // ==================== 数据获取 ====================

  static final _meteo = OpenMeteoService();

  static Future<({int? weatherCode, double? temp, double? precip, int? pop})?>
      _fetchCurrent(double lat, double lon) async {
    // 主：Open-Meteo 当前小时
    try {
      final list = await _meteo.fetchHourly(
        lat: lat,
        lon: lon,
        forecastDays: 2,
      );
      final now = DateTime.now();
      final h = _nearest(list, now);
      if (h != null) {
        return (
          weatherCode: h.weatherCode,
          temp: h.temperature,
          precip: h.precipitation,
          pop: h.precipitationProbability,
        );
      }
    } catch (e) {
      debugPrint('[提醒] Open-Meteo 获取失败: $e');
    }
    return null;
  }

  static T? _nearest<T>(List<T> list, DateTime t) {
    if (list.isEmpty) return null;
    // 依赖各 weather 类型都有 time 字段，这里用动态取
    T? best;
    var bd = 1 << 30;
    for (final e in list) {
      final time = (e as dynamic).time as DateTime?;
      if (time == null) continue;
      final d = time.difference(t).inMinutes.abs();
      if (d < bd) {
        bd = d;
        best = e;
      }
    }
    return best;
  }

  /// 次日预报推送
  static Future<String> _pushDailyForecast(double lat, double lon, String name) async {
    try {
      final daily = await _meteo.fetchDaily(
        lat: lat,
        lon: lon,
        forecastDays: 3,
      );
      if (daily.isEmpty) return '次日预报获取失败';
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final d = daily.firstWhere(
        (e) => e.date.year == tomorrow.year &&
            e.date.month == tomorrow.month &&
            e.date.day == tomorrow.day,
        orElse: () => daily.first,
      );
      final body = '${d.date.month}/${d.date.day} '
          '${d.weatherText ?? '—'} '
          '${d.tempMin?.toStringAsFixed(0) ?? '—'}~'
          '${d.tempMax?.toStringAsFixed(0) ?? '—'}℃'
          '${d.precipProbabilityMax != null ? '，降水概率 ${d.precipProbabilityMax}%' : ''}';
      await _notify(
        id: _dailyId,
        channelId: _channelDaily,
        channelName: '每日天气',
        title: '$name 明日天气',
        body: body,
      );
      return '已推送次日预报：$body';
    } catch (e) {
      debugPrint('[提醒] 次日预报失败: $e');
      return '次日预报获取失败：$e';
    }
  }

  /// WMO weather code → 中文简述（与地点页口径一致）
  static String _wcText(int code) {
    if (code == 0) return '晴';
    if (code <= 2) return '少云';
    if (code == 3) return '阴';
    if (code <= 48) return '雾';
    if (code <= 57) return '毛毛雨';
    if (code <= 67) return '雨';
    if (code <= 77) return '雪';
    if (code <= 82) return '阵雨';
    if (code <= 86) return '阵雪';
    return '雷雨';
  }

  /// 当前平台是否支持通知（桌面/测试环境直接跳过）
  static bool get supported => Platform.isAndroid || Platform.isIOS;
}
