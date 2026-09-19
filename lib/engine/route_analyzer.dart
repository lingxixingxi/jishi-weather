import 'dart:math' as math;

import '../models/hourly_weather.dart';
import '../services/amap_service.dart';

/// 路线分段结果（一个 SEG）
class RouteSegment {
  /// 段序号（从 1 开始）
  final int index;
  final String fromName;
  final String toName;

  /// 里程区间（km）
  final double startKm;
  final double endKm;

  /// 时间区间
  final DateTime startTime;
  final DateTime endTime;

  // ===== 天气结论 =====
  final double? temperature;
  final double? precipitation;
  final String precipitationLevel; // 无雨/小雨/中雨/大雨/暴雨
  final int? precipitationProbability;
  final double? windSpeed;
  final String? weatherText;

  /// 建议等级：绿 / 黄 / 红
  final String grade;

  /// 多源一致性评分（0~100，100 = 各源完全一致）
  final int? agreementScore;

  /// 多源一致性文字：多源一致 / 略有分歧 / 分歧较大
  final String? agreementText;

  /// 参与比对的源数
  final int? sourceCount;

  /// **本段最终采用的数据源**展示名
  ///
  /// 若雷达定调判出了最吻合的源，则本段各要素取自该源；
  /// 否则为 null（表示用多源融合值）。
  final String? adoptedSource;

  /// 研判依据（展示用）
  final List<({String label, String value})> basis;

  /// **该分段对应的路线点**（用于点击分段时地图缩放到这一段）
  final List<({double lat, double lon})> points;

  const RouteSegment({
    required this.index,
    required this.fromName,
    required this.toName,
    required this.startKm,
    required this.endKm,
    required this.startTime,
    required this.endTime,
    required this.grade,
    required this.basis,
    this.points = const [],
    this.agreementScore,
    this.agreementText,
    this.sourceCount,
    this.adoptedSource,
    this.temperature,
    this.precipitation,
    this.precipitationLevel = '未知',
    this.precipitationProbability,
    this.windSpeed,
    this.weatherText,
  });
}

/// 整条路线的研判结果
class RouteAnalysis {
  final List<RouteSegment> segments;
  final double totalKm;
  final int totalMinutes;
  final String originName;
  final String destinationName;

  /// 全程总评等级
  final String overallGrade;

  const RouteAnalysis({
    required this.segments,
    required this.totalKm,
    required this.totalMinutes,
    required this.originName,
    required this.destinationName,
    required this.overallGrade,
  });
}

/// 路线研判引擎（纯函数，无 IO）
///
/// 流程：沿途采样点 + 各点逐小时天气 → 按到达时刻取值 → 按天气突变切段。
class RouteAnalyzer {
  RouteAnalyzer._();

  /// 沿途采样间隔（km）——与 Python 版计划的「抽点间隔公里」一致
  static const double sampleIntervalKm = 10;

  /// 最小区段长度（km）
  ///
  /// 短于此的段会与相邻段合并，避免出现 1~2km 的碎片段
  /// （那会让同一路段每次切出的段数都不一样）。
  static const double minSegmentKm = 15;

  /// 天气特征签名 —— 用于判断「天气是否发生突变」从而切段
  ///
  /// ⚠️ 只用**降水强度等级**，**不掺入天气文字**。
  /// 原因：天气文字（"毛毛雨"/"小雨"/"多云"）各源表述不同，
  /// 且融合值取的是第一个源的文字，数据一更新文字就变，
  /// 会导致同一路段每次切出的段数不一致（用户反馈的问题）。
  /// 降水强度等级来自降水量（连续量的离散化），稳定得多。
  static String signature(HourlyWeather? w) {
    if (w == null) return '未知';
    return w.precipitationLevel;
  }

  /// 给每个采样点按到达时刻挑出对应小时的天气
  ///
  /// [samples] 采样点序列；[pointForecasts] 与 samples 一一对应的逐小时数据；
  /// [departAt] 出发时刻；[totalMinutes] 全程预计耗时。
  static List<HourlyWeather?> pickAtArrival({
    required List<({GeoPoint point, double kmFromStart})> samples,
    required List<List<HourlyWeather>> pointForecasts,
    required DateTime departAt,
    required int totalMinutes,
    required double totalKm,
  }) {
    final out = <HourlyWeather?>[];
    for (var i = 0; i < samples.length; i++) {
      final km = samples[i].kmFromStart;
      final frac = totalKm <= 0 ? 0.0 : (km / totalKm).clamp(0.0, 1.0);
      final arriveAt = departAt.add(Duration(minutes: (totalMinutes * frac).round()));
      final list = i < pointForecasts.length ? pointForecasts[i] : const <HourlyWeather>[];
      out.add(_nearestHour(list, arriveAt));
    }
    return out;
  }

  /// 找最接近目标时刻的一条（同小时取第一条）
  static HourlyWeather? _nearestHour(List<HourlyWeather> list, DateTime target) {
    if (list.isEmpty) return null;
    HourlyWeather? best;
    var bestDiff = const Duration(days: 999).inMinutes;
    for (final w in list) {
      final diff = (w.time.difference(target).inMinutes).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = w;
      }
    }
    return best;
  }

  /// 按天气突变把采样序列切成若干段
  ///
  /// 合并规则：相邻采样点的「降水等级 + 天气现象」一致则归为同段；
  /// 全程天气一致 → 合成 1 段（与 Python 版计划描述一致）。
  static List<RouteSegment> buildSegments({
    required List<({GeoPoint point, double kmFromStart})> samples,
    required List<HourlyWeather?> weathers,
    required DateTime departAt,
    required int totalMinutes,
    required double totalKm,
    required String originName,
    required String destinationName,
    /// 完整路线点（用于截取每个分段对应的真实路径，供地图按段缩放）
    List<GeoPoint> fullPolyline = const [],

    /// **多源交叉验证数据**（与 samples 一一对应，元素可为 null）
    List<MultiModelHourly?> multiModels = const [],

    /// **优先采用的数据源标识**（如 `ecmwf_ifs025`）
    ///
    /// 雷达定调判出最吻合源后，用它重建分段 —— 各要素取自该源，
    /// 而不是多源平均值。传 null 表示用融合值。
    String? preferredModel,
  }) {
    if (samples.isEmpty) return const [];

    // 1) 计算每个采样点的到达时刻
    final times = <DateTime>[];
    for (final s in samples) {
      final frac = totalKm <= 0 ? 0.0 : (s.kmFromStart / totalKm).clamp(0.0, 1.0);
      times.add(departAt.add(Duration(minutes: (totalMinutes * frac).round())));
    }

    // 2) 找出「天气特征」变化的边界（签名只用稳定的降水强度等级）
    final rawBounds = <int>[0];
    for (var i = 1; i < samples.length; i++) {
      if (signature(weathers[i]) != signature(weathers[i - 1])) {
        rawBounds.add(i);
      }
    }

    // 3) 合并过短的段 —— 避免碎片段让「同一路段每次段数不一样」
    final bounds = <int>[rawBounds.first];
    for (var i = 1; i < rawBounds.length; i++) {
      final km = samples[rawBounds[i]].kmFromStart - samples[bounds.last].kmFromStart;
      if (km >= minSegmentKm) bounds.add(rawBounds[i]);
    }
    // 末段若不足最小区段长度，则并入前一段
    while (bounds.length > 1 &&
        (samples.last.kmFromStart - samples[bounds.last].kmFromStart) < minSegmentKm) {
      bounds.removeLast();
    }

    // 4) 逐段构造
    final segments = <RouteSegment>[];
    for (var b = 0; b < bounds.length; b++) {
      final startIdx = bounds[b];
      final endIdx = (b + 1 < bounds.length) ? bounds[b + 1] : samples.length - 1;
      final w = weathers[startIdx];

      final startKm = samples[startIdx].kmFromStart;
      final endKm = samples[endIdx].kmFromStart;
      final startTime = times[startIdx];
      final endTime = times[endIdx];

      final fromName = b == 0
          ? originName
          : _label(samples[startIdx].point, originName, destinationName, startKm, totalKm);
      final toName = (b + 1 == bounds.length)
          ? destinationName
          : _label(samples[endIdx].point, originName, destinationName, endKm, totalKm);

      segments.add(_makeSegment(
        index: b + 1,
        fromName: fromName,
        toName: toName,
        startKm: startKm,
        endKm: endKm,
        startTime: startTime,
        endTime: endTime,
        w: w,
        points: _sliceByKm(fullPolyline, startKm, endKm),
        mm: startIdx < multiModels.length ? multiModels[startIdx] : null,
        preferredModel: preferredModel,
      ));
    }
    return segments;
  }

  /// 按里程区间从完整路线中截取点（用于「点击分段→地图缩放到该段」）
  ///
  /// 若区间内点太少，会向两端各扩展一个点，保证能看出走向。
  static List<({double lat, double lon})> _sliceByKm(
    List<GeoPoint> full,
    double startKm,
    double endKm,
  ) {
    if (full.isEmpty) return const [];
    if (full.length == 1) return [(lat: full.first.lat, lon: full.first.lon)];

    final out = <({double lat, double lon})>[];
    var acc = 0.0;
    for (var i = 1; i < full.length; i++) {
      final a = full[i - 1];
      final b = full[i];
      final d = _haversineKm(a.lat, a.lon, b.lat, b.lon);
      final segStart = acc;
      final segEnd = acc + d;
      // 该小段与目标里程区间有交集
      if (segEnd >= startKm && segStart <= endKm) {
        if (out.isEmpty) out.add((lat: a.lat, lon: a.lon));
        out.add((lat: b.lat, lon: b.lon));
      }
      acc = segEnd;
      if (acc > endKm + 1) break;
    }
    if (out.isEmpty) {
      // 兜底：整条路线的首尾
      return [
        (lat: full.first.lat, lon: full.first.lon),
        (lat: full.last.lat, lon: full.last.lon),
      ];
    }
    return out;
  }

  /// 计算完整路线的总里程（用于校验截取是否正确）
  static double totalKmOf(List<GeoPoint> full) {
    var acc = 0.0;
    for (var i = 1; i < full.length; i++) {
      acc += _haversineKm(full[i - 1].lat, full[i - 1].lon, full[i].lat, full[i].lon);
    }
    return acc;
  }

  /// 两点球面距离（km）
  static double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLon = (lon2 - lon1) * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static String _label(GeoPoint p, String origin, String dest, double km, double totalKm) {
    if (km <= 0.5) return origin;
    if (totalKm > 0 && km >= totalKm - 0.5) return dest;
    return '${km.round()}km 处';
  }

  static RouteSegment _makeSegment({
    required int index,
    required String fromName,
    required String toName,
    required double startKm,
    required double endKm,
    required DateTime startTime,
    required DateTime endTime,
    required HourlyWeather? w,
    List<({double lat, double lon})> points = const [],
    MultiModelHourly? mm,
    String? preferredModel,
  }) {
    // 若指定了优先源（雷达定调判出的最吻合源），改用该源的值
    ModelForecast? chosen;
    if (mm != null && preferredModel != null) {
      for (final s in mm.sources) {
        if (s.model == preferredModel) {
          chosen = s;
          break;
        }
      }
    }

    // 有效值：优先取 chosen，缺失时退回融合值
    final eff = HourlyWeather(
      place: w?.place ?? '',
      lat: w?.lat ?? 0,
      lon: w?.lon ?? 0,
      time: w?.time ?? startTime,
      source: chosen?.displayName ?? w?.source ?? 'multi-model',
      temperature: chosen?.temperature ?? w?.temperature,
      precipitationProbability:
          chosen?.precipitationProbability ?? w?.precipitationProbability,
      precipitation: chosen?.precipitation ?? w?.precipitation,
      windSpeed: chosen?.windSpeed ?? w?.windSpeed,
      windDirection: chosen?.windDirection ?? w?.windDirection,
      windGust: chosen?.windGust ?? w?.windGust,
      visibility: chosen?.visibility ?? w?.visibility,
      cloudCover: chosen?.cloudCover ?? w?.cloudCover,
      weatherCode: chosen?.weatherCode ?? w?.weatherCode,
      weatherText: chosen?.weatherText ?? w?.weatherText,
    );

    final grade = gradeOf(eff);
    final basis = <({String label, String value})>[
      (
        label: '采用源',
        value: chosen == null
            ? '多源融合（${mm?.sources.length ?? 1} 源平均）'
            : '${chosen.displayName}（雷达定调最吻合）',
      ),
      (label: '到达时刻', value: '${_hhmm(startTime)} – ${_hhmm(endTime)}'),
      (label: '里程区间', value: '${startKm.toStringAsFixed(0)} – ${endKm.toStringAsFixed(0)} km'),
      (label: '降水强度', value: eff.precipitationLevel),
      (
        label: '降水量',
        value: eff.precipitation == null ? '—' : '${eff.precipitation!.toStringAsFixed(1)} mm/h'
      ),
      (
        label: '降水概率',
        value: eff.precipitationProbability == null ? '—' : '${eff.precipitationProbability}%'
      ),
      (label: '能见度', value: eff.visibility == null ? '—' : '${eff.visibility!.toStringAsFixed(1)} km'),
      (label: '风速', value: eff.windSpeed == null ? '—' : '${eff.windSpeed!.toStringAsFixed(1)} km/h'),
    ];

    // ===== 多源交叉验证：并列展示各源数值，便于判断可信度 =====
    if (mm != null && mm.sources.length >= 2) {
      final t = mm.spreadText((s) => s.temperature, digits: 1, unit: '℃');
      if (t.isNotEmpty) basis.add((label: '多源温度', value: t));

      final pp = mm.spreadText((s) => s.precipitationProbability?.toDouble(), digits: 0, unit: '%');
      if (pp.isNotEmpty) basis.add((label: '多源降水概率', value: pp));

      final pr = mm.spreadText((s) => s.precipitation, digits: 1, unit: '');
      if (pr.isNotEmpty) basis.add((label: '多源降水', value: pr));

      final gs = mm.spreadText((s) => s.windGust, digits: 0, unit: '');
      if (gs.isNotEmpty) basis.add((label: '多源阵风', value: gs));

      basis.add((
        label: '一致性',
        value: '${mm.agreementScore} 分 · ${mm.agreementText}（${mm.sources.length} 源）',
      ));
    }

    return RouteSegment(
      index: index,
      fromName: fromName,
      toName: toName,
      startKm: startKm,
      endKm: endKm,
      startTime: startTime,
      endTime: endTime,
      temperature: eff.temperature,
      precipitation: eff.precipitation,
      precipitationLevel: eff.precipitationLevel,
      precipitationProbability: eff.precipitationProbability,
      windSpeed: eff.windSpeed,
      weatherText: eff.weatherText,
      grade: grade,
      basis: basis,
      points: points,
      agreementScore: mm?.agreementScore,
      agreementText: mm?.agreementText,
      sourceCount: mm?.sources.length,
      adoptedSource: chosen?.displayName,
    );
  }

  /// 建议等级（绿/黄/红）——依据降水强度 + 能见度 + 风速
  static String gradeOf(HourlyWeather? w) {
    if (w == null) return '黄';
    final p = w.precipitation ?? 0;
    final vis = w.visibility;
    final wind = w.windSpeed ?? 0;

    // 红：大雨以上 / 能见度极差 / 大风
    if (p >= 8.0 || (vis != null && vis < 1.0) || wind >= 60) return '红';
    // 黄：中雨 / 能见度较差 / 风较大
    if (p >= 2.5 || (vis != null && vis < 5.0) || wind >= 40) return '黄';
    // 小雨也算黄（湿滑风险）
    if (p >= 0.1) return '黄';
    return '绿';
  }

  /// 全程总评：取最差等级
  static String worstGrade(Iterable<String> grades) {
    if (grades.contains('红')) return '红';
    if (grades.contains('黄')) return '黄';
    return '绿';
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
