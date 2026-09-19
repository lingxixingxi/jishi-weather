import 'dart:async';

import 'package:amap_flutter_location/amap_flutter_location.dart';
import 'package:amap_flutter_location/amap_location_option.dart';

import '../config/secrets.dart';
import 'amap_service.dart' show GeoPoint;

/// 高德定位服务
///
/// 相比 geolocator（依赖 Google Location Service，小米等国内设备常失败），
/// 高德定位走**基站 + WiFi + GPS 混合定位**，把周边 WiFi/基站指纹发到高德服务端匹配，
/// 室内也能定位，WiFi 场景精度可达十几米~几十米（微信/QQ 同款原理）。
class AmapLocationService {
  static bool _keyInitialized = false;

  /// 单次定位，带超时
  static Future<GeoPoint?> locate({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final location = AMapFlutterLocation();
    final completer = Completer<GeoPoint?>();
    StreamSubscription<Map<String, Object>>? sub;

    try {
      if (!_keyInitialized) {
        // 高德 Key：Android 平台 Key（与地图 SDK 同一个）
        AMapFlutterLocation.setApiKey(Secrets.amapAndroidKey, '');
        _keyInitialized = true;
      }

      final option = AMapLocationOption()
        ..onceLocation = true // 单次定位
        ..needAddress = true // 需要逆地理地址
        ..desiredAccuracy = DesiredAccuracy.Best; // 高精度混合定位
      location.setLocationOption(option);

      sub = location.onLocationChanged().listen((result) {
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
      return await completer.future.timeout(timeout, onTimeout: () => null);
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
