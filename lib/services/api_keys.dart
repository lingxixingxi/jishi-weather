import 'package:flutter/foundation.dart';

import '../config/secrets.dart';
import 'app_settings.dart';

/// 运行时 API Key 解析层
///
/// ## 为什么需要这一层
///
/// 项目分两条分发路线，共用同一份代码，靠编译期开关切换：
///
/// - **内测版**：Key 编译进包（[Secrets]，该文件不入库），装上即用
/// - **公测版**：包里**不带**任何 Key，由用户在设置页填自己的
///
/// ```powershell
/// flutter build apk --dart-define=INJECT_KEYS=true   # 内测版
/// flutter build apk                                   # 公测版（默认 false）
/// ```
///
/// ## 哪些 Key 能用户自填，哪些不能
///
/// | Key | 能否自填 | 原因 |
/// |---|---|---|
/// | 高德 **Web服务** Key | ✅ | 纯 HTTP GET 参数，运行时拼 URL |
/// | 和风 Key / Host | ✅ | 请求头，运行时拼 |
/// | 高德 **Android 平台** Key | ❌ | 与「包名 + 签名 SHA1」绑定，地图/定位 SDK 初始化时写死，**只能编译期注入** |
///
/// 所以公测版的**地图显示与定位**用的是发布者的 Android Key（与内测版相同），
/// 而**地理编码 / 路线规划**用用户自己的 Web服务 Key —— 后者有日配额
/// （个人开发者 5000 次/天），不能让全体公测用户共用发布者那一个。
///
/// ## 用法
///
/// App 启动时 `await ApiKeys.load()` 一次，之后各处**同步**读 getter ——
/// 服务层拼 URL 是同步的，不可能到处 await。
/// 用户在设置页改完 Key 后调 [reload] 刷新内存缓存。
class ApiKeys {
  ApiKeys._();

  /// 是否把 [Secrets] 里编译进包的 Key 当作兜底
  ///
  /// 内测版构建时 `--dart-define=INJECT_KEYS=true`；公测版默认 false。
  static const bool _injectBuiltin =
      bool.fromEnvironment('INJECT_KEYS', defaultValue: false);

  /// 当前是否为公测构建（供 UI 决定要不要提示"请填 Key"）
  static bool get isPublicBuild => !_injectBuiltin;

  static String _amapWeb = '';
  static String _amapAndroid = '';
  static String _qwKey = '';
  static String _qwHost = '';

  /// 启动时调用一次，把用户填过的 Key 读进内存
  static Future<void> load() async {
    _amapWeb = await AppSettings.amapWebKey();
    _amapAndroid = await AppSettings.amapAndroidKey();
    _qwKey = await AppSettings.qweatherApiKey();
    _qwHost = await AppSettings.qweatherApiHost();
    debugPrint('[ApiKeys] 高德Web=${hasAmapWeb ? "有" : "无"} · '
        '高德安卓=${hasOwnAmapAndroid ? "用户自填" : "内置"} · '
        '和风=${hasQweather ? "有" : "无"} · 内置Key兜底=$_injectBuiltin');
  }

  /// 用户在设置页改完 Key 后调用
  static Future<void> reload() => load();

  // ==================== 高德 Web服务 Key ====================

  /// 高德 Web服务 Key：**用户填的优先**，内测版没有时回退到包内 Key
  static String get amapWeb {
    if (_amapWeb.isNotEmpty) return _amapWeb;
    return _injectBuiltin ? Secrets.amapWebKey : '';
  }

  static bool get hasAmapWeb => amapWeb.isNotEmpty;

  // ==================== 高德 Android 平台 Key ====================
  //
  // 地图 SDK 与定位 SDK 共用这一个 Key。它绑定「包名 + 签名 SHA1」，
  // 所以用户要自填，必须先去高德控制台创建一个**绑定本 App 包名与签名**的
  // Key（包名与 SHA1 在设置页里可以直接复制）。门槛不低，但技术上成立 ——
  // 官方支持 `MapsInitializer.setApiKey()` 运行时设置，flutter_amap 插件
  // 已透传（见 `plugins/amap_map/.../ConvertUtil.java`）。
  //
  // 用户没填 → 回退内置 Key；用户填了 → 花他自己的配额，
  // [LocationBudget] 也不再对他做每日限制。

  /// 高德 Android 平台 Key（地图 SDK + 定位 SDK 共用）
  static String get amapAndroid =>
      _amapAndroid.isNotEmpty ? _amapAndroid : Secrets.amapAndroidKey;

  /// 用户是否填了自己的 Android Key（填了就不走内置配额）
  static bool get hasOwnAmapAndroid => _amapAndroid.isNotEmpty;

  /// 内置 Key 是否可用（公测版若不带内置 Key，用户不填就用不了地图）
  static bool get hasBuiltinAmapAndroid => Secrets.amapAndroidKey.isNotEmpty;

  // ==================== 和风天气 ====================

  /// 和风 Key（可选数据源，留空则自动跳过和风）
  static String get qweatherKey {
    if (_qwKey.isNotEmpty) return _qwKey;
    return _injectBuiltin ? Secrets.qweatherApiKey : '';
  }

  /// 和风专属 API Host（2024 改版后通用域名已停用）
  static String get qweatherHost {
    if (_qwHost.isNotEmpty) return _qwHost;
    return _injectBuiltin ? Secrets.qweatherApiHost : '';
  }

  static bool get hasQweather =>
      qweatherKey.isNotEmpty && qweatherHost.isNotEmpty;

  /// 用户是否填了自己的和风 Key（填了就不走内置配额）
  static bool get hasOwnQweather => _qwKey.isNotEmpty && _qwHost.isNotEmpty;

  // ==================== 额度限制的适用范围 ====================
  //
  // 口径（2026-10-01 用户拍板）—— **限制只针对公测版的共享内置 Key**：
  //
  // | 版本   | Key 来源   | 是否限制 | 理由 |
  // |--------|-----------|---------|------|
  // | 内测版 | 包里内置   | ❌ 不限 | 都是自己人，限它没意义 |
  // | 公测版 | 用户自填   | ❌ 不限 | 花他自己的额度 |
  // | 公测版 | 包里内置   | ✅ 限制 | 全体用户共享发布者的配额，必须自保 |
  //
  // 这两个 getter 是**唯一**的口径来源 —— 两个 Budget 类都只问它们，
  // 改规则改这里一处即可。

  /// 是否对「高德在线定位」施加内置额度限制
  static bool get amapAndroidIsMetered => isPublicBuild && !hasOwnAmapAndroid;

  /// 是否对「和风天气」施加内置额度限制
  static bool get qweatherIsMetered => isPublicBuild && !hasOwnQweather;
}
