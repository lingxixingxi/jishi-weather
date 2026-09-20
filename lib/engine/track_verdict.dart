import 'dart:math' as math;

import '../services/open_meteo_extra.dart';

/// 路面抓地状态（按「含水」分级）
enum TrackGrip {
  dry('干', 0),
  damp('微湿', 1),
  wet('湿', 2),
  flooded('积水', 3);

  const TrackGrip(this.label, this.rank);

  final String label;
  final int rank;

  /// 简要处置建议（短句，用于徽章下方一行）
  String get shortAdvice {
    switch (this) {
      case TrackGrip.dry:
        return '抓地力良好 · 干胎正常';
      case TrackGrip.damp:
        return '抓地力略降 · 注意入弯制动点';
      case TrackGrip.wet:
        return '明显湿滑 · 建议换中性/雨胎';
      case TrackGrip.flooded:
        return '有水滑风险 · 建议暂停或大幅降速';
    }
  }
}

/// 赛道研判结果
class TrackVerdict {
  /// 判定基准时刻（对齐到整点）
  final DateTime at;

  /// 路面含水（mm）
  final double waterMm;
  final TrackGrip grip;

  /// 过去 6 小时累计降水（mm）
  final double past6hRain;

  /// 过去 6 小时累计蒸散（mm）
  final double et0Sum6h;

  /// 当前小时雨强（mm/h）
  final double currentIntensity;

  final double? airTemp;
  final double? surfaceTemp; // 路面表面温度 ℃
  final double? windSpeed; // km/h
  final double? visibility; // km
  final double? humidity; // %

  /// 当前小时降水概率 %
  final int? precipProb;

  /// 当前小时蒸散率（mm/h）
  final double? et0Rate;

  /// 预计干燥所需分钟数；null 表示**近期不会干**（蒸散率过低或无数据）
  final int? dryMinutes;

  final String advice;
  final List<String> reasons;

  const TrackVerdict({
    required this.at,
    required this.waterMm,
    required this.grip,
    required this.past6hRain,
    required this.et0Sum6h,
    required this.currentIntensity,
    required this.advice,
    required this.reasons,
    this.airTemp,
    this.surfaceTemp,
    this.windSpeed,
    this.visibility,
    this.humidity,
    this.precipProb,
    this.et0Rate,
    this.dryMinutes,
  });

  /// 干燥时间文案
  String get dryText {
    final d = dryMinutes;
    if (d == null) return '近期不会干（蒸散过弱）';
    if (d == 0) return '路面已干';
    if (d < 60) return '约 $d 分钟';
    final h = d ~/ 60;
    final m = d % 60;
    return m == 0 ? '约 $h 小时' : '约 $h 小时 $m 分';
  }
}

/// 赛道湿滑研判引擎
///
/// ## 模型（用户确认版）
/// ```text
/// 含水 = max(0, 过去6h降水 − 累计蒸散 ET0 + 当前雨强 × 0.5)
/// 分级：干 < 0.2 ≤ 微湿 < 0.8 ≤ 湿 < 2.0 ≤ 积水        （单位 mm）
/// 干燥时间 = 逐小时用 ET0 累减含水，直到 < 0.2
///           当前 ET0 ≤ 0.02 mm/h → 判定「近期不会干」
/// 表面温度 Ts = 气温 + 0.02 × 短波辐射 × (1 − 0.3 × 云量/100)
///                 − min(6, 0.05 × 风速 × 日照增量)
/// 日照增量 = clamp(短波辐射 / 1000 × 5, 0, 5)   ← 无量纲日照强度因子
/// ```
///
/// ⚠️ 单位（Open-Meteo 实测口径，勿改）：
/// `et0_fao_evapotranspiration` 是**每小时 mm**、`wind_speed_10m` 是 **km/h**、
/// `shortwave_radiation` 是 **W/m²**、`cloud_cover` 是 **%**、
/// `visibility` 原始为**米**（已在服务层换算成公里）。
///
/// ⚠️ 原公式未定义「日照增量」，此处取**短波辐射归一化**（晴日正午 SW≈800
/// → 日照增量 ≈ 4，风冷项约 3℃；全晴正午的辐射增温项 0.02×800 = +16℃，
/// 与「晴日正午 +16℃」的既有结论一致）。界面会把代入值一并列出便于核对。
class TrackVerdictEngine {
  TrackVerdictEngine._();

  static const double dryLimit = 0.2;
  static const double dampLimit = 0.8;
  static const double wetLimit = 2.0;

  static TrackVerdict? judge(ExtraWeather wx, DateTime? at) {
    if (wx.isEmpty) return null;

    final t0 = at ?? DateTime.now();
    final hour = DateTime(t0.year, t0.month, t0.day, t0.hour);
    final cur = wx.nearest(hour) ?? wx.hourly.first;

    double sum(List<ExtraHourly> l, double? Function(ExtraHourly) f) =>
        l.fold(0.0, (a, e) => a + (f(e) ?? 0));

    // ===== 过去 6 小时（不含当前小时）=====
    final past6 = wx.between(hour.subtract(const Duration(hours: 6)), hour);
    final past6Rain = sum(past6, (e) => e.precipitation);
    final et0Sum6h = sum(past6, (e) => e.et0);

    // ===== 含水 =====
    final intensity = cur.precipitation ?? 0;
    final water = math.max(0.0, past6Rain - et0Sum6h + intensity * 0.5);

    final TrackGrip grip;
    if (water < dryLimit) {
      grip = TrackGrip.dry;
    } else if (water < dampLimit) {
      grip = TrackGrip.damp;
    } else if (water < wetLimit) {
      grip = TrackGrip.wet;
    } else {
      grip = TrackGrip.flooded;
    }

    // ===== 表面温度 =====
    final air = cur.temperature;
    final sw = cur.shortwave ?? 0;
    final cloud = cur.cloudCover ?? 0;
    final wind = cur.windSpeed ?? 0;
    final daylight = (sw / 1000 * 5).clamp(0.0, 5.0);
    final cooling = math.min(6.0, 0.05 * wind * daylight);
    final radiationGain = 0.02 * sw * (1 - 0.3 * cloud / 100);
    final surface = air == null ? null : air + radiationGain - cooling;

    // ===== 干燥时间 =====
    final et0Rate = cur.et0;
    int? dryMinutes;
    if (water < dryLimit) {
      dryMinutes = 0;
    } else if (et0Rate == null || et0Rate <= 0.02) {
      dryMinutes = null; // 近期不会干
    } else {
      var w = water;
      var h = 0;
      for (final e in wx.ahead(hour, 24)) {
        w -= (e.et0 ?? 0);
        h++;
        if (w < dryLimit) break;
      }
      dryMinutes = w < dryLimit ? h * 60 : null;
    }

    // ===== 研判依据 =====
    final reasons = <String>[
      '含水 ${water.toStringAsFixed(2)} mm = 过去 6h 降水 ${past6Rain.toStringAsFixed(1)}'
          ' − 蒸散 ${et0Sum6h.toStringAsFixed(2)} + 当前雨强 ${intensity.toStringAsFixed(1)} × 0.5',
      '分级标准：干 < 0.2 ≤ 微湿 < 0.8 ≤ 湿 < 2.0 ≤ 积水（mm）',
    ];
    if (surface != null) {
      reasons.add('表面温度 ${surface.toStringAsFixed(1)}℃ = 气温 ${air!.toStringAsFixed(1)}'
          ' + 辐射增温 ${radiationGain.toStringAsFixed(1)}'
          '（SW ${sw.round()} W/m² · 云量 ${cloud.round()}%）'
          ' − 风冷 ${cooling.toStringAsFixed(1)}（风 ${wind.round()} km/h）');
    }
    if (water >= dryLimit) {
      reasons.add('当前蒸散率 ${et0Rate?.toStringAsFixed(3) ?? "--"} mm/h → '
          '${dryMinutes == null ? "蒸散过弱，近期不会干" : "预计 ${dryMinutes ~/ 60} 小时 ${dryMinutes % 60} 分后转干"}');
    }

    return TrackVerdict(
      at: hour,
      waterMm: water,
      grip: grip,
      past6hRain: past6Rain,
      et0Sum6h: et0Sum6h,
      currentIntensity: intensity,
      airTemp: air,
      surfaceTemp: surface,
      windSpeed: cur.windSpeed,
      visibility: cur.visibility,
      humidity: cur.humidity,
      precipProb: cur.precipProb,
      et0Rate: et0Rate,
      dryMinutes: dryMinutes,
      advice: _advice(grip, water),
      reasons: reasons,
    );
  }

  static String _advice(TrackGrip grip, double water) {
    switch (grip) {
      case TrackGrip.dry:
        return '路面干燥（含水 ${water.toStringAsFixed(2)} mm），抓地力处于最佳状态，'
            '可正常使用干胎并按常规节奏推进。';
      case TrackGrip.damp:
        return '路面微湿（含水 ${water.toStringAsFixed(2)} mm），轮胎温度上升会变慢。'
            '建议推迟入弯制动点、柔和给油，干胎仍可用但需留出余量。';
      case TrackGrip.wet:
        return '路面湿滑（含水 ${water.toStringAsFixed(2)} mm），干胎抓地力明显不足。'
            '建议改用中性胎或雨胎，避开积水区与路面白线、井盖等低摩擦位置。';
      case TrackGrip.flooded:
        return '路面积水（含水 ${water.toStringAsFixed(2)} mm），存在水滑（aquaplaning）'
            '风险。建议暂停赛道活动，或改全雨胎并大幅降速、避开积水最深处。';
    }
  }
}
