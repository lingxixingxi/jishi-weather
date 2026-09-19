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
class Secrets {
  Secrets._();

  /// 高德 Web服务 Key
  static const String amapWebKey = '';

  /// 高德 Android 平台 Key
  static const String amapAndroidKey = '';
}
