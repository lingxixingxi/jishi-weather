/// 密钥配置模板 —— 复制本文件为 `secrets.dart` 并填入自己的 Key
///
/// 高德 Key 申请：https://lbs.amap.com/ （控制台 → 应用管理 → 创建应用 → 添加 Key）
/// 需要创建**两个** Key：
///   1. 服务平台选「Web服务」→ 填到 amapWebKey
///   2. 服务平台选「Android 平台」→ 填到 amapAndroidKey（同时填 android/key.properties）
///
/// Android 平台 Key 申请时需要：
///   PackageName: com.lingxi.jishiweather
///   SHA1: 用 keytool 获取（见 README）
///
/// 和风天气 Key 申请：https://dev.qweather.com/
/// ⚠️ 2024 改版后必须使用**专属 API Host**（控制台 → 设置），
///    通用域名 devapi/api.qweather.com 已停用。留空则跳过该数据源。
class Secrets {
  Secrets._();

  /// 高德 Web服务 Key
  static const String amapWebKey = '';

  /// 高德 Android 平台 Key
  static const String amapAndroidKey = '';

  /// 和风天气 API Key
  static const String qweatherApiKey = '';

  /// 和风天气专属 API Host（形如 abcdefg.re.qweatherapi.com）
  static const String qweatherApiHost = '';
}
