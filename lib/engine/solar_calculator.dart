import 'dart:math' as math;

import 'astro.dart';

/// 一段摄影关键时刻（黄金时刻 / 蓝调时刻）
class PhotoTimeWindow {
  final String name;
  final DateTime? start;
  final DateTime? end;

  const PhotoTimeWindow({required this.name, this.start, this.end});

  bool get isValid => start != null && end != null;

  /// `18:04 – 18:32`（两端都拿不到时返回 `—`）
  String get text {
    if (!isValid) return '—';
    String hm(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return '${hm(start!)} – ${hm(end!)}';
  }

  /// 时长文案
  String get durationText {
    if (!isValid) return '';
    final m = end!.difference(start!).inMinutes;
    return m <= 0 ? '' : '$m 分钟';
  }
}

/// 太阳位置与摄影关键时刻
///
/// 定义：
/// - **黄金时刻**：太阳高度 **+6° → −4°**（光线金黄柔和、影子长）
/// - **蓝调时刻**：太阳高度 **−4° → −7°**（天空呈深蓝，城市灯光与天光平衡）
///
/// > 关于蓝调的下界：PhotoPills 等用 `−4° → −6°` 的窄定义，但在南京 9 月
/// > 实测该区间**只有 9 分钟**；实际拍摄经验是蓝调约 **10~15 分钟** 就差不多
/// > 结束了。因此取下界 −7°（实测约 13~14 分钟），与经验吻合。
///
/// 日出与日落是对称的：清晨是 蓝调(−8°→−4°) → 黄金(−4°→+6°)，
/// 傍晚是 黄金(+6°→−4°) → 蓝调(−4°→−8°)。
///
/// ⚠️ Open-Meteo 的 `daily.sunrise/sunset` 只给日出日落（太阳高度 0°），
/// 蓝调与黄金时刻必须自己算太阳高度角 —— 见 [Astro.altitude]。
class SolarCalculator {
  SolarCalculator._();

  /// 太阳赤经 / 赤纬（弧度）
  static ({double ra, double dec}) sunEquatorial(double jd) {
    final tc = (jd - 2451545.0) / 36525.0;

    // 太阳几何平黄经
    final l0 = 280.46646 + 36000.76983 * tc + 0.0003032 * tc * tc;
    // 太阳平近点角
    final m = 357.52911 + 35999.05029 * tc - 0.0001537 * tc * tc;
    final mRad = Astro.rad(m);

    // 中心差
    final c = (1.914602 - 0.004817 * tc - 0.000014 * tc * tc) * math.sin(mRad) +
        (0.019993 - 0.000101 * tc) * math.sin(2 * mRad) +
        0.000289 * math.sin(3 * mRad);

    final trueLong = l0 + c;
    // 章动 + 光行差修正
    final omega = 125.04 - 1934.136 * tc;
    final lambda = trueLong - 0.00569 - 0.00478 * math.sin(Astro.rad(omega));

    final eps = 23.439291 - 0.0130042 * tc;
    final lamRad = Astro.rad(lambda);
    final epsRad = Astro.rad(eps);

    final dec = math.asin((math.sin(epsRad) * math.sin(lamRad)).clamp(-1.0, 1.0));
    final ra = math.atan2(math.cos(epsRad) * math.sin(lamRad), math.cos(lamRad));
    return (ra: ra, dec: dec);
  }

  /// 太阳高度角（度）
  static double altitudeAt(DateTime t, double lat, double lon) {
    final jd = Astro.julianDay(t.toUtc());
    final eq = sunEquatorial(jd);
    return Astro.altitude(raRad: eq.ra, decRad: eq.dec, jd: jd, lat: lat, lon: lon);
  }

  /// 在 [from, to] 内求太阳高度角等于 [target] 的时刻（区间内须单调）
  ///
  /// 二分法，精度约 1 秒。区间内无穿越时返回 null。
  static DateTime? crossing(
    DateTime from,
    DateTime to,
    double target,
    double lat,
    double lon,
  ) {
    var a = from;
    var b = to;
    var fa = altitudeAt(a, lat, lon) - target;
    final fb = altitudeAt(b, lat, lon) - target;
    if (fa == 0) return a;
    if (fb == 0) return b;
    if (fa * fb > 0) return null; // 无穿越

    for (var i = 0; i < 40; i++) {
      final totalMs = b.difference(a).inMilliseconds;
      if (totalMs <= 1000) break;
      final mid = a.add(Duration(milliseconds: totalMs ~/ 2));
      final fm = altitudeAt(mid, lat, lon) - target;
      if (fa * fm <= 0) {
        b = mid;
      } else {
        a = mid;
        fa = fm;
      }
    }
    return a.add(Duration(milliseconds: b.difference(a).inMilliseconds ~/ 2));
  }

  /// 傍晚黄金时刻：太阳 +6° → −4°
  static PhotoTimeWindow goldenHourEvening(DateTime sunset, double lat, double lon) {
    final start = crossing(
        sunset.subtract(const Duration(hours: 3)), sunset, 6.0, lat, lon);
    final end = crossing(sunset, sunset.add(const Duration(hours: 2)), -4.0, lat, lon);
    return PhotoTimeWindow(name: '黄金时刻', start: start, end: end);
  }

  /// 傍晚蓝调时刻：太阳 −4° → −7°
  static PhotoTimeWindow blueHourEvening(DateTime sunset, double lat, double lon) {
    final start = crossing(sunset, sunset.add(const Duration(hours: 2)), -4.0, lat, lon);
    final end = crossing(sunset, sunset.add(const Duration(hours: 3)), -7.0, lat, lon);
    return PhotoTimeWindow(name: '蓝调时刻', start: start, end: end);
  }

  /// 清晨蓝调时刻：太阳 −7° → −4°
  static PhotoTimeWindow blueHourMorning(DateTime sunrise, double lat, double lon) {
    final start = crossing(
        sunrise.subtract(const Duration(hours: 2)), sunrise, -7.0, lat, lon);
    final end = crossing(
        sunrise.subtract(const Duration(hours: 2)), sunrise, -4.0, lat, lon);
    return PhotoTimeWindow(name: '蓝调时刻', start: start, end: end);
  }

  /// 清晨黄金时刻：太阳 −4° → +6°
  static PhotoTimeWindow goldenHourMorning(DateTime sunrise, double lat, double lon) {
    final start = crossing(
        sunrise.subtract(const Duration(hours: 2)), sunrise, -4.0, lat, lon);
    final end = crossing(sunrise, sunrise.add(const Duration(hours: 3)), 6.0, lat, lon);
    return PhotoTimeWindow(name: '黄金时刻', start: start, end: end);
  }

  /// 太阳正午高度角（用于判断季节与日照强度）
  static double noonAltitude(DateTime day, double lat, double lon) {
    var best = -90.0;
    final start = DateTime(day.year, day.month, day.day, 10);
    for (var m = 0; m <= 240; m += 5) {
      final t = start.add(Duration(minutes: m));
      final alt = altitudeAt(t, lat, lon);
      if (alt > best) best = alt;
    }
    return best;
  }
}
