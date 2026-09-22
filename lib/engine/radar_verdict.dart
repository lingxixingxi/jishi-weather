import 'dart:async';

import '../models/hourly_weather.dart';
import '../services/radar_service.dart';
import '../services/radar_source.dart';

/// 单点雷达实况结论
class RadarPointVerdict {
  final DateTime time;

  /// 该点当前回波强度（dBZ），null = 无回波
  final int? dbzNow;

  /// 由 dBZ 经 Z-R 关系反演的降水强度（mm/h）
  final double? rainNow;

  /// 按回波移动趋势外推，该点未来 [horizonMinutes] 内是否可能被回波覆盖
  final bool expectedRainAhead;

  /// 参与分析的帧数
  final int framesUsed;

  /// 全图最大 dBZ（反映区域对流强度）
  final int maxDbz;

  /// 全图回波覆盖率（%）
  final double coverage;

  /// 回波移动速度（km/h）
  final double? motionSpeedKmh;

  /// 回波移动去向方位（如「东北」）
  final String? motionDirection;

  /// **外推预测**：目标点在 [leadMinutes] 分钟后的回波强度（dBZ）
  ///
  /// 数值模式对 0~2 小时的短临预报很弱，而雷达回波外推恰好擅长这个尺度，
  /// 因此这份预测是「未来逐小时」展示时的重要补充依据。
  final int? dbzForecast;

  /// 外推预测的降水强度（mm/h，由 dBZ 经 Z-R 关系反演）
  final double? rainForecast;

  /// 外推提前量（分钟）
  final int leadMinutes;

  /// 本结论是否来自**单站雷达**（false = 拼图兜底）
  final bool fromStation;

  /// 数据源标签（「单站雷达 南京站（AZ9250）」/「区域拼图（华东）」）
  final String sourceLabel;

  /// 该源的空间精度（km/像素）
  final double kmPerPixel;

  const RadarPointVerdict({
    required this.time,
    this.dbzNow,
    this.rainNow,
    this.expectedRainAhead = false,
    this.framesUsed = 0,
    this.maxDbz = 0,
    this.coverage = 0,
    this.motionSpeedKmh,
    this.motionDirection,
    this.dbzForecast,
    this.rainForecast,
    this.leadMinutes = 60,
    this.fromStation = false,
    this.sourceLabel = '',
    this.kmPerPixel = 2.6,
  });

  bool get hasEchoNow => dbzNow != null && dbzNow! >= 5;

  /// 外推预测是否有回波
  bool get hasEchoForecast => dbzForecast != null && dbzForecast! >= 5;

  String get echoText {
    if (!hasEchoNow) return '无回波';
    return '${RadarPalette.dbzLevel(dbzNow!)}（$dbzNow dBZ）';
  }

  /// 外推预测的文字描述
  String get forecastText {
    if (dbzForecast == null) return '—';
    if (dbzForecast! < 5) return '无回波';
    return '${RadarPalette.dbzLevel(dbzForecast!)}（$dbzForecast dBZ）';
  }
}

/// 单个数值模型与雷达实况的吻合度
class ModelScore {
  /// 模型标识（如 ecmwf_ifs025 / nmc / qweather）
  final String modelKey;

  /// 展示名（如 ECMWF / 中央气象台）
  final String modelName;
  final int score; // 0~100
  final String reason;

  const ModelScore({
    required this.modelKey,
    required this.modelName,
    required this.score,
    required this.reason,
  });
}

/// 雷达定调结论
class RadarVerdict {
  final RadarPointVerdict? radar;
  final List<ModelScore> scores;

  /// 与雷达实况最吻合的模型展示名（分歧大时的「定调」依据）
  final String? bestModel;

  /// 与雷达实况最吻合的**模型标识**（用于取该源的数据显示详情）
  final String? bestModelKey;

  /// 结论摘要
  final String summary;

  /// 是否因分歧大而启用了雷达定调
  final bool arbitrationUsed;

  /// 打分所依据的雷达时点说明
  ///
  /// 形如「按当前回波」/「按 58 分钟后外推」。**必须如实标注**：
  /// 未来时刻的比较用的是外推预测而非实测，可信度不同。
  final String scoreBasis;

  /// 本结论是否来自单站雷达
  final bool fromStation;

  /// 数据源标签
  final String sourceLabel;

  /// 目标时刻是否**超出雷达外推可信范围**（此时完全未使用雷达定调）
  ///
  /// 为 true 时 [scores] 必为空、[bestModelKey] 必为 null ——
  /// 调用方据此**不得**用「雷达判出的最优源」重建数据，应保持多源融合。
  final bool beyondNowcast;

  const RadarVerdict({
    this.radar,
    this.scores = const [],
    this.bestModel,
    this.bestModelKey,
    this.summary = '',
    this.arbitrationUsed = false,
    this.scoreBasis = '',
    this.fromStation = false,
    this.sourceLabel = '',
    this.beyondNowcast = false,
  });
}

/// 雷达定调引擎
///
/// 当各数值模型分歧较大时，用**真实雷达回波**作为裁决依据：
///   1. 取最近若干帧雷达图 → 逐帧反演 dBZ
///   2. 判断目标点当前是否有回波、回波往哪移动
///   3. 与各模型的「是否有雨 / 降水强度」预测比对打分
///   4. 得分最高者即为「最可信模型」，同时也能反过来校验模型准确度
///
/// ## 数据源选择（2026-09-22 重构）
/// **不在本类里决定用哪张图** —— 统一交给 [RadarSourcePicker]：
/// 单站雷达当前小时有更新就用单站（0.68 km/px），查过且过期才回退拼图
/// （2.6 km/px）。地点查询 / 出行路线 / 赛道研判三处因此口径完全一致。
///
/// ## 时间对齐（2026-09-22 修复）
/// 过去有一个**时间轴错配**的 bug：调用方传进来的 `models` 是**目标时刻**
/// 的预报（路线页是「到达时刻」、地点页点选未来某格也是），但打分却拿
/// **当前**回波去比 —— 于是「未来用时」的定调结果不准。
/// 现在按 [horizonOverride] 区分：目标在未来且在外推可信范围内时，
/// 用**外推预测值**参与打分，并在 [RadarVerdict.scoreBasis] 里如实标注。
class RadarVerdictEngine {
  RadarVerdictEngine._();

  /// 默认外推时间窗（分钟）
  static const int horizonMinutes = 60;

  /// 综合判定
  ///
  /// [horizonOverride] 可指定外推提前量（分钟）。用户在地点查询页
  /// 点选「未来 12 小时」中的某一格、或路线页按「出发/到达时刻」研判时，
  /// 会传入「该时刻距今的分钟数」，从而给出**对应那个时刻**的回波外推预测。
  ///
  /// 超过 [RadarService.forecastMaxMinutes]（2 小时）时**不做外推**：
  /// 那种尺度下外推误差已经大于数值模式，雷达只提供当前实况参考，
  /// 且**不启用**雷达仲裁（避免用一份过期的依据去裁决未来）。
  static Future<RadarVerdict> judge({
    required double lat,
    required double lon,
    required List<MultiModelHourly> models,
    String? radarPath,
    int frameCount = 3,
    Duration timeout = const Duration(seconds: 40),
    int? horizonOverride,
  }) async {
    try {
      return await _judgeInner(
        lat: lat,
        lon: lon,
        models: models,
        radarPath: radarPath,
        frameCount: frameCount,
        horizonOverride: horizonOverride,
      ).timeout(timeout);
    } catch (e) {
      return RadarVerdict(summary: '雷达分析失败: $e');
    }
  }

  static Future<RadarVerdict> _judgeInner({
    required double lat,
    required double lon,
    required List<MultiModelHourly> models,
    required String? radarPath,
    required int frameCount,
    required int? horizonOverride,
  }) async {
    // 目标时刻是否为「未来」、以及外推是否可信
    final futureTarget = horizonOverride != null && horizonOverride > 0;
    final beyondNowcast = futureTarget &&
        horizonOverride > RadarService.forecastMaxMinutes;
    final leadMinutes = beyondNowcast
        ? RadarService.forecastMaxMinutes
        : (horizonOverride ?? horizonMinutes);

    // 1. 选源：单站优先（≤60 分钟有更新），查过且过期才回退拼图
    final source = await RadarSourcePicker.pick(
      lat: lat,
      lon: lon,
      mapRadarPath: radarPath,
      count: frameCount,
    );
    // 目标点必须在雷达覆盖范围内 —— 否则「无回波」是假象
    // （海外赛道、中国西部等区域落在这里）。
    // ⚠️ 必须**先于** isEmpty 判断：海外场景下选源会带回空帧，
    // 若先判 isEmpty 就会给出误导性的「雷达图拉取失败」。
    if (!source.projection.covers(lat, lon)) {
      return RadarVerdict(
        summary: '该位置不在雷达覆盖范围内（雷达仅覆盖中国 · ${source.label}）',
        sourceLabel: source.label,
        fromStation: source.fromStation,
      );
    }

    if (source.isEmpty) {
      return RadarVerdict(
        summary: '雷达图拉取失败（${source.label}）',
        sourceLabel: source.label,
        fromStation: source.fromStation,
      );
    }

    // 2. 逐帧分析（投影来自所选源，单站/拼图共用同一套换算）
    final analyzed = <RadarFrame>[];
    for (final f in source.frames) {
      final a = await RadarService.analyze(f.bytes, f.time,
          projection: source.projection);
      if (a != null) analyzed.add(a);
    }
    if (analyzed.isEmpty) {
      return RadarVerdict(
        summary: '雷达图解码失败（${source.label}）',
        sourceLabel: source.label,
        fromStation: source.fromStation,
      );
    }
    analyzed.sort((a, b) => a.time.compareTo(b.time));
    final latest = analyzed.last;

    // 3. 目标点当前回波
    final dbz = RadarService.sampleAt(latest, lat, lon);
    final rain = dbz == null ? null : RadarService.dbzToRainRate(dbz);

    // 4. 运动矢量 + **目标点回波外推预测**
    //
    // 旧实现用「外推质心与目标点的距离 < 150km」判断是否可能被影响 ——
    // 过于粗糙（150km 内的回波未必会飘到目标点，方向不对也没用）。
    // 现在改为把回波场沿运动矢量整体外推，**直接预测目标点未来的回波强度**：
    //   目标点 T 在 t 分钟后 ≡ 当前位置 (T − v·t) 处的当前回波
    final motion = RadarService.estimateMotion(analyzed);
    int? dbzForecast;
    double? rainForecast;
    var expectedRain = false;
    if (motion != null && latest.hasEcho && !beyondNowcast) {
      dbzForecast =
          RadarService.forecastDbzAt(latest, motion, lat, lon, leadMinutes);
      if (dbzForecast != null && dbzForecast >= 5) {
        rainForecast = RadarService.dbzToRainRate(dbzForecast);
        expectedRain = true;
      }
    }

    final pointVerdict = RadarPointVerdict(
      time: latest.time,
      dbzNow: dbz,
      rainNow: rain,
      expectedRainAhead: expectedRain,
      framesUsed: analyzed.length,
      maxDbz: latest.maxDbz,
      coverage: latest.coverage,
      motionSpeedKmh: motion?.speedKmh,
      motionDirection: motion?.directionText,
      dbzForecast: dbzForecast,
      rainForecast: rainForecast,
      leadMinutes: leadMinutes,
      fromStation: source.fromStation,
      sourceLabel: source.label,
      kmPerPixel: source.projection.kmPerPixel,
    );

    // 5. 各模型打分 —— **必须用与模型同一时刻的雷达值**
    //
    // ⚠️ 两条硬规则（都是实测踩出来的）：
    //
    // ① **时间对齐**：models 是「目标时刻」的预报，若拿**当前**回波去比就是
    //    时间轴错配。目标在未来、外推可信、且同点有外推值时 → 用外推值打分。
    //
    // ② **超出外推可信范围时一个都不打**（scores 保持为空）。
    //    这不是图省事，而是调用方的语义依赖：路线页会依据 `bestModelKey` 用
    //    「雷达判出的最优源」重建整条路线的分段，地点页也会切换中心点显示。
    //    若几天后的行程还能拿到 bestModelKey，它们就会照常按雷达重建 ——
    //    表现正是**「选了很远的时间，雷达定调却没降级」**（实测 bug）。
    //    scores 为空 → bestModelKey 为 null → 调用方不动 → 真正的多源融合。
    final scores = <ModelScore>[];
    String scoreBasis;

    if (beyondNowcast) {
      scoreBasis = '目标时刻超出雷达外推可信范围'
          '（>${RadarService.forecastMaxMinutes} 分钟），未用雷达定调，以多源融合为准';
    } else {
      final useForecastForScore = futureTarget && dbzForecast != null;
      final scoreDbz = useForecastForScore ? dbzForecast : dbz;
      final scoreRain = useForecastForScore ? rainForecast : rain;

      scoreBasis = useForecastForScore
          ? '按 $leadMinutes 分钟后外推值比对'
          : (futureTarget
              // 目标确实是未来时刻，但该点当前无回波 → 外推拿不到值。
              // 必须说清楚，否则用户看到「按当前回波比对」会以为系统用错了时刻。
              ? '目标是 $leadMinutes 分钟后，但该点当前无回波、无可用外推值 → 按当前回波比对'
              : '按当前回波比对');

      for (final src
          in (models.isNotEmpty ? models.first.sources : <ModelForecast>[])) {
        scores.add(_scoreModel(src, scoreDbz, scoreRain,
            basis: useForecastForScore ? '$leadMinutes 分钟后外推' : null));
      }
      scores.sort((a, b) => b.score.compareTo(a.score));
    }

    // 6. 是否启用仲裁（模型间分歧大）
    //
    // 超出外推可信范围时**不仲裁**：用当前回波去裁决几天后的分歧没有意义，
    // 那种情况应由多源融合自行给出结论。
    final spread = models.isNotEmpty ? models.first.precipProbSpread : null;
    final arbitration = !beyondNowcast && spread != null && spread > 30;

    return RadarVerdict(
      radar: pointVerdict,
      scores: scores,
      bestModel: scores.isEmpty ? null : scores.first.modelName,
      bestModelKey: scores.isEmpty ? null : scores.first.modelKey,
      summary: _summarize(
        pointVerdict,
        scores,
        arbitration,
        source: source,
        futureTarget: futureTarget,
        beyondNowcast: beyondNowcast,
        scoreBasis: scoreBasis,
      ),
      arbitrationUsed: arbitration,
      scoreBasis: scoreBasis,
      fromStation: source.fromStation,
      sourceLabel: source.label,
      beyondNowcast: beyondNowcast,
    );
  }

  /// 模型 vs 雷达实况打分
  ///
  /// [basis] 非空时表示用的是**外推预测值**（而非实测），会在理由里注明。
  static ModelScore _scoreModel(
    ModelForecast src,
    int? radarDbz,
    double? radarRain, {
    String? basis,
  }) {
    final modelRain = src.precipitation ?? 0;
    final modelProb = src.precipitationProbability ?? 0;
    final modelSaysRain = modelRain >= 0.1 || modelProb >= 50;
    final radarSaysRain = radarDbz != null && radarDbz >= 5;

    var score = 50;
    final reasons = <String>[];

    // ① 有无降水的一致性（权重最大）
    if (modelSaysRain == radarSaysRain) {
      score += 25;
      reasons.add(radarSaysRain ? '与雷达一致(有雨)' : '与雷达一致(无雨)');
    } else {
      score -= 25;
      reasons.add(radarSaysRain ? '雷达有回波但模型未报' : '模型报雨但雷达无回波');
    }

    // ② 降水强度量级接近度
    if (radarSaysRain && modelSaysRain) {
      final rDbz = RadarService.dbzToRainRate(radarDbz);
      final diff = (modelRain - rDbz).abs();
      if (diff < 1) {
        score += 20;
        reasons.add('强度接近');
      } else if (diff < 3) {
        score += 8;
        reasons.add('强度略差');
      } else {
        score -= 10;
        reasons.add('强度差异大');
      }
    }

    // ③ 实测源小额加分（中央气象台实况更贴近雷达）
    if (src.isObservation) {
      score += 5;
      reasons.add('实况源');
    }

    if (basis != null) reasons.add('依据$basis');

    return ModelScore(
      modelKey: src.model,
      modelName: src.displayName,
      score: score.clamp(0, 100),
      reason: reasons.join('，'),
    );
  }

  static String _summarize(
    RadarPointVerdict r,
    List<ModelScore> scores,
    bool arbitration, {
    required RadarSource source,
    required bool futureTarget,
    required bool beyondNowcast,
    required String scoreBasis,
  }) {
    final parts = <String>[];
    parts.add('数据源: ${source.label}（${source.resolutionText}）');
    parts.add('雷达实况: ${r.echoText}');
    if (r.rainNow != null && r.rainNow! >= 0.1) {
      parts.add('反演降水 ${r.rainNow!.toStringAsFixed(1)} mm/h');
    }
    if (r.motionSpeedKmh != null && r.motionSpeedKmh! > 1) {
      parts.add('回波向${r.motionDirection}移动 ${r.motionSpeedKmh!.toStringAsFixed(0)} km/h');
    }

    if (beyondNowcast) {
      parts.add('目标时刻超出外推范围，未用雷达定调');
      return parts.join(' · ');
    }

    if (futureTarget) {
      parts.add('${r.leadMinutes} 分钟后外推: ${r.forecastText}');
    } else if (r.expectedRainAhead) {
      parts.add('未来 ${r.leadMinutes} 分钟可能受影响');
    }

    if (arbitration && scores.isNotEmpty) {
      parts.add('模型分歧较大 → 以雷达为准，最吻合: ${scores.first.modelName}');
    } else if (scores.isNotEmpty) {
      parts.add('最吻合模型: ${scores.first.modelName}');
    }
    parts.add(scoreBasis);
    return parts.join(' · ');
  }
}
