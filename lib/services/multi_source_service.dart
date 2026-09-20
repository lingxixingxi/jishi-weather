import 'dart:math' as math;

import '../models/hourly_weather.dart';
import 'nmc_city_repository.dart';
import 'nmc_service.dart';
import 'open_meteo.dart';
import 'qweather_service.dart';

/// 多源气象数据融合服务
///
/// 把 Open-Meteo 的三个独立数值模型（ECMWF / GFS / ICON）
/// 与中央气象台（实况 + 逐小时实测 + 预报）合并成同一时刻的多源集合，
/// 供研判做交叉验证与分歧分析。
///
/// 中央气象台缺失的 4 项（降水概率/阵风/能见度/云量）由
/// [WeatherEstimator] 用物理经验公式补全，使各源字段对齐后可比。
class MultiSourceService {
  final OpenMeteoService _meteo;
  final NmcService _nmc;
  final NmcCityRepository _cityRepo;

  /// 和风天气（可选第 5 源；未配置 API Host 时自动跳过）
  final QWeatherService _qweather;

  /// 最近一次中央气象台返回的雷达拼图路径（供雷达定调用）
  String? lastRadarPath;

  /// 最近一次中央气象台的完整天气（含实况/逐小时实测）
  NmcWeather? lastNmcWeather;

  MultiSourceService({
    required OpenMeteoService meteo,
    required NmcService nmc,
    required NmcCityRepository cityRepo,
    QWeatherService? qweather,
  })  : _meteo = meteo,
        _nmc = nmc,
        _cityRepo = cityRepo,
        _qweather = qweather ?? QWeatherService();

  /// 拉取单点多源融合数据
  ///
  /// [includeNmc] 为 false 时只返回 Open-Meteo 三模型（用于网络受限场景）。
  Future<List<MultiModelHourly>> fetch({
    required double lat,
    required double lon,
    String place = '',
    int forecastDays = 3,
    bool includeNmc = true,
  }) async {
    // 1. Open-Meteo 三模型（主源）
    final multi = await _meteo.fetchMultiModel(
      lat: lat,
      lon: lon,
      place: place,
      forecastDays: forecastDays,
    );
    if (!includeNmc || multi.isEmpty) return multi;

    // 2. 和风天气（可选第 5 源；未配置 API Host 会自动跳过）
    var result = multi;
    if (_qweather.isConfigured) {
      try {
        final qw = await _qweather.hourly(lat, lon, hours: forecastDays * 24);
        if (qw.isNotEmpty) {
          result = result.map((m) {
            final h = QWeatherService.nearest(qw, m.time);
            return h == null ? m : m.withExtraSource(QWeatherService.toModelForecast(h));
          }).toList();
        }
      } catch (_) {
        // 和风失败不影响其他源
      }
    }

    // 3. 中央气象台（定位城市 → 拉完整天气）
    if (!includeNmc || result.isEmpty) return result;
    try {
      final city = await _cityRepo.locate(lat, lon);
      if (city == null) return result;

      final wx = await _nmc.weather(city.code, cityName: city.city);
      lastRadarPath ??= wx.radarImagePath;
      lastNmcWeather ??= wx;

      // 4. 按每个时刻注入中央气象台数据
      return result
          .map((m) => m.withExtraSource(nmcForecastAt(wx, m.time)))
          .toList();
    } catch (_) {
      // 中央气象台失败不影响主源
      return result;
    }
  }

  /// 批量拉取（路线沿途采样点）
  ///
  /// 会**按城市去重**：多个采样点落在同一城市时只请求一次中央气象台。
  Future<List<List<MultiModelHourly>>> fetchMany(
    List<({double lat, double lon, String place})> points, {
    int forecastDays = 3,
    bool includeNmc = true,
  }) async {
    if (points.isEmpty) return const [];

    // 1. Open-Meteo 三模型（并行，带单点超时降级）
    final meteoAll = await _meteo.fetchMultiModelMany(
      points: points,
      forecastDays: forecastDays,
    );

    // 2. 和风天气（所有采样点并行；免费配额 1000 次/天，正常用量足够）
    var result = meteoAll;
    if (_qweather.isConfigured && points.isNotEmpty) {
      final qwAll = await Future.wait(points.map((p) async {
        try {
          return await _qweather.hourly(p.lat, p.lon, hours: forecastDays * 24);
        } catch (_) {
          return const <QWeatherHourly>[];
        }
      }));
      result = List.generate(result.length, (i) {
        final qw = i < qwAll.length ? qwAll[i] : const <QWeatherHourly>[];
        if (qw.isEmpty) return result[i];
        return result[i].map((m) {
          final h = QWeatherService.nearest(qw, m.time);
          return h == null ? m : m.withExtraSource(QWeatherService.toModelForecast(h));
        }).toList();
      });
    }

    if (!includeNmc) return result;

    // 2. 每个点的城市（去重后只拉一次天气）
    final cityOf = <int, NmcCity?>{};
    final cityCodes = <String, NmcCity>{};
    for (var i = 0; i < points.length; i++) {
      try {
        final c = await _cityRepo.locate(points[i].lat, points[i].lon);
        cityOf[i] = c;
        if (c != null) cityCodes[c.code] = c;
      } catch (_) {
        cityOf[i] = null;
      }
    }
    if (cityCodes.isEmpty) return result;

    // 3. 并行拉取各城市天气
    final wxByCode = <String, NmcWeather>{};
    await Future.wait(cityCodes.values.map((c) async {
      try {
        final wx = await _nmc.weather(c.code, cityName: c.city);
        wxByCode[c.code] = wx;
        // 记录雷达路径供定调使用
        lastRadarPath ??= wx.radarImagePath;
        lastNmcWeather ??= wx;
      } catch (_) {
        // 单城市失败忽略
      }
    }));

    // 4. 合并（注意用 result —— 它已含和风数据）
    final out = <List<MultiModelHourly>>[];
    for (var i = 0; i < result.length; i++) {
      final code = cityOf[i]?.code;
      final wx = code == null ? null : wxByCode[code];
      if (wx == null) {
        out.add(result[i]);
        continue;
      }
      out.add(result[i]
          .map((m) => m.withExtraSource(nmcForecastAt(wx, m.time)))
          .toList());
    }
    return out;
  }

  /// 把中央气象台数据转成 [ModelForecast]
  ///
  /// · 目标时刻在「过去 ~ 当前+30min」→ 用 passedchart **实测**
  /// · 未来 → 用 predict 预报（日/夜粒度，取白天值代表当天）
  /// 风速单位从 m/s 换算为 km/h（与 Open-Meteo 对齐）。
  static ModelForecast nmcForecastAt(NmcWeather wx, DateTime t) {
    final now = DateTime.now();
    final isPastOrNow = t.isBefore(now.add(const Duration(minutes: 30)));

    if (isPastOrNow) {
      final h = wx.historyAt(t);
      if (h != null) {
        return ModelForecast(
          model: 'nmc',
          displayName: '中央气象台',
          temperature: h.temperature,
          humidity: h.humidity,
          precipitation: h.rain1h,
          windSpeed: h.windSpeed == null ? null : h.windSpeed! * 3.6, // m/s → km/h
          windDirection: h.windDirection?.round(),
          isObservation: true,
        ).enriched();
      }
    }

    // 未来：用日预报（中央气象台预报粒度是日/夜）
    //
    // ⚠️ 中央气象台给的是**日最高温 / 夜间最低温**，不是逐小时值，
    // 直接拿最高温去和 Open-Meteo 的逐小时温度比会系统性偏高。
    // 这里按日温变化规律插值到目标时刻（最低 05 时、最高 14 时）。
    //
    // ⚠️⚠️ 降水**必须置空**：
    // `NmcDailyForecast.precipitation` 是**该日的累计降水量**，
    // 而本函数是「给某一小时生成一条 ModelForecast」——
    // 若直接透传，同一个日累计值会被复制到 24 个小时上，
    // 日累加时就变成「日累计 × 24」的爆炸值。
    // 实测曾出现：中央气象台 1185.6mm/日（= 49.4mm × 24），
    // 把 7 日预报的降水总量整体拉高近 20 倍。
    // 中央气象台没有小时粒度的降水预报，因此这里不提供降水，
    // 逐小时降水交由 Open-Meteo 三源 + 和风负责。
    final f = wx.forecastAt(t);
    final temp = _diurnalTemp(f?.dayTemp, f?.nightTemp, t.hour) ?? wx.temperature;
    final text = (t.hour >= 6 && t.hour < 18) ? f?.dayText : f?.nightText;
    return ModelForecast(
      model: 'nmc',
      displayName: '中央气象台',
      temperature: temp,
      humidity: wx.humidity,
      precipitation: null, // ← 日累计值不可当小时值（见上方说明）
      weatherText: text ?? wx.weatherText,
      isObservation: false,
    ).enriched();
  }

  /// 由日最高温 / 夜最低温插值出指定小时的温度
  ///
  /// 采用余弦日变化模型：最高出现在 14 时、最低出现在 02 时（近似）。
  static double? _diurnalTemp(double? dayMax, double? nightMin, int hour) {
    if (dayMax == null && nightMin == null) return null;
    if (dayMax == null) return nightMin;
    if (nightMin == null) return dayMax;
    final mean = (dayMax + nightMin) / 2;
    final amp = (dayMax - nightMin) / 2;
    // 峰值 14 时，谷值 02 时（周期 24h）
    final phase = (hour - 14) * math.pi / 12;
    return mean + amp * math.cos(phase);
  }
}
