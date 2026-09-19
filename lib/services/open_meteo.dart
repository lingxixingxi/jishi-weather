import 'dart:convert';
import 'dart:math' as math;

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
    'relative_humidity_2m', // 能见度/云量推算所需
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

  /// 批量拉取网格点的「云量 + 雨量」逐小时序列
  ///
  /// Open-Meteo 支持一次请求多个坐标（逗号分隔），5×5 网格只需 1 次请求。
  /// 返回按行优先排列：index = row * n + col，row 由南到北、col 由西到东。
  /// 每个点带完整逐小时序列，便于做时间轴动画。
  Future<List<GridPoint>> fetchGrid({
    required double centerLat,
    required double centerLon,
    double spanKm = 24, // 覆盖范围（公里）
    int n = 5, // 每边格点数
    int forecastDays = 1,
    int pastDays = 1, // 含过去 N 天（可回看移动轨迹）
  }) async {
    final half = spanKm / 2 / 111.0;
    final dLat = spanKm / 111.0 / (n - 1);
    final cosLat = math.cos(centerLat * math.pi / 180.0).abs().clamp(0.2, 1.0);
    final dLon = dLat / cosLat;

    final lats = <double>[];
    final lons = <double>[];
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        lats.add(centerLat - half + r * dLat);
        lons.add(centerLon - half / cosLat + c * dLon);
      }
    }

    final uri = Uri.parse(_forecastUrl).replace(queryParameters: {
      'latitude': lats.map((e) => e.toStringAsFixed(4)).join(','),
      'longitude': lons.map((e) => e.toStringAsFixed(4)).join(','),
      'hourly': 'cloud_cover,precipitation,precipitation_probability',
      'forecast_days': '$forecastDays',
      'past_days': '$pastDays',
      'timezone': 'Asia/Shanghai',
    });

    final resp = await _client.get(uri).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception('网格数据请求失败 ${resp.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    final list = (decoded is List ? decoded : [decoded]).cast<Map<String, dynamic>>();

    List<double?> toList(dynamic hourly, String key) {
      final arr = (hourly as Map<String, dynamic>?)?[key] as List?;
      if (arr == null) return const [];
      return arr.map((e) => (e as num?)?.toDouble()).toList();
    }

    final out = <GridPoint>[];
    for (var i = 0; i < lats.length; i++) {
      var times = <String>[];
      var cloud = <double?>[];
      var rain = <double?>[];
      var pop = <double?>[];
      if (i < list.length) {
        final hourly = list[i]['hourly'] as Map<String, dynamic>?;
        times = ((hourly?['time'] as List?) ?? const []).cast<String>();
        cloud = toList(hourly, 'cloud_cover');
        rain = toList(hourly, 'precipitation');
        pop = toList(hourly, 'precipitation_probability');
      }
      out.add(GridPoint(
        lat: lats[i],
        lon: lons[i],
        times: times,
        cloud: cloud,
        rain: rain,
        pop: pop,
      ));
    }
    return out;
  }

  /// 默认参与交叉验证的数值模型（三个独立来源，互不依赖）
  static const List<String> defaultModels = [
    'ecmwf_ifs025', // 欧洲中期天气预报中心
    'gfs_seamless', // 美国 NCEP GFS
    'icon_seamless', // 德国气象局 ICON
  ];

  /// 模型 → 展示名
  static String modelDisplayName(String model) {
    switch (model) {
      case 'ecmwf_ifs025':
      case 'ecmwf_ifs04':
      case 'ecmwf_aifs025':
        return 'ECMWF';
      case 'gfs_seamless':
      case 'gfs_global':
        return 'GFS';
      case 'icon_seamless':
      case 'icon_global':
        return 'ICON';
      case 'best_match':
        return '综合';
      case 'qweather':
        return '和风';
      case 'nmc':
        return '中央气象台';
      default:
        return model;
    }
  }

  /// **多模型交叉验证**：一次请求拿到 ECMWF / GFS / ICON 三源预报
  ///
  /// Open-Meteo 在多模型模式下字段会带模型后缀
  /// （如 `temperature_2m_ecmwf_ifs025`），据此拆成「每时刻的多源集合」。
  /// 注意：能见度只有 GFS 提供（ECMWF/ICON 无此变量），缺失时不参与比对。
  Future<List<MultiModelHourly>> fetchMultiModel({
    required double lat,
    required double lon,
    String place = '',
    List<String> models = defaultModels,
    int forecastDays = 2,
    List<String>? variables,
  }) async {
    final vars = (variables ?? defaultVariables).join(',');
    final uri = Uri.parse(_forecastUrl).replace(queryParameters: {
      'latitude': lat.toString(),
      'longitude': lon.toString(),
      'hourly': vars,
      'models': models.join(','),
      'forecast_days': forecastDays.toString(),
      'timezone': 'Asia/Shanghai',
    });

    final resp = await _client.get(uri).timeout(const Duration(seconds: 35));
    if (resp.statusCode != 200) {
      throw Exception('Open-Meteo 多模型请求失败 ${resp.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final hourly = decoded['hourly'] as Map<String, dynamic>?;
    if (hourly == null) return const [];

    final times = ((hourly['time'] as List?) ?? const []).cast<String>();
    final out = <MultiModelHourly>[];

    double? at(String key, int i) {
      final arr = hourly[key] as List?;
      if (arr == null || i >= arr.length) return null;
      return (arr[i] as num?)?.toDouble();
    }

    for (var i = 0; i < times.length; i++) {
      final sources = <ModelForecast>[];
      for (final m in models) {
        final wc = at('weather_code_$m', i);
        sources.add(ModelForecast(
          model: m,
          displayName: modelDisplayName(m),
          temperature: at('temperature_2m_$m', i),
          humidity: at('relative_humidity_2m_$m', i),
          precipitationProbability: at('precipitation_probability_$m', i)?.round(),
          precipitation: at('precipitation_$m', i),
          windSpeed: at('wind_speed_10m_$m', i),
          windDirection: at('wind_direction_10m_$m', i)?.round(),
          windGust: at('wind_gusts_10m_$m', i),
          visibility: at('visibility_$m', i),
          cloudCover: at('cloud_cover_$m', i),
          weatherCode: wc?.round(),
          weatherText: wc == null ? null : wmoCodeText[wc.round()],
        ));
      }
      out.add(MultiModelHourly(
        place: place,
        lat: lat,
        lon: lon,
        time: DateTime.parse(times[i]),
        sources: sources,
      ));
    }
    return out;
  }

  /// 多地点 × 多模型（路线沿途采样点用）
  Future<List<List<MultiModelHourly>>> fetchMultiModelMany(
    List<({double lat, double lon, String place})> points, {
    List<String> models = defaultModels,
    int forecastDays = 2,
    List<String>? variables,
  }) {
    return Future.wait(points.map((p) => fetchMultiModel(
          lat: p.lat,
          lon: p.lon,
          place: p.place,
          models: models,
          forecastDays: forecastDays,
          variables: variables,
        )));
  }

  void dispose() => _client.close();
}

/// 网格点：带完整逐小时序列（云量 / 雨量 / 降水概率）
class GridPoint {
  final double lat;
  final double lon;
  final List<String> times;
  final List<double?> cloud;
  final List<double?> rain;
  final List<double?> pop;

  const GridPoint({
    required this.lat,
    required this.lon,
    required this.times,
    required this.cloud,
    required this.rain,
    required this.pop,
  });

  int get length => times.length;

  double? cloudAt(int i) => (i >= 0 && i < cloud.length) ? cloud[i] : null;
  double? rainAt(int i) => (i >= 0 && i < rain.length) ? rain[i] : null;
  double? popAt(int i) => (i >= 0 && i < pop.length) ? pop[i] : null;
}
