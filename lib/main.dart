import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/home_screen.dart';
import 'services/api_keys.dart';
import 'services/app_log.dart';
import 'services/background_tasks.dart';
import 'services/weather_alert_service.dart';
import 'theme/app_theme.dart';

/// 迹时天气 —— 本地化出行天气研判
///
/// 深色航空驾驶舱风格，纯本地计算（客户端直连公开气象数据源）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ===== 日志缓冲（必须最先装）=====
  // 重写全局 debugPrint，把 App 自身日志收进内存环形缓冲，
  // 供设置页「问题反馈」一键导出。装晚了会丢掉启动阶段的日志 ——
  // 而启动阶段恰恰是最容易出问题的地方。
  AppLog.install();

  // ===== 天气提醒初始化（失败不影响主功能）=====
  // · 通知插件初始化：发通知前必须完成，否则 Android 13+ 拿不到渠道
  // · 后台调度初始化：只是把入口登记进去；具体任务在设置页开启后才注册
  try {
    await WeatherAlertService.init();
  } catch (e) {
    debugPrint('[启动] 通知初始化失败: $e');
  }
  try {
    await BackgroundTasks.init();
  } catch (e) {
    debugPrint('[启动] 后台调度初始化失败: $e');
  }

  // ===== 运行时 API Key =====
  // 公测版包里不带 Key，用户在设置页自填；内测版回退到编译进包的 Secrets。
  // 必须先加载再进主界面 —— 服务层读 Key 是同步的（拼 URL 用）。
  try {
    await ApiKeys.load();
  } catch (e) {
    debugPrint('[启动] API Key 加载失败: $e');
  }

  runApp(const JishiWeatherApp());
}

class JishiWeatherApp extends StatelessWidget {
  const JishiWeatherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '迹时天气',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),

      // ⚠️ 必须显式声明中文，否则 showDatePicker/showTimePicker 里的
      // 「SELECT DATE」「Cancel」「OK」等按钮全是英文（用户反馈）
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      locale: const Locale('zh', 'CN'),

      home: const HomeScreen(),
    );
  }
}
