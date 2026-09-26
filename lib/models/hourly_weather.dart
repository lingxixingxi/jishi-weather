import '../engine/weather_estimator.dart';

/// 统一小时气象模型
///
/// 所有数据源（Open-Meteo / ECMWF / 台风网…）标准化后对齐到本结构。
/// 对应 Python 版计划的 `小时气象` dataclass。
class HourlyWeather {  /// 地点名（或 "纬度,经度"）
  final String place;
  final double lat;
  final double lon;

  /// 时间（本地时区整点）
  final DateTime time;

  final double? temperature; // 摄氏度
  final int? precipitationProbability; // 0-100 %
  final double? precipitation; // mm/h
  final String? precipitationType; // 无/雨/雪/冻雨/冰雹
  final double? windSpeed; // km/h
  final int? windDirection; // 度
  final double? windGust; // km/h
  final double? visibility; // km
  final String? weatherText; // 天气现象（来源原词）
  final double? cloudCover; // %
  final int? weatherCode; // WMO 代码

  /// 数据源标识：open-meteo / ecmwf / qweather / nmc
  final String source;

  const HourlyWeather({
    required this.place,
    required this.lat,
    required this.lon,
    required this.time,
    required this.source,
    this.temperature,
    this.precipitationProbability,
    this.precipitation,
    this.precipitationType,
    this.windSpeed,
    this.windDirection,
    this.windGust,
    this.visibility,
    this.weatherText,
    this.cloudCover,
    this.weatherCode,
  });

  /// 降水强度分级（mm/h）—— 与 Python 版 `降水强度分级()` 保持一致
  ///
  /// 提成 static 是为了让**非 HourlyWeather 场景**（如中心点文本决策）复用
  /// 同一套界限，避免各处自己写一遍导致分级漂移。
  static String levelOf(double? mmh) {
    if (mmh == null) return '未知';
    if (mmh < 0.1) return '无雨';
    if (mmh < 2.5) return '小雨';
    if (mmh < 8.0) return '中雨';
    if (mmh < 16.0) return '大雨';
    return '暴雨';
  }

  String get precipitationLevel => levelOf(precipitation);

  /// 是否有降水（用于分段判断）
  bool get hasRain => (precipitation ?? 0) >= 0.1;

  factory HourlyWeather.fromJson(Map<String, dynamic> json, {String source = 'open-meteo'}) {
    return HourlyWeather(
      place: json['place'] as String? ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0,
      lon: (json['lon'] as num?)?.toDouble() ?? 0,
      time: DateTime.parse(json['time'] as String),
      temperature: (json['temperature'] as num?)?.toDouble(),
      precipitationProbability: (json['precipitation_probability'] as num?)?.toInt(),
      precipitation: (json['precipitation'] as num?)?.toDouble(),
      precipitationType: json['precipitation_type'] as String?,
      windSpeed: (json['wind_speed'] as num?)?.toDouble(),
      windDirection: (json['wind_direction'] as num?)?.toInt(),
      windGust: (json['wind_gust'] as num?)?.toDouble(),
      visibility: (json['visibility'] as num?)?.toDouble(),
      weatherText: json['weather_text'] as String?,
      cloudCover: (json['cloud_cover'] as num?)?.toDouble(),
      weatherCode: (json['weather_code'] as num?)?.toInt(),
      source: json['source'] as String? ?? source,
    );
  }
}

/// 单个数值模型的预报值（ECMWF / GFS / ICON / 和风 / 中央气象台各一条）
class ModelForecast {
  /// 模型标识，如 ecmwf_ifs025 / gfs_seamless / icon_seamless / qweather / nmc
  final String model;

  /// 展示用名，如「ECMWF」「GFS」「ICON」「和风」「中央气象台」
  final String displayName;

  final double? temperature;
  final double? humidity; // 相对湿度 %（能见度推算用）
  final int? precipitationProbability;
  final double? precipitation;
  final double? windSpeed;
  final int? windDirection;
  final double? windGust;
  final double? visibility;
  final double? cloudCover;
  final int? weatherCode;
  final String? weatherText;

  /// 是否为实测（中央气象台 passedchart 的过去时刻为实测）
  final bool isObservation;

  const ModelForecast({
    required this.model,
    required this.displayName,
    this.temperature,
    this.humidity,
    this.precipitationProbability,
    this.precipitation,
    this.windSpeed,
    this.windDirection,
    this.windGust,
    this.visibility,
    this.cloudCover,
    this.weatherCode,
    this.weatherText,
    this.isObservation = false,
  });

  /// 返回补全缺失字段后的副本（阵风/能见度/云量/降水概率）
  ///
  /// 中央气象台只有部分要素，补全后才能与 Open-Meteo 各模型同字段比对。
  ModelForecast enriched({double? precipProbSpread}) {
    final gust = windGust ??
        (windSpeed == null
            ? null
            : WeatherEstimator.estimateGust(
                windSpeed: windSpeed!,
                precipitation: precipitation,
                weatherCode: weatherCode,
              ));
    final vis = visibility ??
        WeatherEstimator.estimateVisibility(
          humidity: humidity ?? 70,
          precipitation: precipitation,
          weatherCode: weatherCode,
        );
    final cloud = cloudCover ??
        WeatherEstimator.estimateCloudCover(
          weatherCode: weatherCode,
          weatherText: weatherText,
          precipitation: precipitation,
        );
    final prob = WeatherEstimator.estimatePrecipProbability(
      precipitation: precipitation,
      providedProbability: precipitationProbability,
      probabilitySpread: precipProbSpread,
      humidity: humidity,
    );
    return ModelForecast(
      model: model,
      displayName: displayName,
      temperature: temperature,
      humidity: humidity,
      precipitationProbability: prob,
      precipitation: precipitation,
      windSpeed: windSpeed,
      windDirection: windDirection,
      windGust: gust,
      visibility: vis,
      cloudCover: cloud,
      weatherCode: weatherCode,
      // 天气文字缺失时用云量反推（中央气象台某些时刻取不到文字，
      // 不补的话 UI 会显示「无数据」）
      weatherText: (weatherText != null && weatherText!.isNotEmpty)
          ? weatherText
          : _textFromCloud(cloud, precipitation: precipitation),
      isObservation: isObservation,
    );
  }

  /// 由云量反推天气现象文字
  ///
  /// ⚠️ **有降水时必须先按降水强度给文字**（2026-09-26 修正，实测 bug）：
  /// 只看云量的话，下雨天云量必然 ≥85%（[WeatherEstimator.estimateCloudCover]
  /// 对降水直接给 90），反推结果**永远是「阴」** ——
  /// 实测把中央气象台 13.5 mm/h 的「大雨」显示成了「阴」。
  static String? _textFromCloud(double? cloud, {double? precipitation}) {
    final p = precipitation ?? 0;
    if (p >= 0.1) return HourlyWeather.levelOf(p);
    if (cloud == null) return null;
    if (cloud >= 85) return '阴';
    if (cloud >= 60) return '多云';
    if (cloud >= 30) return '少云';
    return '晴';
  }
}

/// 多源同时刻预报集合（用于交叉验证与分歧度计算）
///
/// 对应「多源比对」：同一地点同一时刻，各模型/各数据源的值并列。
class MultiModelHourly {
  final String place;
  final double lat;
  final double lon;
  final DateTime time;

  /// 参与比对的各源（至少 2 个才有比对意义）
  final List<ModelForecast> sources;

  const MultiModelHourly({
    required this.place,
    required this.lat,
    required this.lon,
    required this.time,
    required this.sources,
  });

  /// 追加一个数据源（如中央气象台、和风天气），返回新实例
  MultiModelHourly withExtraSource(ModelForecast source) => MultiModelHourly(
        place: place,
        lat: lat,
        lon: lon,
        time: time,
        sources: [...sources, source],
      );

  /// 追加多个源
  MultiModelHourly withExtraSources(List<ModelForecast> extra) => MultiModelHourly(
        place: place,
        lat: lat,
        lon: lon,
        time: time,
        sources: [...sources, ...extra],
      );

  /// 仅保留指定模型（用于剔除某个源后重新计算分歧度）
  MultiModelHourly onlyModels(Set<String> keep) => MultiModelHourly(
        place: place,
        lat: lat,
        lon: lon,
        time: time,
        sources: sources.where((s) => keep.contains(s.model)).toList(),
      );

  /// 取某字段的全部有效值
  List<double> _values(double? Function(ModelForecast) pick) =>
      sources.map(pick).whereType<double>().toList();

  double? _mean(double? Function(ModelForecast) pick) {
    final v = _values(pick);
    if (v.isEmpty) return null;
    return v.reduce((a, b) => a + b) / v.length;
  }

  double? _spread(double? Function(ModelForecast) pick) {
    final v = _values(pick);
    if (v.length < 2) return null;
    return v.reduce((a, b) => a > b ? a : b) - v.reduce((a, b) => a < b ? a : b);
  }

  /// ===== 融合值（各源均值，作为最终采用值）=====
  double? get temperature => _mean((s) => s.temperature);
  double? get precipitation => _mean((s) => s.precipitation);
  double? get windSpeed => _mean((s) => s.windSpeed);
  double? get windGust => _mean((s) => s.windGust);
  double? get visibility => _mean((s) => s.visibility);
  double? get cloudCover => _mean((s) => s.cloudCover);
  int? get precipitationProbability {
    final v = _values((s) => s.precipitationProbability?.toDouble());
    if (v.isEmpty) return null;
    return (v.reduce((a, b) => a + b) / v.length).round();
  }

  /// ===== 分歧度（越大说明各源越不一致，可信度越低）=====
  double? get temperatureSpread => _spread((s) => s.temperature);
  double? get precipitationSpread => _spread((s) => s.precipitation);
  double? get precipProbSpread => _spread((s) => s.precipitationProbability?.toDouble());
  double? get windGustSpread => _spread((s) => s.windGust);

  /// 综合分歧评分 0~100（100 = 完全一致，0 = 分歧极大）
  ///
  /// 权重：降水概率分歧影响最大（最影响出行决策），其次温度。
  int get agreementScore {
    var score = 100.0;
    var weight = 0.0;

    final ps = precipProbSpread;
    if (ps != null) {
      score -= (ps / 100 * 60).clamp(0, 60);
      weight += 1;
    }
    final ts = temperatureSpread;
    if (ts != null) {
      score -= (ts / 6 * 25).clamp(0, 25);
      weight += 1;
    }
    final gs = windGustSpread;
    if (gs != null) {
      score -= (gs / 25 * 15).clamp(0, 15);
      weight += 1;
    }
    if (weight == 0) return 100;
    return score.clamp(0, 100).round();
  }

  /// 一致 / 略有分歧 / 分歧较大
  String get agreementText {
    final s = agreementScore;
    if (s >= 80) return '多源一致';
    if (s >= 60) return '略有分歧';
    return '分歧较大';
  }

  /// 某字段的三源展示串，如 `ECMWF 29.3 / GFS 27.2 / ICON 27.0`
  String spreadText(double? Function(ModelForecast) pick, {int digits = 1, String unit = ''}) {
    final parts = <String>[];
    for (final s in sources) {
      final v = pick(s);
      if (v == null) continue;
      parts.add('${s.displayName} ${v.toStringAsFixed(digits)}$unit');
    }
    return parts.join(' / ');
  }

  /// 各源的**天气现象文字**并列展示（诊断「晴天/阴天」不一致用）
  String get weatherTextSpread {
    final parts = <String>[];
    for (final s in sources) {
      final t = s.weatherText;
      if (t == null || t.isEmpty) continue;
      parts.add('${s.displayName} $t');
    }
    return parts.join(' / ');
  }

  /// 各源的**天气码**并列展示
  String get weatherCodeSpread {
    final parts = <String>[];
    for (final s in sources) {
      final c = s.weatherCode;
      if (c == null) continue;
      parts.add('${s.displayName} $c');
    }
    return parts.join(' / ');
  }

  /// **按云量共识判定天气现象**（比单源文字可靠）
  ///
  /// 各源云量普遍很高时（如 GFS/ICON/和风都 100%），即使第一个源报「晴」，
  /// 实际也应是「阴」—— 单取一个源的文字会出现「显示晴天、实际阴天很多云」。
  ///
  /// 规则：取各源云量的**中位数**，再按区间映射：
  /// ≥85% 阴 / 60~85% 多云 / 30~60% 少云 / <30% 晴
  String? get consensusWeatherText {
    final clouds = sources.map((s) => s.cloudCover).whereType<double>().toList();
    if (clouds.isEmpty) return null;
    clouds.sort();
    final median = clouds.length.isOdd
        ? clouds[clouds.length ~/ 2]
        : (clouds[clouds.length ~/ 2 - 1] + clouds[clouds.length ~/ 2]) / 2;
    if (median >= 85) return '阴';
    if (median >= 60) return '多云';
    if (median >= 30) return '少云';
    return '晴';
  }

  /// 中心点天气现象的**统一决策**（地点页「中心」行 / 区域概览共用）
  ///
  /// [sourceText] 是「最优源」自带的天气现象原文，[sourcePrecipitation] 是该源
  /// 同时刻的降水量（mm/h）。
  ///
  /// ⚠️ 规则（2026-09-26 二次修正）：
  /// · **有降水 → 一律按降水强度分级**（小雨/中雨/大雨/暴雨）
  /// · **无降水 → 云量共识**（共识拿不到时才退回该源原文）
  ///
  /// 为什么有降水时**不采用**该源的定性词：那会让「当前时刻」（走雷达定调的
  /// 最优源）显示源的定性词，而「未来时刻」（走融合值）显示强度分级 ——
  /// 同一位置相邻两小时自相矛盾。用户实测反馈：区域概览显示「毛毛雨」，
  /// 点一下 15 时变成「中雨」，无从判断哪个对。
  ///
  /// 按**小时雨量国标**分级是客观且各处一致的；实测央台 `info="暴雨"`
  /// 与 `rain1h=20.7mm/h` 的分级本就吻合，采用分级不会损失它的专业判断。
  String? effectiveWeatherText({
    required String? sourceText,
    required double? sourcePrecipitation,
  }) {
    final hasPrecip = (sourcePrecipitation ?? 0) >= 0.1;
    if (hasPrecip) return HourlyWeather.levelOf(sourcePrecipitation);
    return consensusWeatherText ?? sourceText;
  }

  /// 共识云量（各源中位数）
  double? get consensusCloudCover {
    final clouds = sources.map((s) => s.cloudCover).whereType<double>().toList();
    if (clouds.isEmpty) return null;
    clouds.sort();
    return clouds.length.isOdd
        ? clouds[clouds.length ~/ 2]
        : (clouds[clouds.length ~/ 2 - 1] + clouds[clouds.length ~/ 2]) / 2;
  }

  /// 生成一条 HourlyWeather（用融合值，source 标记为多源）
  ///
  /// **天气现象统一走 [effectiveWeatherText]** —— 地点页中心点、四个方位点、
  /// 7 天聚合因此走**完全同一套判断**：有降水用该源原文（缺失则按降水强度分级），
  /// 无降水才用各源云量共识。
  ///
  /// ⚠️ 旧实现是「有降水取 texts.first（**第一个源**的文字）」，与中心点取
  /// 「雷达定调最优源原文」的口径并不一致；再加上四个方位点当初只拉单模型，
  /// 实测出现「中心 大雨、四个方位全是毛毛雨」这种同页面两套判法的观感。
  HourlyWeather toHourlyWeather({String source = 'multi-model'}) {
    final codes = sources.map((s) => s.weatherCode).whereType<int>().toList();
    final texts = sources.map((s) => s.weatherText).whereType<String>().toList();

    // 与地点页「中心」行、区域概览**同一套**决策（含未来时刻）
    final effectiveText = effectiveWeatherText(
      sourceText: texts.isEmpty ? null : texts.first,
      sourcePrecipitation: precipitation,
    );

    return HourlyWeather(
      place: place,
      lat: lat,
      lon: lon,
      time: time,
      source: source,
      temperature: temperature,
      precipitationProbability: precipitationProbability,
      precipitation: precipitation,
      windSpeed: windSpeed,
      windGust: windGust,
      visibility: visibility,
      // 云量也用共识中位数（避免单源极端值）
      cloudCover: consensusCloudCover ?? cloudCover,
      weatherCode: codes.isEmpty ? null : codes.first,
      weatherText: effectiveText,
    );
  }
}

/// WMO 天气代码 → 中文（Open-Meteo 用）
const Map<int, String> wmoCodeText = {
  0: '晴',
  1: '基本晴',
  2: '多云',
  3: '阴',
  45: '雾',
  48: '雾凇',
  51: '毛毛雨',
  53: '毛毛雨',
  55: '毛毛雨',
  56: '冻毛毛雨',
  57: '冻毛毛雨',
  61: '小雨',
  63: '中雨',
  65: '大雨',
  66: '冻雨',
  67: '冻雨',
  71: '小雪',
  73: '中雪',
  75: '大雪',
  77: '米雪',
  80: '阵雨',
  81: '阵雨',
  82: '强阵雨',
  85: '阵雪',
  86: '强阵雪',
  95: '雷雨',
  96: '雷雨伴冰雹',
  99: '强雷雨伴冰雹',
};
