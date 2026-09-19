import 'dart:math' as math;

/// 气象参数推算引擎
///
/// 中央气象台只提供 温度/降水/天气现象/风速/风向，缺:
/// **降水概率、阵风、能见度、云量** 四项。
/// 这里用物理经验公式 + 已有要素推算补全，使各源字段对齐后可比对。
///
/// 参考依据：
/// - 阵风系数：胡海川(2022) 阵风预报方程、景盼盼(2024) 阵风系数模型综述
/// - 能见度：CN108227041A（湿度→能见度）、地面气象观测经验
/// - Z-R 关系：Marshall-Palmer(1948) `Z = 200·R^1.6`
class WeatherEstimator {
  WeatherEstimator._();

  // ==================== 阵风 ====================

  /// 阵风系数（阵风风速 / 10 分钟平均风速）
  ///
  /// 陆地一般 1.3~1.8；风速越大湍流越强、降水/对流会进一步加大阵风。
  /// 参考方程（胡海川 2022）：Fgust = F10 + 7.71·u* + 0.6·max(0,U)
  static double gustFactor({
    required double windSpeed, // km/h
    double? precipitation, // mm/h
    int? weatherCode,
  }) {
    var f = 1.35;
    // 风速越大 → 湍流越强
    if (windSpeed > 60) {
      f += 0.25;
    } else if (windSpeed > 40) {
      f += 0.15;
    } else if (windSpeed > 25) {
      f += 0.08;
    }
    // 降水增强阵风
    final p = precipitation ?? 0;
    if (p > 16) {
      f += 0.25;
    } else if (p > 8) {
      f += 0.18;
    } else if (p > 0.1) {
      f += 0.10;
    }
    // 雷暴/强对流
    if (weatherCode != null && weatherCode >= 95) f += 0.20;
    return f.clamp(1.2, 2.2);
  }

  /// 由平均风速推算阵风（km/h）
  static double estimateGust({
    required double windSpeed,
    double? precipitation,
    int? weatherCode,
  }) {
    return windSpeed *
        gustFactor(
          windSpeed: windSpeed,
          precipitation: precipitation,
          weatherCode: weatherCode,
        );
  }

  // ==================== 能见度 ====================

  /// 能见度估算（km）
  ///
  /// 相对湿度决定起雾倾向，降水再向下折减，雾/霾天气码给出硬上限。
  static double estimateVisibility({
    required double humidity, // %
    double? precipitation, // mm/h
    int? weatherCode,
  }) {
    // 1. 湿度基线
    double vis;
    if (humidity < 60) {
      vis = 30;
    } else if (humidity < 75) {
      vis = 20;
    } else if (humidity < 85) {
      vis = 12;
    } else if (humidity < 92) {
      vis = 6;
    } else if (humidity < 96) {
      vis = 2.5;
    } else {
      vis = 1.0; // 接近饱和 → 易起雾
    }

    // 2. 降水折减
    final p = precipitation ?? 0;
    if (p >= 0.1) {
      double rainVis;
      if (p < 2.5) {
        rainVis = 8; // 小雨
      } else if (p < 8) {
        rainVis = 4; // 中雨
      } else if (p < 16) {
        rainVis = 2; // 大雨
      } else {
        rainVis = 1; // 暴雨
      }
      vis = math.min(vis, rainVis);
    }

    // 3. 雾/雾凇
    if (weatherCode == 45 || weatherCode == 48) vis = math.min(vis, 0.5);

    return vis.clamp(0.1, 50.0);
  }

  // ==================== 云量 ====================

  /// 云量估算（%）
  ///
  /// 中央气象台给的是「晴/多云/阴/小雨」这类定性词，按此映射云量区间。
  static double estimateCloudCover({
    int? weatherCode,
    String? weatherText,
    double? precipitation,
  }) {
    // 优先按 WMO 天气码
    if (weatherCode != null) {
      final c = weatherCode;
      if (c == 0) return 5;
      if (c == 1) return 20;
      if (c == 2) return 55;
      if (c == 3) return 95;
      if (c == 45 || c == 48) return 90;
      if (c >= 51 && c <= 57) return 90; // 毛毛雨
      if (c >= 61 && c <= 67) return 95; // 雨
      if (c >= 71 && c <= 77) return 95; // 雪
      if (c >= 80 && c <= 82) return 85; // 阵雨
      if (c >= 85 && c <= 86) return 90; // 阵雪
      if (c >= 95) return 100; // 雷雨
    }

    // 退化为文字判断
    final t = weatherText ?? '';
    if (t.isEmpty) {
      return (precipitation ?? 0) > 0.1 ? 90 : 50;
    }
    if (t.contains('晴')) return 10;
    if (t.contains('少云')) return 30;
    if (t.contains('多云')) return 60;
    if (t.contains('阴')) return 95;
    if (t.contains('雾') || t.contains('霾')) return 90;
    if (t.contains('雨') || t.contains('雪') || t.contains('雷') || t.contains('雹')) {
      return 95;
    }
    return (precipitation ?? 0) > 0.1 ? 90 : 50;
  }

  // ==================== 降水概率 ====================

  /// 降水概率估算（%）
  ///
  /// 已有实测/预报值时直接采用；否则按降水强度 + 湿度 + 多源分歧推算。
  static int estimatePrecipProbability({
    double? precipitation,
    int? providedProbability,
    double? probabilitySpread, // 各源概率分歧（0~100）
    double? humidity,
  }) {
    if (providedProbability != null) return providedProbability.clamp(0, 100);

    final p = precipitation ?? 0;
    double prob;
    if (p < 0.05) {
      prob = 10;
    } else if (p < 0.5) {
      prob = 40;
    } else if (p < 2.5) {
      prob = 70;
    } else if (p < 8) {
      prob = 85;
    } else {
      prob = 95;
    }

    // 湿度修正
    if (humidity != null) {
      if (humidity > 90) {
        prob += 10;
      } else if (humidity < 50) {
        prob -= 15;
      }
    }
    // 多源分歧大 → 下调置信
    if (probabilitySpread != null && probabilitySpread > 40) prob -= 10;

    return prob.round().clamp(0, 100);
  }

  // ==================== Z-R 关系（雷达反演降水）====================

  /// 雷达反射率 → 降水强度（mm/h）
  ///
  /// Marshall-Palmer (1948)：`Z = 200 · R^1.6`
  /// 其中 `Z = 10^(dBZ/10)`，反解得 `R = (Z / a)^(1/b)`
  ///
  /// [a] 与 [b] 可按降水类型调整（对流性降水常用 300/1.4，层状云 200/1.6）。
  static double dbzToRainRate(double dbz, {double a = 200, double b = 1.6}) {
    if (dbz <= 0) return 0;
    final z = math.pow(10, dbz / 10).toDouble();
    final r = math.pow(z / a, 1 / b).toDouble();
    return r.isFinite ? r : 0;
  }

  /// 降水强度 → 雷达反射率（dBZ），用于与雷达图回波等级比对
  static double rainRateToDbz(double mmPerHour, {double a = 200, double b = 1.6}) {
    if (mmPerHour <= 0) return 0;
    final z = a * math.pow(mmPerHour, b).toDouble();
    return 10 * (math.log(z) / math.ln10);
  }
}
