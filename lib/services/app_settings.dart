import 'package:shared_preferences/shared_preferences.dart';

/// App 设置（本地持久化）
///
/// 目前包含两类：
/// · **提醒开关**：每小时天气变化提醒、每日次日预报推送
/// · **API Key**：为将来公测版预留（当前内测版的 key 编译进包内，
///   公测若要换成用户自填，直接读这里即可）
class AppSettings {
  AppSettings._();

  static const _kHourlyAlert = 'alert_hourly_enabled';
  static const _kDailyAlert = 'alert_daily_enabled';
  static const _kAlertLocation = 'alert_location'; // 提醒用的定位（省得每次重新定位）
  // 公测版让用户自填的 Key（内测版留空即可，会回退到包内 Secrets）
  static const _kAmapWebKey = 'api_key_amap_web';
  static const _kAmapAndroidKey = 'api_key_amap_android';
  static const _kQweatherKey = 'api_key_qweather';
  static const _kQweatherHost = 'api_key_qweather_host';
  static const _kLastHourlyCheck = 'alert_last_hourly_check';
  static const _kLastDailyPush = 'alert_last_daily_push';
  static const _kLastSnapshot = 'alert_last_snapshot';

  // ==================== 提醒开关 ====================

  /// 每小时天气变化提醒
  static Future<bool> hourlyAlertEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kHourlyAlert) ?? false; // 默认关闭，由用户主动开启
  }

  static Future<void> setHourlyAlert(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kHourlyAlert, v);
  }

  /// 每日次日天气推送（约 24:00）
  static Future<bool> dailyAlertEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kDailyAlert) ?? false;
  }

  static Future<void> setDailyAlert(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDailyAlert, v);
  }

  // ==================== 提醒用的地点 ====================

  /// 提醒关联的地点（"lat,lon" 与显示名）
  static Future<({double lat, double lon, String name})?> alertLocation() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kAlertLocation);
    if (raw == null) return null;
    final parts = raw.split('|');
    if (parts.length < 3) return null;
    final lat = double.tryParse(parts[0]);
    final lon = double.tryParse(parts[1]);
    if (lat == null || lon == null) return null;
    return (lat: lat, lon: lon, name: parts[2]);
  }

  static Future<void> setAlertLocation(double lat, double lon, String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAlertLocation, '$lat|$lon|$name');
  }

  // ==================== API Key（公测版让用户自填）====================
  //
  // 内测版这里留空即可 —— 读取时会回退到编译进包的 Secrets（见 ApiKeys）。
  // 公测版包里不带 Key，必须用户自己填，否则地理编码 / 路线规划不可用。

  /// 高德 **Web服务** Key（地理编码、驾车路线规划、静态地图）
  static Future<String> amapWebKey() => _getStr(_kAmapWebKey);

  static Future<void> setAmapWebKey(String v) => _setStr(_kAmapWebKey, v);

  /// 高德 **Android 平台** Key（地图 SDK + 定位 SDK 共用）
  ///
  /// 与 Web服务 Key 不同，这个 Key 绑定「包名 + 签名 SHA1」—— 用户要自填，
  /// 须先去高德控制台创建一个**绑定本 App 包名与签名**的 Key
  /// （包名与 SHA1 在设置页可直接复制）。留空则用内置的。
  static Future<String> amapAndroidKey() => _getStr(_kAmapAndroidKey);

  static Future<void> setAmapAndroidKey(String v) =>
      _setStr(_kAmapAndroidKey, v);

  /// 和风天气 API Key（可选数据源，留空自动跳过）
  static Future<String> qweatherApiKey() => _getStr(_kQweatherKey);
  static Future<void> setQweatherApiKey(String v) => _setStr(_kQweatherKey, v);

  /// 和风天气专属 API Host（形如 `abc.re.qweatherapi.com`）
  static Future<String> qweatherApiHost() => _getStr(_kQweatherHost);

  static Future<void> setQweatherApiHost(String v) => _setStr(_kQweatherHost, v);

  static Future<String> _getStr(String key) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(key) ?? '';
  }

  static Future<void> _setStr(String key, String v) async {
    final p = await SharedPreferences.getInstance();
    if (v.trim().isEmpty) {
      await p.remove(key);
    } else {
      await p.setString(key, v.trim());
    }
  }

  // ==================== 调度用时间戳 ====================

  static Future<DateTime?> lastHourlyCheck() => _getTime(_kLastHourlyCheck);

  static Future<void> setLastHourlyCheck(DateTime t) => _setTime(_kLastHourlyCheck, t);

  static Future<DateTime?> lastDailyPush() => _getTime(_kLastDailyPush);

  static Future<void> setLastDailyPush(DateTime t) => _setTime(_kLastDailyPush, t);

  /// 上一次的天气快照（用于比对「有没有变化」）
  static Future<String?> lastSnapshot() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kLastSnapshot);
  }

  static Future<void> setLastSnapshot(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLastSnapshot, v);
  }

  static Future<DateTime?> _getTime(String key) async {
    final p = await SharedPreferences.getInstance();
    final ms = p.getInt(key);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> _setTime(String key, DateTime t) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(key, t.millisecondsSinceEpoch);
  }
}
