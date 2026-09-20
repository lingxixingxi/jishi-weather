import 'dart:convert';

import 'package:flutter/foundation.dart';
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

  /// WMO 天气码（0 晴 / 1-2 少云多云 / 3 阴 / 45-48 雾 /
  /// 51-67 雨 / 71-77 雪 / 80-86 阵性降水 / 95-99 雷暴）
  final int? weatherCode;

  /// **气溶胶光学厚度 AOD**（无量纲，来自 Open-Meteo Air Quality API）
  ///
  /// 大气通透度的**最直接**指标，比 AQI 更贴近摄影/天文需求：
  /// `<0.05` 极佳（高原/海岛）｜`0.1` 很好｜`0.2` 良好｜
  /// `0.35` 一般｜`>0.5` 明显浑浊｜`>1.0` 很差。
  final double? aod;

  /// PM2.5（μg/m³）
  final double? pm25;

  /// PM10（μg/m³）
  final double? pm10;

  /// 欧洲空气质量指数 EAQI
  /// （0-20 好 / 20-40 尚可 / 40-60 中等 / 60-80 差 / 80-100 很差 / >100 极差）
  final int? aqi;

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
    this.weatherCode,
    this.aod,
    this.pm25,
    this.pm10,
    this.aqi,
  });

  /// 复制并附加空气质量字段（气象与空气质量来自两个 API，需按时刻合并）
  ExtraHourly withAir({
    double? aod,
    double? pm25,
    double? pm10,
    int? aqi,
  }) =>
      ExtraHourly(
        time: time,
        temperature: temperature,
        precipitation: precipitation,
        et0: et0,
        shortwave: shortwave,
        cloudCover: cloudCover,
        cloudLow: cloudLow,
        cloudMid: cloudMid,
        cloudHigh: cloudHigh,
        humidity: humidity,
        windSpeed: windSpeed,
        visibility: visibility,
        dewPoint: dewPoint,
        precipProb: precipProb,
        weatherCode: weatherCode,
        aod: aod,
        pm25: pm25,
        pm10: pm10,
        aqi: aqi,
      );
}

/// 扩展气象结果（逐小时 + 日出日落 + 地点）
class ExtraWeather {
  final List<ExtraHourly> hourly;
  final Map<String, DateTime> sunrise; // key: yyyy-MM-dd
  final Map<String, DateTime> sunset;

  /// 请求地点（月相与月亮高度角需要它）
  final double lat;
  final double lon;

  const ExtraWeather({
    required this.hourly,
    this.sunrise = const {},
    this.sunset = const {},
    this.lat = 0,
    this.lon = 0,
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

  /// 空气质量是**独立子域**（不是 `/v1/forecast` 的变量）
  static const String _airBase = 'https://air-quality-api.open-meteo.com/v1/air-quality';

  final http.Client _client;
  OpenMeteoExtraService({http.Client? client}) : _client = client ?? http.Client();

  /// 取数入口：气象 + 空气质量（两者**并行**，空气质量失败不阻塞主流程）
  Future<ExtraWeather> fetch({
    required double lat,
    required double lon,
    int pastDays = 1,
    int forecastDays = 3,
  }) async {
    final weatherFuture =
        _fetchWeather(lat: lat, lon: lon, pastDays: pastDays, forecastDays: forecastDays);
    final airFuture =
        _fetchAir(lat: lat, lon: lon, pastDays: pastDays, forecastDays: forecastDays);

    final wx = await weatherFuture;

    Map<String, ExtraHourly> air = const {};
    try {
      air = await airFuture;
    } catch (e) {
      debugPrint('[扩展气象] 空气质量拉取失败（不影响主流程）: $e');
    }
    if (air.isEmpty) {
      debugPrint('[扩展气象] 空气质量返回为空，本次不带空气数据');
      return wx;
    }

    // 两个 API 都是整点小时序列，按 "yyyy-MM-ddTHH:00" 对齐合并
    final merged = wx.hourly.map((h) {
      final a = air[_hourKey(h.time)];
      if (a == null) return h;
      return h.withAir(aod: a.aod, pm25: a.pm25, pm10: a.pm10, aqi: a.aqi);
    }).toList();

    // 实测：空气质量预报只覆盖前约 5 天，之后 API 返回 null
    final hitCount = merged.where((h) => h.aod != null || h.pm25 != null).length;
    debugPrint('[扩展气象] 空气质量命中 $hitCount / ${merged.length} 条'
        '${hitCount < merged.length ? "（空气预报仅覆盖前约 5 天，其余为 null）" : ""}');

    return ExtraWeather(
      hourly: merged,
      sunrise: wx.sunrise,
      sunset: wx.sunset,
      lat: wx.lat,
      lon: wx.lon,
    );
  }

  static String _hourKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}'
      'T${t.hour.toString().padLeft(2, '0')}:00';

  /// 气象小时序列 + 日出日落
  Future<ExtraWeather> _fetchWeather({
    required double lat,
    required double lon,
    required int pastDays,
    required int forecastDays,
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
        'weather_code',
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
        weatherCode: at('weather_code', i)?.round(),
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

    return ExtraWeather(
      hourly: out,
      sunrise: sunrise,
      sunset: sunset,
      lat: lat,
      lon: lon,
    );
  }

  /// 空气质量（独立子域，免 key）
  ///
  /// `https://air-quality-api.open-meteo.com/v1/air-quality`
  ///
  /// 实测变量（2026-09-20）：`pm10` / `pm2_5`(μg/m³)、`aerosol_optical_depth`(无量纲)、
  /// `dust`(μg/m³)、`uv_index`、`european_aqi`、`us_aqi`。
  ///
  /// 只取摄影相关的四项：**AOD（通透度主指标）+ PM2.5 / PM10 / EAQI（展示与兜底）**。
  /// 失败时由调用方兜底，不影响主流程。
  Future<Map<String, ExtraHourly>> _fetchAir({
    required double lat,
    required double lon,
    required int pastDays,
    required int forecastDays,
  }) async {
    final uri = Uri.parse(_airBase).replace(queryParameters: {
      'latitude': lat.toStringAsFixed(4),
      'longitude': lon.toStringAsFixed(4),
      'hourly': 'pm10,pm2_5,aerosol_optical_depth,european_aqi',
      'timezone': 'Asia/Shanghai',
      'past_days': '$pastDays',
      'forecast_days': '$forecastDays',
    });

    final resp = await _client.get(uri).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('空气质量接口返回 ${resp.statusCode}');
    }
    final root = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final hourly = root['hourly'] as Map<String, dynamic>?;
    if (hourly == null) return const {};

    final times = (hourly['time'] as List?) ?? const [];
    double? at(String key, int i) {
      final list = hourly[key] as List?;
      if (list == null || i >= list.length) return null;
      final v = list[i];
      if (v is num) return v.toDouble();
      return double.tryParse('$v');
    }

    final out = <String, ExtraHourly>{};
    for (var i = 0; i < times.length; i++) {
      final key = '${times[i]}';
      final t = DateTime.tryParse(key);
      if (t == null) continue;
      out[key] = ExtraHourly(
        time: t,
        aod: at('aerosol_optical_depth', i),
        pm25: at('pm2_5', i),
        pm10: at('pm10', i),
        aqi: at('european_aqi', i)?.round(),
      );
    }
    return out;
  }

  void dispose() => _client.close();
}
