import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/hourly_weather.dart';

/// Open-Meteo 数据源（免 key 主力源）
///
/// - 逐小时预报，支持多模型（best_match / ecmwf_ifs025 / gfs_global / icon_global）
/// - 文档：https://open-meteo.com/en/docs
class OpenMeteoService {
  static const String _forecastUrl = 'https://api.open-meteo.com/v1/forecast';

  /// 默认变量集（覆盖出行研判 + 赛道/摄影所需的免费变量）
  static const List<String> defaultVariables = [
    'temperature_2m',
    'precipitation',
    'precipitation_probability',
    'weather_code',
    'wind_speed_10m',
    'wind_direction_10m',
    'wind_gusts_10m',
    'visibility',
    'cloud_cover',
  ];

  final http.Client _client;
  OpenMeteoService({http.Client? client}) : _client = client ?? http.Client();

  /// 拉取指定坐标的逐小时气象
  ///
  /// [model] 可选 `best_match`（默认）/ `ecmwf_ifs025` / `gfs_global` / `icon_global`
  Future<List<HourlyWeather>> fetchHourly({
    required double lat,
    required double lon,
    String place = '',
    String model = 'best_match',
    int forecastDays = 3,
    List<String>? variables,
  }) async {
    final vars = (variables ?? defaultVariables).join(',');
    final uri = Uri.parse(_forecastUrl).replace(queryParameters: {
      'latitude': lat.toString(),
      'longitude': lon.toString(),
      'hourly': vars,
      'forecast_days': forecastDays.toString(),
      'timezone': 'Asia/Shanghai',
      if (model != 'best_match') 'models': model,
    });

    final resp = await _client.get(uri).timeout(const Duration(seconds: 35));
    if (resp.statusCode != 200) {
      throw Exception('Open-Meteo 返回 ${resp.statusCode}');
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return _parse(data, lat: lat, lon: lon, place: place, source: model);
  }

  /// 并发拉取多个坐标点（沿途采样用）
  Future<List<List<HourlyWeather>>> fetchMany(
    List<({double lat, double lon, String place})> points, {
    String model = 'best_match',
    int forecastDays = 3,
  }) async {
    final results = await Future.wait(points.map((p) => fetchHourly(
          lat: p.lat,
          lon: p.lon,
          place: p.place,
          model: model,
          forecastDays: forecastDays,
        )));
    return results;
  }

  List<HourlyWeather> _parse(
    Map<String, dynamic> data, {
    required double lat,
    required double lon,
    required String place,
    required String source,
  }) {
    final hourly = data['hourly'] as Map<String, dynamic>?;
    if (hourly == null) return const [];
    final times = (hourly['time'] as List?)?.cast<String>() ?? const [];

    List<double?> numList(String key) {
      final raw = hourly[key] as List?;
      if (raw == null) return List.filled(times.length, null);
      return raw.map((e) => (e as num?)?.toDouble()).toList();
    }

    final temp = numList('temperature_2m');
    final precip = numList('precipitation');
    final pop = numList('precipitation_probability');
    final code = numList('weather_code');
    final wind = numList('wind_speed_10m');
    final windDir = numList('wind_direction_10m');
    final gust = numList('wind_gusts_10m');
    final vis = numList('visibility');
    final cloud = numList('cloud_cover');

    final out = <HourlyWeather>[];
    for (var i = 0; i < times.length; i++) {
      final v = (i < vis.length ? vis[i] : null);
      final wc = (i < code.length ? code[i]?.toInt() : null);
      final p = (i < precip.length ? precip[i] : null);
      out.add(HourlyWeather(
        place: place.isEmpty ? '${lat.toStringAsFixed(2)},${lon.toStringAsFixed(2)}' : place,
        lat: lat,
        lon: lon,
        time: DateTime.parse(times[i]),
        source: source,
        temperature: i < temp.length ? temp[i] : null,
        precipitation: p,
        precipitationProbability: (i < pop.length ? pop[i]?.toInt() : null),
        precipitationType: (p != null && p > 0) ? '雨' : '无',
        windSpeed: i < wind.length ? wind[i] : null,
        windDirection: (i < windDir.length ? windDir[i]?.toInt() : null),
        windGust: i < gust.length ? gust[i] : null,
        visibility: v == null ? null : v / 1000.0, // 米 → 公里
        cloudCover: i < cloud.length ? cloud[i] : null,
        weatherCode: wc,
        weatherText: wc == null ? null : wmoCodeText[wc],
      ));
    }
    return out;
  }

  void dispose() => _client.close();
}
