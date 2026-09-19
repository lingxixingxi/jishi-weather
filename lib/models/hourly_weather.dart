/// 统一小时气象模型
///
/// 所有数据源（Open-Meteo / ECMWF / 台风网…）标准化后对齐到本结构。
/// 对应 Python 版计划的 `小时气象` dataclass。
class HourlyWeather {
  /// 地点名（或 "纬度,经度"）
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
  String get precipitationLevel {
    final p = precipitation;
    if (p == null) return '未知';
    if (p < 0.1) return '无雨';
    if (p < 2.5) return '小雨';
    if (p < 8.0) return '中雨';
    if (p < 16.0) return '大雨';
    return '暴雨';
  }

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
