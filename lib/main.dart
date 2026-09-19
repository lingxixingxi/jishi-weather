import 'package:flutter/material.dart';

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
      home: const HomeScreen(),
    );
  }
}
