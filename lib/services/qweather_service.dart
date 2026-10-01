import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/hourly_weather.dart';
import 'api_keys.dart';
import 'qweather_budget.dart';

/// 和风天气逐小时预报
class QWeatherHourly {
  final DateTime time;
  final double? temperature;
  final double? humidity;
  final int? precipitationProbability;
  final double? precipitation;
  final double? windSpeed; // km/h（和风默认 km/h）
  final int? windDirection;
  final double? windGust;
  final double? visibility; // km
  final double? cloudCover;
  final String? weatherText;
  final int? iconCode;

  const QWeatherHourly({
    required this.time,
    this.temperature,
    this.humidity,
    this.precipitationProbability,
    this.precipitation,
    this.windSpeed,
    this.windDirection,
    this.windGust,
    this.visibility,
    this.cloudCover,
    this.weatherText,
    this.iconCode,
  });
}

/// 和风天气服务（新版 API，2024+）
///
/// ⚠️ 和风 2024 改版后**必须使用专属 API Host**
/// （形如 `abcdefg.re.qweatherapi.com`，在控制台→设置查看），
/// 通用域名 `devapi.qweather.com` / `api.qweather.com` 已不可用（返回
/// `Invalid Host`）。
///
/// 认证：请求头 `X-QW-Api-Key: {KEY}`
/// 路径：`/weather/v1/current/{lat}/{lon}`、`/weather/v1/hourly/{lat}/{lon}`
/// 响应为 **Gzip**（http 包会自动解压）。
class QWeatherService {
  final http.Client _client;
  final String apiHost;
  final String apiKey;

  QWeatherService({
    http.Client? client,
    String? apiHost,
    String? apiKey,
  })  : _client = client ?? http.Client(),
        apiHost = apiHost ?? ApiKeys.qweatherHost,
        apiKey = apiKey ?? ApiKeys.qweatherKey;

  /// 是否已配置（Host 为空时视为未配置，调用方应跳过该源）
  bool get isConfigured => apiHost.isNotEmpty && apiKey.isNotEmpty;

  Map<String, String> get _headers => {
        'X-QW-Api-Key': apiKey,
        'Accept-Encoding': 'gzip',
      };

  Uri _uri(String path) => Uri.parse('https://$apiHost$path');

  /// 逐小时预报（默认 24 小时）
  ///
  /// 和风的逐小时接口在 v1 下是 `/weather/v1/hourly/{lat}/{lon}`；
  /// 若该 Host 只支持旧版 `/v7/weather/24h?location=`，会自动回退。
  Future<List<QWeatherHourly>> hourly(
    double lat,
    double lon, {
    int hours = 24,
  }) async {
    if (!isConfigured) return const [];

    // ===== 内置 Key 的请求预算守卫 =====
    //
    // 和风免费订阅 1000 次/天（账号级），而本项目是**按采样点**消耗的 ——
    // 路线页一次研判最多 40 个点就是 40 次请求。详见 [QWeatherBudget]。
    // 用户自填了 Key 则不限（canSpend 恒为真）。
    if (!await QWeatherBudget.canSpend()) {
      debugPrint('[和风] 今日内置 Key 额度已用完'
          '（${QWeatherBudget.dailyLimit} 次/天）→ 跳过和风源');
      return const [];
    }
    await QWeatherBudget.spend();

    // 先试新版路径
    final v1 = await _tryHourlyV1(lat, lon, hours);
    if (v1.isNotEmpty) return v1;

    // 回退旧版路径
    //
    // ⚠️ 这次回退会**额外消耗一次和风调用量**（同一个坐标发了第二个请求）。
    // 正常情况走 v1 就够了；只有当 Host 只支持旧版路径时才会双双命中，
    // 那时实际消耗是额度估算的两倍。
    return _tryHourlyV7(lat, lon, hours);
  }

  Future<List<QWeatherHourly>> _tryHourlyV1(double lat, double lon, int hours) async {
    try {
      final resp = await _client
          .get(_uri('/weather/v1/hourly/${lat.toStringAsFixed(4)}/${lon.toStringAsFixed(4)}'),
              headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      final list = (j is Map ? (j['hours'] ?? j['hourly']) : j) as List?;
      if (list == null) return const [];
      return list.map((e) => _parseHourly(e as Map, v1: true)).take(hours).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<QWeatherHourly>> _tryHourlyV7(double lat, double lon, int hours) async {
    final path = hours <= 24 ? '/v7/weather/24h' : '/v7/weather/72h';
    try {
      final resp = await _client
          .get(_uri(path).replace(queryParameters: {
            'location': '${lon.toStringAsFixed(4)},${lat.toStringAsFixed(4)}',
          }), headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final list = (j['hourly'] as List?) ?? const [];
      return list.map((e) => _parseHourly(e as Map, v1: false)).take(hours).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 解析单条逐小时数据
  ///
  /// ⚠️ 新旧版结构差异很大：
  /// · 新版 `/weather/v1/hourly`：**嵌套对象** + 特殊单位
  ///   `temperature.value` / `wind.speed.value`(m/s) / `visibility.value`(米)
  ///   `humidity`(0~1) / `cloudCover`(0~1) / `precipitation.probability`(0~1)
  /// · 旧版 `/v7/weather/24h`：**扁平字符串**字段（temp/windSpeed km/h 等）
  QWeatherHourly _parseHourly(Map map, {required bool v1}) {
    if (v1) {
      // 兼容取标量或 {value: x}
      double? v(dynamic o) {
        if (o == null) return null;
        if (o is num) return o.toDouble();
        if (o is Map) {
          final x = o['value'];
          if (x is num) return x.toDouble();
          return double.tryParse('$x');
        }
        return double.tryParse('$o');
      }

      final precip = map['precipitation'] as Map?;
      final wind = map['wind'] as Map?;
      final windDir = wind?['direction'] as Map?;
      final cond = map['condition'] as Map?;

      final hum = v(map['humidity']); // 0~1
      final pop = v(precip?['probability']); // 0~1
      final cloud = v(map['cloudCover']); // 0~1
      final windMs = v(wind?['speed']); // m/s
      final gustMs = v(map['windGust']); // m/s
      final visM = v(map['visibility']); // 米

      return QWeatherHourly(
        // 新版时间带 Z（UTC），需转本地
        time: DateTime.tryParse('${map['forecastTime']}')?.toLocal() ?? DateTime.now(),
        temperature: v(map['temperature']),
        humidity: hum == null ? null : hum * 100,
        precipitationProbability: pop == null ? null : (pop * 100).round(),
        // 优先用强度（mm/h），退回累计量
        precipitation: v(precip?['intensity']) ?? v(precip?['amount']),
        windSpeed: windMs == null ? null : windMs * 3.6, // m/s → km/h
        windDirection: v(windDir?['degree'])?.round(),
        windGust: gustMs == null ? null : gustMs * 3.6,
        visibility: visM == null ? null : visM / 1000.0, // 米 → 公里
        cloudCover: cloud == null ? null : cloud * 100,
        weatherText: cond?['text'] as String?,
        iconCode: v(cond?['code'])?.round(),
      );
    }

    // 旧版：扁平字段
    double? num_(dynamic x) {
      if (x == null) return null;
      if (x is num) return x.toDouble();
      return double.tryParse('$x');
    }

    return QWeatherHourly(
      time: DateTime.tryParse('${map['fxTime']}')?.toLocal() ?? DateTime.now(),
      temperature: num_(map['temp']),
      humidity: num_(map['humidity']),
      precipitationProbability: num_(map['pop'])?.round(),
      precipitation: num_(map['precip']),
      windSpeed: num_(map['windSpeed']),
      windDirection: num_(map['wind360'])?.round(),
      windGust: num_(map['windGust'] ?? map['gust']),
      visibility: num_(map['vis']),
      cloudCover: num_(map['cloud']),
      weatherText: map['text'] as String?,
      iconCode: num_(map['icon'])?.round(),
    );
  }

  /// 转成统一的 [ModelForecast]（供多源比对）
  static ModelForecast toModelForecast(QWeatherHourly h) => ModelForecast(
        model: 'qweather',
        displayName: '和风天气',
        temperature: h.temperature,
        humidity: h.humidity,
        precipitationProbability: h.precipitationProbability,
        precipitation: h.precipitation,
        windSpeed: h.windSpeed,
        windDirection: h.windDirection,
        windGust: h.windGust,
        visibility: h.visibility,
        cloudCover: h.cloudCover,
        weatherText: h.weatherText,
      ).enriched();

  /// 把逐小时数据按目标时刻取最近一条
  static QWeatherHourly? nearest(List<QWeatherHourly> list, DateTime t) {
    if (list.isEmpty) return null;
    QWeatherHourly? best;
    var bestDiff = const Duration(days: 999).inMinutes;
    for (final h in list) {
      final d = h.time.difference(t).inMinutes.abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = h;
      }
    }
    return best;
  }

  void dispose() => _client.close();
}
