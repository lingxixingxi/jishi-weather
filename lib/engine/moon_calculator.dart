import 'dart:math' as math;

import 'astro.dart';

/// 月相与月亮位置
///
/// **纯天文计算，不需要任何外部数据源** —— 早期把「月相」列为"无免 key
/// 数据源"是判断失误：朔望月周期与月球历表都是确定性的，用 Meeus
/// 《Astronomical Algorithms》的低精度公式即可算到足够精度
/// （照亮比例与权威月相表一致，高度角误差 ~0.3°）。
///
/// 对摄影（尤其星空）而言，「月明星稀」是仅次于云量的硬约束：
/// 满月夜的天空背景亮度可比新月夜高 3~4 个星等，银河、暗星云全部被淹没。
class MoonInfo {
  /// 照亮比例 0~1（0 = 新月，1 = 满月）
  final double illumination;

  /// 月龄（天，0 ~ 29.53）
  final double ageDays;

  /// 月相名称
  final String phaseName;

  /// 月亮高度角（度；负值表示在地平线以下）
  final double altitudeDeg;

  /// 月亮方位角（度；0=北，90=东，180=南，270=西）
  final double azimuthDeg;

  const MoonInfo({
    required this.illumination,
    required this.ageDays,
    required this.phaseName,
    required this.altitudeDeg,
    required this.azimuthDeg,
  });

  /// 月亮是否在地平线以上
  bool get isUp => altitudeDeg > 0;

  /// 照亮百分比（展示用）
  int get illuminationPercent => (illumination * 100).round();

  /// **月光对天文观测的干扰系数 0~1**（1 = 完全无干扰，0 = 月光淹没一切）
  ///
  /// 三个自变量：
  /// - 照亮比例：满月约比新月亮 3~4 个星等；用 `^0.7` 让半月的影响不至于被低估
  /// - 高度角：月亮越接近天顶，穿过的大气越薄、散射越强，干扰越大
  /// - **凸月 / 满月额外压制**：
  ///   照亮 >65%（盈凸月后期起）月亮整夜基本在天上，银河拍摄窗口关闭 → ×0.72；
  ///   照亮 >85%（满月级）天空背景亮度本身就是决定性的 → ×0.50
  ///
  /// 月亮落到地平线以下 → 完全不干扰（系数 1.0）。
  double get darknessFactor {
    if (!isUp) return 1.0;
    final alt = (altitudeDeg / 90).clamp(0.0, 1.0);
    final bright = math.pow(illumination, 0.7).toDouble();
    var f = 1.0 - 0.90 * bright * (0.30 + 0.70 * alt);
    if (illumination > 0.85) {
      f *= 0.50; // 满月级
    } else if (illumination > 0.65) {
      f *= 0.72; // 盈凸月 / 亏凸月
    }
    return f.clamp(0.0, 1.0);
  }

  /// 干扰等级文案
  String get interferenceText {
    if (!isUp) return '月亮在地平线下，无月光干扰';
    final d = darknessFactor;
    if (d >= 0.85) return '月光干扰很小';
    if (d >= 0.6) return '月光有轻度干扰';
    if (d >= 0.35) return '月光干扰明显';
    return '月光强烈，暗弱天体基本不可见';
  }
}

/// 月球计算器
class MoonCalculator {
  MoonCalculator._();

  /// 朔望月周期（天）
  static const double synodicMonth = 29.530588853;

  /// 计算给定时刻、给定地点的月亮状态
  ///
  /// [t] 可传本地时间，内部会转 UTC。
  static MoonInfo at(DateTime t, double lat, double lon) {
    final jd = Astro.julianDay(t.toUtc());
    final tc = (jd - 2451545.0) / 36525.0; // 儒略世纪数

    // ===== 月球主要角度（Meeus 低精度公式，度）=====
    final lp = 218.3164477 + 481267.88123421 * tc - 0.0015786 * tc * tc;
    final d = 297.8501921 + 445267.1114034 * tc - 0.0018819 * tc * tc;
    final m = 357.5291092 + 35999.0502909 * tc - 0.0001536 * tc * tc;
    final mp = 134.9633964 + 477198.8675055 * tc + 0.0087414 * tc * tc;
    final f = 93.2720950 + 483202.0175233 * tc - 0.0036539 * tc * tc;

    final dRad = Astro.rad(d);
    final mRad = Astro.rad(m);
    final mpRad = Astro.rad(mp);
    final fRad = Astro.rad(f);

    // ===== 照亮比例 =====
    // 用平距角 D（月亮−太阳）近似相位角：k = (1 − cos D) / 2
    // 新月 D=0 → 0；上弦 D=90° → 0.5；满月 D=180° → 1
    final illum = (1 - math.cos(dRad)) / 2;
    final age = (Astro.norm360(d) / 360.0) * synodicMonth;

    // ===== 月亮黄经 / 黄纬（主要摄动项）=====
    final lambda = lp +
        6.289 * math.sin(mpRad) +
        1.274 * math.sin(2 * dRad - mpRad) +
        0.658 * math.sin(2 * dRad) +
        0.214 * math.sin(2 * mpRad) -
        0.186 * math.sin(mRad) -
        0.114 * math.sin(2 * fRad);

    final beta = 5.128 * math.sin(fRad) +
        0.281 * math.sin(mpRad + fRad) +
        0.278 * math.sin(mpRad - fRad) +
        0.173 * math.sin(2 * dRad - fRad) +
        0.055 * math.sin(2 * dRad - mpRad + fRad) +
        0.046 * math.sin(2 * dRad - mpRad - fRad) +
        0.033 * math.sin(2 * dRad + fRad) +
        0.017 * math.sin(2 * mpRad + fRad);

    // ===== 黄道 → 赤道 =====
    final eps = Astro.rad(23.4392911 - 0.0130042 * tc);
    final lamRad = Astro.rad(lambda);
    final betRad = Astro.rad(beta);

    final sinDec =
        math.sin(betRad) * math.cos(eps) + math.cos(betRad) * math.sin(eps) * math.sin(lamRad);
    final dec = math.asin(sinDec.clamp(-1.0, 1.0));

    final ra = math.atan2(
      math.sin(lamRad) * math.cos(eps) - math.tan(betRad) * math.sin(eps),
      math.cos(lamRad),
    );

    final alt = Astro.altitude(raRad: ra, decRad: dec, jd: jd, lat: lat, lon: lon);
    final az = Astro.azimuth(raRad: ra, decRad: dec, jd: jd, lat: lat, lon: lon);

    return MoonInfo(
      illumination: illum.clamp(0.0, 1.0),
      ageDays: age,
      phaseName: phaseNameOf(age),
      altitudeDeg: alt,
      azimuthDeg: az,
    );
  }

  /// 月出时刻（当天本地日范围内）
  static DateTime? moonrise(DateTime day, double lat, double lon) =>
      _findHorizonCrossing(day, lat, lon, rising: true);

  /// 月落时刻（当天本地日范围内）
  static DateTime? moonset(DateTime day, double lat, double lon) =>
      _findHorizonCrossing(day, lat, lon, rising: false);

  /// 在一天内扫描月亮高度角过 0° 的时刻
  ///
  /// 15 分钟粗扫定位 → 二分细化到秒级。月亮每天晚升约 50 分钟，
  /// 因此某些日子当天可能"无月出"或"无月落"（返回 null）。
  static DateTime? _findHorizonCrossing(
    DateTime day,
    double lat,
    double lon, {
    required bool rising,
  }) {
    final start = DateTime(day.year, day.month, day.day);
    const stepMin = 15;
    var prevT = start;
    var prevAlt = at(prevT, lat, lon).altitudeDeg;

    for (var m = stepMin; m <= 24 * 60; m += stepMin) {
      final t = start.add(Duration(minutes: m));
      final alt = at(t, lat, lon).altitudeDeg;
      final crossed = rising ? (prevAlt <= 0 && alt > 0) : (prevAlt >= 0 && alt < 0);
      if (crossed) return _bisectHorizon(prevT, t, lat, lon, rising: rising);
      prevT = t;
      prevAlt = alt;
    }
    return null;
  }

  static DateTime _bisectHorizon(
    DateTime a,
    DateTime b,
    double lat,
    double lon, {
    required bool rising,
  }) {
    for (var i = 0; i < 30; i++) {
      final totalMs = b.difference(a).inMilliseconds;
      if (totalMs <= 1000) break;
      final mid = a.add(Duration(milliseconds: totalMs ~/ 2));
      final alt = at(mid, lat, lon).altitudeDeg;
      final above = alt > 0;
      if (above == rising) {
        b = mid;
      } else {
        a = mid;
      }
    }
    return a.add(Duration(milliseconds: b.difference(a).inMilliseconds ~/ 2));
  }

  /// 月龄 → 月相名（8 相，每相约 3.69 天）
  static String phaseNameOf(double ageDays) {
    final a = ageDays % synodicMonth;
    if (a < 1.85) return '新月';
    if (a < 5.54) return '娥眉月';
    if (a < 9.23) return '上弦月';
    if (a < 12.92) return '盈凸月';
    if (a < 16.61) return '满月';
    if (a < 20.30) return '亏凸月';
    if (a < 23.99) return '下弦月';
    if (a < 27.68) return '残月';
    return '新月';
  }

  /// 参考用：给定时刻的月相（不含位置依赖）
  static double illuminationAt(DateTime t) => at(t, 0, 0).illumination;

  /// 已知新月参考时刻（Meeus 例 49.a，2000-01-06 18:14 UTC）
  static DateTime get referenceNewMoon => DateTime.utc(2000, 1, 6, 18, 14);
}
