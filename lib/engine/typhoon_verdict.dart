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
}
