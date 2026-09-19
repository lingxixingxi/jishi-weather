import 'package:flutter/material.dart';

/// 迹时天气 · 视觉规范
///
/// 沿用 UI demo 定稿的「深色航空驾驶舱」风格：
/// 深色底 + 琥珀 accent + 全非衬线字体（用户明确要求，不用等宽/衬线）。
class AppTheme {
  AppTheme._();

  // ===== 背景层级 =====
  static const bg = Color(0xFF0A0E14); // 最底
  static const bgPanel = Color(0xFF10151F); // 面板
  static const bgCard = Color(0xFF131A26); // 卡片
  static const bgInset = Color(0xFF0C1119); // 凹陷输入框

  // ===== 边框 =====
  static const border = Color(0xFF1F2A3A);
  static const borderSoft = Color(0xFF182230);

  // ===== 文字 =====
  static const text = Color(0xFFDBE4EE);
  static const textDim = Color(0xFF8493A6);
  static const textFaint = Color(0xFF5C6A7D);

  // ===== 强调色（琥珀）=====
  static const accent = Color(0xFFF0A928);
  static const accentDim = Color(0x1FF0A928);

  // ===== 语义色（绿黄红建议等级）=====
  static const green = Color(0xFF2FD07A);
  static const yellow = Color(0xFFF0A928);
  static const orange = Color(0xFFF2771A);
  static const red = Color(0xFFEF5350);
  static const cyan = Color(0xFF3AC6D6);

  /// 建议等级 → 颜色
  static Color gradeColor(String grade) {
    switch (grade) {
      case '红':
        return red;
      case '橙':
        return orange;
      case '黄':
        return yellow;
      default:
        return green;
    }
  }

  /// 非衬线字体栈（与 demo 的 --sans 一致）
  /// 说明：Flutter 默认即非衬线，此处保留常量供后续自定义字体时替换。
  // ignore: unused_field
  static const _sans = <String>[
    'Roboto',
    'Microsoft YaHei',
    'PingFang SC',
    'sans-serif',
  ];

  /// 日期/时间选择器的**深色主题**
  ///
  /// Flutter 默认的 `showDatePicker` / `showTimePicker` 是浅色 Material
  /// 样式，与 App 的深色航空主题完全不搭（用户反馈「像是系统默认的」）。
  /// 用 `builder` 包一层这个 Theme 即可统一风格。
  ///
  /// 用法：
  /// ```dart
  /// showDatePicker(
  ///   context: context, ...,
  ///   builder: (ctx, child) => Theme(data: AppTheme.pickerTheme(ctx), child: child!),
  /// );
  /// ```
  static ThemeData pickerTheme(BuildContext context) {
    final base = Theme.of(context);
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        onPrimary: const Color(0xFF14100A),
        surface: bgCard,
        onSurface: text,
        surfaceContainerHighest: bgInset,
        onSurfaceVariant: textDim,
        outline: border,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: bgCard,
        surfaceTintColor: Colors.transparent,
      ),
      datePickerTheme: const DatePickerThemeData(
        backgroundColor: bgCard,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: bgInset,
        headerForegroundColor: text,
        weekdayStyle: TextStyle(color: textFaint, fontSize: 12, fontWeight: FontWeight.w600),
        dayStyle: TextStyle(fontSize: 14),
        dayForegroundColor: WidgetStatePropertyAll(text),
        todayForegroundColor: WidgetStatePropertyAll(accent),
        todayBorder: BorderSide(color: accent),
        yearForegroundColor: WidgetStatePropertyAll(text),
        rangePickerBackgroundColor: bgInset,
        dividerColor: borderSoft,
      ),
      timePickerTheme: const TimePickerThemeData(
        backgroundColor: bgCard,
        dialBackgroundColor: bgInset,
        dialHandColor: accent,
        dialTextColor: text,
        hourMinuteColor: bgInset,
        hourMinuteTextColor: text,
        entryModeIconColor: textDim,
        dayPeriodColor: bgInset,
        dayPeriodTextColor: text,
        helpTextStyle: TextStyle(color: textDim, fontSize: 12),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
    );
  }

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        secondary: cyan,
        surface: bgPanel,
        error: red,
      ),
      textTheme: base.textTheme
          .apply(bodyColor: text, displayColor: text, fontFamily: 'Roboto')
          .copyWith(
            bodyLarge: const TextStyle(fontFamily: 'Roboto', fontSize: 15, color: text),
            bodyMedium: const TextStyle(fontFamily: 'Roboto', fontSize: 13.5, color: text),
            bodySmall: const TextStyle(fontFamily: 'Roboto', fontSize: 12, color: textDim),
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        centerTitle: false,
        foregroundColor: text,
      ),
      dividerColor: borderSoft,
      cardTheme: CardThemeData(
        color: bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: borderSoft),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgInset,
        hintStyle: const TextStyle(color: textFaint, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: accent),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF14100A),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
      ),
    );
  }
}
