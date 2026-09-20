import 'dart:math' as math;

/// 天文计算公共工具（太阳与月亮共用）
///
/// 全部为**低精度解析公式**（Meeus《Astronomical Algorithms》简化式），
/// 精度足够摄影用途：太阳高度角误差 <0.02°、月亮高度角误差 <0.3°。
class Astro {
  Astro._();

  static double rad(double deg) => deg * math.pi / 180.0;
  static double deg(double r) => r * 180.0 / math.pi;

  static double norm360(double v) {
    final r = v % 360.0;
    return r < 0 ? r + 360.0 : r;
  }

  static double norm24(double v) {
    final r = v % 24.0;
    return r < 0 ? r + 24.0 : r;
  }

  /// 儒略日（入参**须为 UTC**）
  static double julianDay(DateTime utc) {
    final y0 = utc.year;
    final m0 = utc.month;
    final day = utc.day +
        (utc.hour + utc.minute / 60.0 + utc.second / 3600.0) / 24.0;

    var y = y0;
    var m = m0;
    if (m <= 2) {
      y -= 1;
      m += 12;
    }
    final a = (y / 100).floor();
    final b = 2 - a + (a / 4).floor();
    return (365.25 * (y + 4716)).floor() +
        (30.6001 * (m + 1)).floor() +
        day +
        b -
        1524.5;
  }

  /// 格林尼治平恒星时（度）
  static double gmst(double jd) =>
      norm360(280.46061837 + 360.98564736629 * (jd - 2451545.0));

  /// 由赤经/赤纬与观测地计算**高度角**（度）
  ///
  /// [raRad] 赤经（弧度）、[decRad] 赤纬（弧度）、[lat]/[lon] 观测地（度，东经为正）
  static double altitude({
    required double raRad,
    required double decRad,
    required double jd,
    required double lat,
    required double lon,
  }) {
    final lst = gmst(jd) + lon;
    final ha = rad(norm360(lst - deg(raRad)));
    final phi = rad(lat);
    final sinAlt = math.sin(phi) * math.sin(decRad) +
        math.cos(phi) * math.cos(decRad) * math.cos(ha);
    return deg(math.asin(sinAlt.clamp(-1.0, 1.0)));
  }

  /// 由赤经/赤纬与观测地计算**方位角**（度，0=北，顺时针）
  static double azimuth({
    required double raRad,
    required double decRad,
    required double jd,
    required double lat,
    required double lon,
  }) {
    final lst = gmst(jd) + lon;
    final ha = rad(norm360(lst - deg(raRad)));
    final phi = rad(lat);
    final sinAlt = math.sin(phi) * math.sin(decRad) +
        math.cos(phi) * math.cos(decRad) * math.cos(ha);
    final alt = math.asin(sinAlt.clamp(-1.0, 1.0));
    final cosAz =
        (math.sin(decRad) - math.sin(phi) * sinAlt) / (math.cos(phi) * math.cos(alt));
    var az = math.acos(cosAz.clamp(-1.0, 1.0));
    if (math.sin(ha) > 0) az = 2 * math.pi - az;
    return deg(az);
  }

  /// 色散折射修正（近地平线时天体视高度比真高度略高，约 0.57°）
  ///
  /// 判断"是否在地平线上"用 0° 即可，摄影上可忽略；此处保留常量备用。
  static const double horizonRefractionDeg = -0.57;
}
