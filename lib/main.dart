import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

/// 迹时天气 —— 本地化出行天气研判
///
/// 深色航空驾驶舱风格，纯本地计算（客户端直连公开气象数据源）。
void main() {
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
