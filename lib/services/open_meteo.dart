import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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
  ///
  /// ## ⚡ 性能设计（实测驱动，2026-09-23）
  ///
  /// 这是「缩放 / 平移地图时重采网格」的热路径，**耗时直接决定跟手程度**。
  /// 实测 9×9 网格、24 km 跨度（脚本：`_research/probe/probe_grid_speed.py`）：
  ///
  /// | 时间跨度 | 变量数 | 耗时 |
  /// |---|---|---|
  /// | 48 h | 3 | **8.65 s** ← 旧实现，用户反馈「加载慢」的根因 |
  /// | 24 h | 3 | 4.20 s |
  /// | 48 h | 2 | 3.64 s |
  /// | **24 h** | **2** | **1.05 s** |
  ///
  /// 结论：**时间跨度是主因，点数几乎不影响** —— 3×3（仅 9 个点）仍要 2.55 s，
  /// 比 24 h / 81 点的 1.05 s 还慢。Open-Meteo 官方也说明「多坐标 + 长时间跨度」
  /// 代价很高（GitHub issue #369：单次调用可能返回数 GB 数据）。
  ///
  /// 因此这里做两件事：
  /// 1. **只请求 `cloud_cover` + `precipitation`**（叠加图用不到降水概率）；
  /// 2. **把整段时间轴拆成「逐日窗口」并发拉取** —— 每个窗口 24 h 约 1 s，
  ///    并发后总耗时仍约 1 s，而时间轴长度不变（过去 1 天 + 今天 = 48 帧）。
  ///
  /// ⚠️ 不要退回「一次请求 48 h」：那是 8.65 s，用户会明显感到卡。
  Future<List<GridPoint>> fetchGrid({
    required double centerLat,
    required double centerLon,
    double spanKm = 24, // 覆盖范围（公里）
    int n = 5, // 每边格点数
    int pastDays = 1, // 含过去 N 天（可回看）
    int forecastDays = 1,
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

    // 组成「逐日窗口」列表（过去的 N 天 + 未来 N 天，按时间顺序）
    final today = DateTime.now();
    final base = DateTime(today.year, today.month, today.day);
    final days = <DateTime>[
      for (var d = pastDays; d >= 1; d--) base.subtract(Duration(days: d)),
      for (var d = 0; d < forecastDays; d++) base.add(Duration(days: d)),
    ];
    if (days.isEmpty) days.add(base);

    // 并发拉取：单个窗口失败不影响其余（返回空列表占位）
    final parts = await Future.wait(days.map((d) async {
      try {
        return await _fetchGridDay(lats: lats, lons: lons, day: d);
      } catch (e) {
        debugPrint('[网格] 窗口 ${_ymd(d)} 失败: $e');
        return const <GridPoint>[];
      }
    }));

    // 按时间顺序把各窗口的序列拼接起来
    final out = <GridPoint>[];
    for (var i = 0; i < lats.length; i++) {
      final times = <String>[];
      final cloud = <double?>[];
      final rain = <double?>[];
      for (final part in parts) {
        if (i >= part.length) continue;
        times.addAll(part[i].times);
        cloud.addAll(part[i].cloud);
        rain.addAll(part[i].rain);
      }
      out.add(GridPoint(
        lat: lats[i],
        lon: lons[i],
        times: times,
        cloud: cloud,
        rain: rain,
        // 叠加图不需要降水概率 —— 去掉它实测可省约 4 倍耗时
        pop: const [],
      ));
    }
    return out;
  }

  static String _ymd(DateTime d) => '${d.year}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 拉取**单个自然日**的网格数据（[fetchGrid] 的并发单元）
  Future<List<GridPoint>> _fetchGridDay({
    required List<double> lats,
    required List<double> lons,
    required DateTime day,
  }) async {
    final uri = Uri.parse(_forecastUrl).replace(queryParameters: {
      'latitude': lats.map((e) => e.toStringAsFixed(4)).join(','),
      'longitude': lons.map((e) => e.toStringAsFixed(4)).join(','),
      'hourly': 'cloud_cover,precipitation',
      'start_date': _ymd(day),
      'end_date': _ymd(day),
      'timezone': 'Asia/Shanghai',
    });

    final resp = await _client.get(uri).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception('网格数据请求失败 ${resp.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    final list =
        (decoded is List ? decoded : [decoded]).cast<Map<String, dynamic>>();

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
      if (i < list.length) {
        final hourly = list[i]['hourly'] as Map<String, dynamic>?;
        times = ((hourly?['time'] as List?) ?? const []).cast<String>();
        cloud = toList(hourly, 'cloud_cover');
        rain = toList(hourly, 'precipitation');
      }
      out.add(GridPoint(
        lat: lats[i],
        lon: lons[i],
        times: times,
        cloud: cloud,
        rain: rain,
        pop: const [],
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
          // ⚠️ Open-Meteo 的 visibility 单位是**米**，统一换算成公里
          visibility: at('visibility_$m', i) == null ? null : at('visibility_$m', i)! / 1000.0,
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

  /// 多地点 × 多模型，**带超时降级**
  ///
  /// 三模型请求的响应体积是单模型的 3 倍，网络慢时容易超时。
  /// 这里给每个点单独设超时；超时的点自动降级为 `best_match` 单模型，
  /// 保证整条路线仍能出研判结果（而不是整个流程失败）。
  Future<List<List<MultiModelHourly>>> fetchMultiModelMany({
    required List<({double lat, double lon, String place})> points,
    List<String> models = defaultModels,
    int forecastDays = 2,
    List<String>? variables,
    Duration perPointTimeout = const Duration(seconds: 20),
  }) {
    return Future.wait(points.map((p) => _fetchOneWithFallback(
          p,
          models: models,
          forecastDays: forecastDays,
          variables: variables,
          timeout: perPointTimeout,
        )));
  }

  Future<List<MultiModelHourly>> _fetchOneWithFallback(
    ({double lat, double lon, String place}) p, {
    required List<String> models,
    required int forecastDays,
    List<String>? variables,
    required Duration timeout,
  }) async {
    try {
      return await fetchMultiModel(
        lat: p.lat,
        lon: p.lon,
        place: p.place,
        models: models,
        forecastDays: forecastDays,
        variables: variables,
      ).timeout(timeout);
    } catch (e) {
      debugPrint('[Open-Meteo] 三模型失败(${p.place})，降级单模型: $e');
      // 降级：单模型 best_match
      try {
        final single = await fetchHourly(
          lat: p.lat,
          lon: p.lon,
          place: p.place,
          forecastDays: forecastDays,
          variables: variables,
        );
        return single
            .map((w) => MultiModelHourly(
                  place: p.place,
                  lat: p.lat,
                  lon: p.lon,
                  time: w.time,
                  sources: [
                    ModelForecast(
                      model: 'best_match',
                      displayName: '综合',
                      temperature: w.temperature,
                      precipitationProbability: w.precipitationProbability,
                      precipitation: w.precipitation,
                      windSpeed: w.windSpeed,
                      windDirection: w.windDirection,
                      windGust: w.windGust,
                      visibility: w.visibility,
                      cloudCover: w.cloudCover,
                      weatherCode: w.weatherCode,
                      weatherText: w.weatherText,
                    ),
                  ],
                ))
            .toList();
      } catch (e2) {
        debugPrint('[Open-Meteo] 降级也失败(${p.place}): $e2');
        return const <MultiModelHourly>[];
      }
    }
  }

  /// 逐日预报（未来 N 天）
  ///
  /// 用 Open-Meteo 的 `daily` 参数一次拿到日最高/最低温、天气码、
  /// 降水总量、降水概率、最大风速与紫外线，供「未来预测」展示。
  Future<List<DailyWeather>> fetchDaily({
    required double lat,
    required double lon,
    int forecastDays = 7,
  }) async {
    final uri = Uri.parse(_forecastUrl).replace(queryParameters: {
      'latitude': lat.toString(),
      'longitude': lon.toString(),
      'daily': [
        'weather_code',
        'temperature_2m_max',
        'temperature_2m_min',
        'precipitation_sum',
        'precipitation_probability_max',
        'wind_speed_10m_max',
        'wind_gusts_10m_max',
        'uv_index_max',
        'sunrise',
        'sunset',
      ].join(','),
      'forecast_days': forecastDays.toString(),
      'timezone': 'Asia/Shanghai',
    });

    final resp = await _client.get(uri).timeout(const Duration(seconds: 35));
    if (resp.statusCode != 200) {
      throw Exception('Open-Meteo 逐日请求失败 ${resp.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final daily = decoded['daily'] as Map<String, dynamic>?;
    if (daily == null) return const [];

    final dates = ((daily['time'] as List?) ?? const []).cast<String>();
    double? at(String k, int i) {
      final arr = daily[k] as List?;
      if (arr == null || i >= arr.length) return null;
      return (arr[i] as num?)?.toDouble();
    }

    final out = <DailyWeather>[];
    for (var i = 0; i < dates.length; i++) {
      final code = at('weather_code', i)?.round();
      final sunrise = (daily['sunrise'] as List?)?.elementAtOrNull(i) as String?;
      final sunset = (daily['sunset'] as List?)?.elementAtOrNull(i) as String?;
      out.add(DailyWeather(
        date: DateTime.parse(dates[i]),
        weatherCode: code,
        weatherText: code == null ? null : wmoCodeText[code],
        tempMax: at('temperature_2m_max', i),
        tempMin: at('temperature_2m_min', i),
        precipitationSum: at('precipitation_sum', i),
        precipProbabilityMax: at('precipitation_probability_max', i)?.round(),
        windSpeedMax: at('wind_speed_10m_max', i),
        windGustMax: at('wind_gusts_10m_max', i),
        uvIndexMax: at('uv_index_max', i),
        sunrise: sunrise == null ? null : DateTime.tryParse(sunrise),
        sunset: sunset == null ? null : DateTime.tryParse(sunset),
      ));
    }
    return out;
  }

  void dispose() => _client.close();
}

/// 逐日预报
class DailyWeather {
  final DateTime date;
  final int? weatherCode;
  final String? weatherText;
  final double? tempMax;
  final double? tempMin;
  final double? precipitationSum; // mm
  final int? precipProbabilityMax; // %
  final double? windSpeedMax; // km/h
  final double? windGustMax; // km/h
  final double? uvIndexMax;
  final DateTime? sunrise;
  final DateTime? sunset;

  const DailyWeather({
    required this.date,
    this.weatherCode,
    this.weatherText,
    this.tempMax,
    this.tempMin,
    this.precipitationSum,
    this.precipProbabilityMax,
    this.windSpeedMax,
    this.windGustMax,
    this.uvIndexMax,
    this.sunrise,
    this.sunset,
  });

  /// 日累计降水分级（mm/24h，国标日雨量）
  ///
  /// ⚠️ 这是**日口径**，与 `HourlyWeather.levelOf`（小时口径 mm/h）界限完全不同，
  /// 两者**不可混用**：日累计 8mm 是「小雨」，而 8mm/h 已经是「中雨」。
  ///
  /// 提成 static 是为了让逐日聚合（`_dailySummaries`）复用 —— 那里原先误用了
  /// **小时**分级去判日预报，于是整周 7 天全显示「小雨」（实测反馈：
  /// 9/26 当天累计 31.8mm，按日口径本应是「大雨」）。
  static String dailyLevelOf(double? mm) {
    final p = mm ?? 0;
    if (p < 0.1) return '无雨';
    if (p < 10) return '小雨';
    if (p < 25) return '中雨';
    if (p < 50) return '大雨';
    if (p < 100) return '暴雨';
    return '大暴雨';
  }

  /// 降水强度描述（按日累计量粗分）
  String get precipLevel => dailyLevelOf(precipitationSum);

  /// 星期几
  String get weekday {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${names[date.weekday - 1]}';
  }
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
