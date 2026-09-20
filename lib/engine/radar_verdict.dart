import 'dart:async';

import '../models/hourly_weather.dart';
import '../services/radar_service.dart';

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
  });

  bool get hasEchoNow => dbzNow != null && dbzNow! >= 5;

  /// 外推预测是否有回波
  bool get hasEchoForecast => dbzForecast != null && dbzForecast! >= 5;

  String get echoText {
    if (!hasEchoNow) return '无回波';
    return '${RadarPalette.dbzLevel(dbzNow!)}（${dbzNow} dBZ）';
  }

  /// 外推预测的文字描述
  String get forecastText {
    if (dbzForecast == null) return '—';
    if (dbzForecast! < 5) return '无回波';
    return '${RadarPalette.dbzLevel(dbzForecast!)}（${dbzForecast} dBZ）';
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

  const RadarVerdict({
    this.radar,
    this.scores = const [],
    this.bestModel,
    this.bestModelKey,
    this.summary = '',
    this.arbitrationUsed = false,
  });
}

/// 雷达定调引擎
///
/// 当各数值模型分歧较大时，用**真实雷达回波**作为裁决依据：
///   1. 取最近若干帧雷达拼图 → 逐帧反演 dBZ
///   2. 判断目标点当前是否有回波、回波往哪移动
///   3. 与各模型的「是否有雨 / 降水强度」预测比对打分
///   4. 得分最高者即为「最可信模型」，同时也能反过来校验模型准确度
///
/// 这正是用户要的「模型吵得凶时用雷达定调」。
class RadarVerdictEngine {
  RadarVerdictEngine._();

  /// 外推时间窗（分钟）
  static const int horizonMinutes = 60;

  /// 综合判定
  static Future<RadarVerdict> judge({
    required double lat,
    required double lon,
    required List<MultiModelHourly> models,
    String? radarPath,
    int frameCount = 3,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (radarPath == null || radarPath.isEmpty) {
      return const RadarVerdict(summary: '无雷达数据');
    }

    try {
      return await _judgeInner(
        lat: lat,
        lon: lon,
        models: models,
        radarPath: radarPath,
        frameCount: frameCount,
      ).timeout(timeout);
    } catch (e) {
      return RadarVerdict(summary: '雷达分析失败: $e');
    }
  }

  static Future<RadarVerdict> _judgeInner({
    required double lat,
    required double lon,
    required List<MultiModelHourly> models,
    required String radarPath,
    required int frameCount,
  }) async {
    // 1. 拉最近几帧
    final frames = await RadarService.fetchRecentFrames(
      radarPath: radarPath,
      count: frameCount,
    );
    if (frames.isEmpty) {
      return const RadarVerdict(summary: '雷达图拉取失败');
    }

    // 2. 逐帧分析
    final analyzed = <RadarFrame>[];
    for (final f in frames) {
      final a = await RadarService.analyze(f.bytes, f.time);
      if (a != null) analyzed.add(a);
    }
    if (analyzed.isEmpty) {
      return const RadarVerdict(summary: '雷达图解码失败');
    }
    analyzed.sort((a, b) => a.time.compareTo(b.time));
    final latest = analyzed.last;

    // 3. 目标点查询
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
    if (motion != null && latest.hasEcho) {
      dbzForecast = RadarService.forecastDbzAt(latest, motion, lat, lon, horizonMinutes);
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
      leadMinutes: horizonMinutes,
    );

    // 5. 各模型打分
    final scores = <ModelScore>[];
    for (final src in (models.isNotEmpty ? models.first.sources : <ModelForecast>[])) {
      scores.add(_scoreModel(src, dbz, rain));
    }
    scores.sort((a, b) => b.score.compareTo(a.score));

    // 6. 是否启用仲裁（模型间分歧大）
    final spread = models.isNotEmpty ? models.first.precipProbSpread : null;
    final arbitration = spread != null && spread > 30;

    return RadarVerdict(
      radar: pointVerdict,
      scores: scores,
      bestModel: scores.isEmpty ? null : scores.first.modelName,
      bestModelKey: scores.isEmpty ? null : scores.first.modelKey,
      summary: _summarize(pointVerdict, scores, arbitration),
      arbitrationUsed: arbitration,
    );
  }

  /// 模型 vs 雷达实况打分
  static ModelScore _scoreModel(ModelForecast src, int? radarDbz, double? radarRain) {
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
    bool arbitration,
  ) {
    final parts = <String>[];
    parts.add('雷达实况: ${r.echoText}');
    if (r.rainNow != null && r.rainNow! >= 0.1) {
      parts.add('反演降水 ${r.rainNow!.toStringAsFixed(1)} mm/h');
    }
    if (r.motionSpeedKmh != null && r.motionSpeedKmh! > 1) {
      parts.add('回波向${r.motionDirection}移动 ${r.motionSpeedKmh!.toStringAsFixed(0)} km/h');
    }
    if (r.expectedRainAhead) {
      parts.add('未来 ${RadarVerdictEngine.horizonMinutes} 分钟可能受影响');
    }
    if (arbitration && scores.isNotEmpty) {
      parts.add('模型分歧较大 → 以雷达为准，最吻合: ${scores.first.modelName}');
    } else if (scores.isNotEmpty) {
      parts.add('最吻合模型: ${scores.first.modelName}');
    }
    return parts.join(' · ');
  }

  static double _sqrt(double v) {
    var x = v;
    var y = 1.0;
    for (var i = 0; i < 12; i++) {
      y = (y + x / y) / 2;
    }
    return y;
  }
}
