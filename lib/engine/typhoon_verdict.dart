import '../models/typhoon_track.dart';

/// 台风对某地的影响等级
enum TyphoonImpactLevel {
  none('无影响', 0),
  watch('关注', 1),
  alert('警戒', 2),
  severe('严重影响', 3);

  const TyphoonImpactLevel(this.label, this.rank);

  final String label;
  final int rank;
}

/// 一次台风研判的结果
class TyphoonImpact {
  final TyphoonDetail typhoon;

  /// 当前台风中心到目标点的距离（km）
  final double distanceNowKm;

  /// 预报路径中距目标点的**最近**距离（km），无预报时为 null
  final double? nearestKm;

  /// 最近点出现的时刻
  final DateTime? nearestTime;

  /// 最近点时的台风强度中文（如「强台风」）
  final String? nearestLevelText;

  /// 目标点当前是否位于 7 级风圈内
  final bool inWindCircle;

  /// 7 级风圈最大象限半径（km），无风圈数据时为 null
  final double? windCircleRadiusKm;

  final TyphoonImpactLevel level;
  final String advice;
  final List<String> reasons;

  const TyphoonImpact({
    required this.typhoon,
    required this.distanceNowKm,
    required this.level,
    required this.advice,
    required this.reasons,
    this.nearestKm,
    this.nearestTime,
    this.nearestLevelText,
    this.inWindCircle = false,
    this.windCircleRadiusKm,
  });
}

/// 台风影响研判引擎
///
/// 判定尺度（**预报路径最近距离**，并用强度做加权修正）：
/// | 距离 | 等级 |
/// |---|---|
/// | < 200 km | 严重影响 |
/// | < 400 km | 警戒 |
/// | < 800 km | 关注 |
/// | ≥ 800 km | 无影响 |
///
/// 另外：
/// - 目标点若已在**当前 7 级风圈**内 → 直接判「严重影响」（实测风圈四象限半径，
///   取最大象限做保守估计）。
/// - 强台风/超强台风把有效距离按 0.8/0.9 折算 —— 同样的中心距离，
///   强台风的外围影响范围明显更大。
class TyphoonVerdictEngine {
  TyphoonVerdictEngine._();

  static const double severeKm = 200;
  static const double alertKm = 400;
  static const double watchKm = 800;

  static TyphoonImpact? judge({
    required TyphoonDetail typhoon,
    required double lat,
    required double lon,
  }) {
    final now = typhoon.latest;
    if (now == null) return null;

    final d0 = distanceKm(now.lat, now.lon, lat, lon);

    // ===== 预报路径最近点 =====
    double? nearest;
    DateTime? nearestTime;
    String? nearestLevel;
    for (final p in typhoon.forecast) {
      final d = distanceKm(p.lat, p.lon, lat, lon);
      if (nearest == null || d < nearest) {
        nearest = d;
        nearestTime = p.time;
        nearestLevel = p.levelTextByWind;
      }
    }

    // ===== 7 级风圈 =====
    TyphoonWindCircle? c30;
    for (final c in now.windCircles) {
      if (c.name.startsWith('30')) {
        c30 = c;
        break;
      }
    }
    // 最新实况点没有风圈时，向前回溯最近一个带风圈的点
    if (c30 == null) {
      for (var i = typhoon.observed.length - 1; i >= 0; i--) {
        for (final c in typhoon.observed[i].windCircles) {
          if (c.name.startsWith('30')) {
            c30 = c;
            break;
          }
        }
        if (c30 != null) break;
      }
    }
    final radius = c30?.maxRadius;
    final inCircle = radius != null && d0 <= radius;

    // ===== 强度加权 =====
    final sev = TyphoonLevel.severity(now.levelCode);
    var eff = nearest ?? d0;
    if (sev >= 6) {
      eff *= 0.8; // 超强台风
    } else if (sev >= 5) {
      eff *= 0.9; // 强台风
    }

    TyphoonImpactLevel level;
    if (inCircle || eff < severeKm) {
      level = TyphoonImpactLevel.severe;
    } else if (eff < alertKm) {
      level = TyphoonImpactLevel.alert;
    } else if (eff < watchKm) {
      level = TyphoonImpactLevel.watch;
    } else {
      level = TyphoonImpactLevel.none;
    }

    // ===== 研判依据 =====
    final reasons = <String>[
      '当前中心距此 ${d0.round()} km（${typhoon.displayName} · ${now.levelText}级，'
          '中心气压 ${now.pressure?.round() ?? '--'} hPa）',
    ];
    if (nearest != null && nearestTime != null) {
      final dt = nearestTime;
      reasons.add('预报路径最近点 ${nearest.round()} km'
          '（${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:00，'
          '届时${nearestLevel ?? '未知'}级）');
    } else {
      reasons.add('该台风暂无预报路径数据，仅按当前中心距离评估');
    }
    if (radius != null) {
      reasons.add('当前 7 级风圈最大半径 ${radius.round()} km，'
          '${inCircle ? '目标点已在风圈内' : '目标点尚在风圈外'}');
    }
    final mv = now.moveSpeed;
    final md = now.moveDirText;
    if (mv != null && mv > 0) {
      reasons.add('正以 ${mv.round()} km/h 向$md方向移动');
    } else {
      reasons.add('移动缓慢或原地少动');
    }

    return TyphoonImpact(
      typhoon: typhoon,
      distanceNowKm: d0,
      nearestKm: nearest,
      nearestTime: nearestTime,
      nearestLevelText: nearestLevel,
      inWindCircle: inCircle,
      windCircleRadiusKm: radius,
      level: level,
      advice: _advice(level, typhoon, nearest, inCircle),
      reasons: reasons,
    );
  }

  static String _advice(
    TyphoonImpactLevel level,
    TyphoonDetail t,
    double? nearest,
    bool inCircle,
  ) {
    switch (level) {
      case TyphoonImpactLevel.severe:
        if (inCircle) {
          return '目标点已进入 ${t.displayName} 的 7 级风圈，将出现明显大风与降雨，'
              '请避免户外活动，远离广告牌、临时构筑物与大树。';
        }
        return '${t.displayName} 预报路径将逼近本地（最近约 ${nearest?.round() ?? '--'} km），'
            '出行计划建议推迟或改期，并持续跟踪路径调整。';
      case TyphoonImpactLevel.alert:
        return '${t.displayName} 外围环流可能影响本地，出行需预留充足时间，'
            '留意航班、高铁与轮渡的动态调整。';
      case TyphoonImpactLevel.watch:
        return '距离较远，短期内对本地无直接影响；'
            '但台风路径预报存在不确定性，建议关注后续更新。';
      case TyphoonImpactLevel.none:
        return '${t.displayName} 对本地无直接影响，可按原计划出行。';
    }
  }

  // ==================== 台风 × 路线（计划任务 4-1 / 10-2）====================

  /// 机构分歧：各机构预报点相对 BABJ（中央气象台）的最大偏差（km）
  ///
  /// 这是**路径预报不确定度**的直接度量：分歧越大，越该对"最近距离"留余量。
  static double agencySpread(TyphoonDetail t) {
    final babj = t.agencyForecasts['BABJ'];
    if (babj == null || t.agencyForecasts.length < 2) return 0;

    var maxSpread = 0.0;
    for (final e in t.agencyForecasts.entries) {
      if (e.key == 'BABJ') continue;
      final pts = e.value;
      for (var i = 0; i < pts.length && i < babj.length; i++) {
        final d = distanceKm(pts[i].lat, pts[i].lon, babj[i].lat, babj[i].lon);
        if (d > maxSpread) maxSpread = d;
      }
    }
    return maxSpread;
  }

  /// 台风 × 路线重叠分析
  ///
  /// 对路线每个采样点，取**该点到达时刻 ±6 小时**窗口内最近的台风路径点
  /// （实况 + 预报），算距离：
  /// - 距离 < 该时刻台风的 **7 级风圈半径**（无风圈数据时用 [defaultWindRadiusKm]）
  ///   → 判为「受影响路段」
  /// - 距离 < [highRiskKm] → 风险「高」，否则「中」
  ///
  /// 与 [judge] 的区别：[judge] 回答"台风对这个地点有没有影响"（单点），
  /// 这里回答"这条路线上哪些路段会撞上台风"（沿程 + 时间窗）。
  static RouteTyphoonImpact routeImpact({
    required TyphoonDetail typhoon,
    required List<RouteSample> samples,
    double defaultWindRadiusKm = 200,
    double highRiskKm = 100,
  }) {
    final spread = agencySpread(typhoon);
    final agencyCount = typhoon.agencyForecasts.length;
    final path = typhoon.fullTrack;

    RouteTyphoonImpact empty(String reason) => RouteTyphoonImpact(
          typhoonName: typhoon.displayName,
          affected: false,
          segments: const [],
          agencySpreadKm: spread,
          agencyCount: agencyCount,
          advice: reason,
          sampleCount: samples.length,
        );

    if (path.isEmpty) return empty('台风无有效路径数据，无法做路线重叠分析。');
    if (samples.isEmpty) return empty('路线无采样点。');

    final hit = <RouteTyphoonSegment>[];
    double? nearest;
    DateTime? nearestTime;
    double? nearestKmMark;
    String? nearestLabel;

    for (final s in samples) {
      TyphoonPoint? best;
      var bestD = double.infinity;

      for (final p in path) {
        // ±6 小时时间窗
        if (p.time.difference(s.time).inMinutes.abs() > 6 * 60) continue;
        final d = distanceKm(p.lat, p.lon, s.lat, s.lon);
        if (d < bestD) {
          bestD = d;
          best = p;
        }
      }
      if (best == null) continue;

      if (nearest == null || bestD < nearest) {
        nearest = bestD;
        nearestTime = s.time;
        nearestKmMark = s.km;
        nearestLabel = s.label;
      }

      // 该时刻台风的真实 7 级风圈半径（取最大象限，偏保守）
      var radius = defaultWindRadiusKm;
      for (final c in best.windCircles) {
        if (c.name.startsWith('30')) {
          radius = c.maxRadius;
          break;
        }
      }

      if (bestD < radius) {
        hit.add(RouteTyphoonSegment(
          km: s.km,
          time: s.time,
          distanceKm: bestD,
          levelText: best.levelText,
          windSpeed: best.windSpeed,
          risk: bestD < highRiskKm ? '高' : '中',
          label: s.label,
        ));
      }
    }

    // 受影响路段可能很密（每 10km 一个采样点），按里程抽稀到最多 8 条
    final thinned = _thinSegments(hit, 8);

    final affected = hit.isNotEmpty;
    final highRisk = hit.any((h) => h.risk == '高');

    final buf = StringBuffer();
    if (!affected) {
      buf.write('${typhoon.displayName} 对本次路线无直接影响');
      if (nearest != null) buf.write('（全程最近 ${nearest.round()} km）');
      buf.write('，可按原计划出行。');
    } else if (highRisk) {
      buf.write('路线有路段将进入 ${typhoon.displayName} 的 7 级风圈内且距离较近，'
          '存在大风与强降雨风险，建议改期或调整路线。');
    } else {
      buf.write('路线部分路段处于 ${typhoon.displayName} 的外围影响范围内，'
          '建议预留延误时间并关注预警更新。');
    }
    if (spread > 100) {
      buf.write('另外，各机构对路径的预报分歧约 ${spread.round()} km，'
          '不确定性较大，请以最新预报为准。');
    }

    return RouteTyphoonImpact(
      typhoonName: typhoon.displayName,
      affected: affected,
      nearestKm: nearest,
      nearestTime: nearestTime,
      nearestKmMark: nearestKmMark,
      nearestLabel: nearestLabel,
      segments: thinned,
      agencySpreadKm: spread,
      agencyCount: agencyCount,
      advice: buf.toString(),
      sampleCount: samples.length,
    );
  }

  /// 按里程均匀抽稀受影响路段，避免 10km 一个点铺满屏幕
  static List<RouteTyphoonSegment> _thinSegments(
    List<RouteTyphoonSegment> list,
    int maxCount,
  ) {
    if (list.length <= maxCount) return list;
    final out = <RouteTyphoonSegment>[];
    final step = (list.length - 1) / (maxCount - 1);
    for (var i = 0; i < maxCount; i++) {
      out.add(list[(i * step).round().clamp(0, list.length - 1)]);
    }
    return out;
  }
}

/// 路线上的一个采样点（台风 × 路线分析用）
class RouteSample {
  /// 里程（km）
  final double km;

  /// 到达时刻
  final DateTime time;

  final double lat;
  final double lon;

  /// 段名 / 地名（可选，展示用）
  final String? label;

  const RouteSample({
    required this.km,
    required this.time,
    required this.lat,
    required this.lon,
    this.label,
  });
}

/// 受台风影响的一个路段
class RouteTyphoonSegment {
  final double km;
  final DateTime time;
  final double distanceKm;

  /// 该时刻台风的强度中文
  final String levelText;

  /// 该时刻台风的最大风速 m/s
  final double? windSpeed;

  /// 风险：高 / 中
  final String risk;

  final String? label;

  const RouteTyphoonSegment({
    required this.km,
    required this.time,
    required this.distanceKm,
    required this.levelText,
    required this.risk,
    this.windSpeed,
    this.label,
  });
}

/// 台风对整条路线的影响
class RouteTyphoonImpact {
  final String typhoonName;
  final bool affected;

  /// 全程最近距离（km）
  final double? nearestKm;

  /// 最近点对应的到达时刻
  final DateTime? nearestTime;

  /// 最近点的里程
  final double? nearestKmMark;

  final String? nearestLabel;

  /// 受影响路段（已抽稀）
  final List<RouteTyphoonSegment> segments;

  /// 机构分歧（km）
  final double agencySpreadKm;

  /// 参与预报的机构数
  final int agencyCount;

  final String advice;
  final int sampleCount;

  const RouteTyphoonImpact({
    required this.typhoonName,
    required this.affected,
    required this.segments,
    required this.agencySpreadKm,
    required this.agencyCount,
    required this.advice,
    required this.sampleCount,
    this.nearestKm,
    this.nearestTime,
    this.nearestKmMark,
    this.nearestLabel,
  });

  /// 最高风险等级
  String get worstRisk =>
      segments.any((s) => s.risk == '高') ? '高' : (segments.isEmpty ? '无' : '中');
}
