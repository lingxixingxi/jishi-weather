/// App 身份信息 —— 用户申请自己的高德 Key 时需要用到
///
/// 高德 **Android 平台** Key 绑定「包名 + 签名 SHA1」，所以用户要自填 Key，
/// 必须先去高德控制台创建一个**绑定下面这两项**的 Key。
///
/// 这两个值都**不是秘密** —— 任何人都能从发布的 APK 里读出来 —— 但必须
/// 一字不差，否则地图会报 `INVALID_USER_SCODE` 白屏。
class AppIdentity {
  AppIdentity._();

  /// 应用版本号（**不含** `+build` 部分）
  ///
  /// ⚠️ 必须与 `pubspec.yaml` 的 `version:` 保持一致 ——
  /// `_research/pack_dist.py` 打包时会强制校验：
  /// pubspec / 这里 / 脚本自己的 VERSION，三处不一致直接报错退出。
  ///
  /// 首页徽章与日志导出头部都读这个常量，不再各处硬编码。
  static const String appVersion = '0.2.0';

  /// Android 包名（`build.gradle.kts` 的 applicationId）
  static const String packageName = 'com.lingxi.jishiweather';

  /// **发布签名**的 SHA1 指纹（release.keystore）
  ///
  /// 提取方式（2026-10-01 实测）：
  /// ```
  /// apksigner verify --print-certs <apk> | findstr SHA-1
  /// ```
  /// ⚠️ **不能用 `keytool -printcert -jarfile`** —— 现代 APK 只做 v2/v3
  /// 签名，而 keytool 只认 v1 的 JAR 签名，会报「不是签名的 jar 文件」。
  ///
  /// ⚠️ **调试签名的 SHA1 与此不同**（Android Studio 的 debug.keystore）。
  /// 用户拿到的是发布包，所以填这个。
  static const String sha1 = 'AC:6F:15:89:73:1B:0B:94:EA:80:3D:4C:ED:19:74:7D:9C:8C:0E:19';

  /// 无冒号小写版本（部分工具/文档要这个格式）
  static const String sha1Plain = 'ac6f1589731b0b94ea803d4ced19747d9c8c0e19';

  /// 证书主体（供核对）
  static const String certDn = 'CN=Jishi Weather, O=Lingxi, C=CN';

  /// 问题反馈邮箱（设置页「问题反馈」卡片里的收件地址）
  static const String feedbackEmail = '1017288764@qq.com';
}
