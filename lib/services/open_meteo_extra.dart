import 'dart:convert';

import 'package:http/http.dart' as http;

/// 扩展小时气象点（赛道 / 摄影功能专用）
///
/// 现有的 [HourlyWeather] 面向「出行」场景，不含蒸散、辐射、分层云量；
/// 赛道湿滑模型和摄影指数都需要这些量，因此单独拉一份**不污染主流程**。
class ExtraHourly {
  final DateTime time;
  final double? temperature; // °C
  final double? precipitation; // mm/h（该小时的降水）
  final double? et0; // mm/h 参考蒸散（FAO-56）
  final double? shortwave; // W/m² 短波辐射
  final double? cloudCover; // % 总云量
  final double? cloudLow; // % 低云
  final double? cloudMid; // % 中云
  final double? cloudHigh; // % 高云
  final double? humidity; // %
  final double? windSpeed; // km/h
  final double? visibility; // km
  final double? dewPoint; // °C
  final int? precipProb; // % 降水概率

  const ExtraHourly({
    required this.time,
    this.temperature,
    this.precipitation,
    this.et0,
    this.shortwave,
    this.cloudCover,
    this.cloudLow,
    this.cloudMid,
    this.cloudHigh,
    this.humidity,
    this.windSpeed,
    this.visibility,
    this.dewPoint,
    this.precipProb,
  });
}

/// 扩展气象结果（逐小时 + 日出日落）
class ExtraWeather {
  final List<ExtraHourly> hourly;
  final Map<String, DateTime> sunrise; // key: yyyy-MM-dd
  final Map<String, DateTime> sunset;

  const ExtraWeather({
    required this.hourly,
    this.sunrise = const {},
    this.sunset = const {},
  });

  bool get isEmpty => hourly.isEmpty;

  /// 最接近给定时刻的小时点
  ExtraHourly? nearest(DateTime t) {
    if (hourly.isEmpty) return null;
    ExtraHourly? best;
    var bestDiff = const Duration(days: 999).inMinutes;
    for (final h in hourly) {
      final d = h.time.difference(t).inMinutes.abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = h;
      }
    }
    return best;
  }

  /// [from, to) 区间内的所有小时点（用于「过去 6 小时降水」）
  List<ExtraHourly> between(DateTime from, DateTime to) =>
      hourly.where((h) => !h.time.isBefore(from) && h.time.isBefore(to)).toList();

  /// 从 [from] 起的未来 [hours] 个小时点
  List<ExtraHourly> ahead(DateTime from, int hours) =>
      hourly.where((h) => !h.time.isBefore(from)).take(hours).toList();

  static String dayKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  DateTime? sunriseOn(DateTime t) => sunrise[dayKey(t)];
  DateTime? sunsetOn(DateTime t) => sunset[dayKey(t)];
}

/// Open-Meteo 扩展变量客户端
///
/// 需要的变量**实测全部免 key 可用**（2026-09-20 验证）：
/// `et0_fao_evapotranspiration`(mm)、`shortwave_radiation`(W/m²)、
/// `cloud_cover` / `cloud_cover_low` / `cloud_cover_mid` / `cloud_cover_high`(%)、
/// `relative_humidity_2m`(%)、`wind_speed_10m`(km/h)、`visibility`(m)、
/// `dew_point_2m`(°C)、`precipitation`(mm)、`temperature_2m`(°C)，
/// 以及 `daily=sunrise,sunset`。
///
/// ⚠️ 单位换算：Open-Meteo 的 `visibility` 是**米**、`wind_speed_10m` 默认
/// **km/h**、`et0_fao_evapotranspiration` 是**每小时 mm**（不是日累计）。
class OpenMeteoExtraService {
  static const String _base = 'https://api.open-meteo.com/v1/forecast';

  final http.Client _client;
  OpenMeteoExtraService({http.Client? client}) : _client = client ?? http.Client();

  Future<ExtraWeather> fetch({
    required double lat,
    required double lon,
    int pastDays = 1,
    int forecastDays = 3,
  }) async {
    final uri = Uri.parse(_base).replace(queryParameters: {
      'latitude': lat.toStringAsFixed(4),
      'longitude': lon.toStringAsFixed(4),
      'hourly': [
        'temperature_2m',
        'precipitation',
        'precipitation_probability',
        'et0_fao_evapotranspiration',
        'shortwave_radiation',
        'cloud_cover',
        'cloud_cover_low',
        'cloud_cover_mid',
        'cloud_cover_high',
        'relative_humidity_2m',
        'wind_speed_10m',
        'visibility',
        'dew_point_2m',
      ].join(','),
      'daily': 'sunrise,sunset',
      'timezone': 'Asia/Shanghai',
      'past_days': '$pastDays',
      'forecast_days': '$forecastDays',
    });

    final resp = await _client.get(uri).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('Open-Meteo 扩展变量返回 ${resp.statusCode}');
    }
    final root = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final hourly = root['hourly'] as Map<String, dynamic>?;
    if (hourly == null) return const ExtraWeather(hourly: []);

    final times = (hourly['time'] as List?) ?? const [];

    double? at(String key, int i) {
      final list = hourly[key] as List?;
      if (list == null || i >= list.length) return null;
      final v = list[i];
      if (v is num) return v.toDouble();
      return double.tryParse('$v');
    }

    final out = <ExtraHourly>[];
    for (var i = 0; i < times.length; i++) {
      final t = DateTime.tryParse('${times[i]}');
      if (t == null) continue;
      final visM = at('visibility', i);
      out.add(ExtraHourly(
        time: t,
        temperature: at('temperature_2m', i),
        precipitation: at('precipitation', i),
        et0: at('et0_fao_evapotranspiration', i),
        shortwave: at('shortwave_radiation', i),
        cloudCover: at('cloud_cover', i),
        cloudLow: at('cloud_cover_low', i),
        cloudMid: at('cloud_cover_mid', i),
        cloudHigh: at('cloud_cover_high', i),
        humidity: at('relative_humidity_2m', i),
        windSpeed: at('wind_speed_10m', i),
        visibility: visM == null ? null : visM / 1000.0, // 米 → 公里
        dewPoint: at('dew_point_2m', i),
        precipProb: at('precipitation_probability', i)?.round(),
      ));
    }
    out.sort((a, b) => a.time.compareTo(b.time));

    // ===== 日出日落 =====
    final daily = root['daily'] as Map<String, dynamic>?;
    final sunrise = <String, DateTime>{};
    final sunset = <String, DateTime>{};
    if (daily != null) {
      final dts = (daily['time'] as List?) ?? const [];
      final sr = (daily['sunrise'] as List?) ?? const [];
      final ss = (daily['sunset'] as List?) ?? const [];
      for (var i = 0; i < dts.length; i++) {
        final k = '${dts[i]}';
        if (i < sr.length) {
          final t = DateTime.tryParse('${sr[i]}');
          if (t != null) sunrise[k] = t;
        }
        if (i < ss.length) {
          final t = DateTime.tryParse('${ss[i]}');
          if (t != null) sunset[k] = t;
        }
      }
    }

    return ExtraWeather(hourly: out, sunrise: sunrise, sunset: sunset);
  }

  void dispose() => _client.close();
}
