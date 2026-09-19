import '../models/hourly_weather.dart';
import 'nmc_city_repository.dart';
import 'nmc_service.dart';
import 'open_meteo.dart';

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

  MultiSourceService({
    required OpenMeteoService meteo,
    required NmcService nmc,
    required NmcCityRepository cityRepo,
  })  : _meteo = meteo,
        _nmc = nmc,
        _cityRepo = cityRepo;

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

    // 2. 中央气象台（定位城市 → 拉完整天气）
    try {
      final city = await _cityRepo.locate(lat, lon);
      if (city == null) return multi;

      final wx = await _nmc.weather(city.code, cityName: city.city);

      // 3. 按每个时刻注入中央气象台数据
      return multi
          .map((m) => m.withExtraSource(nmcForecastAt(wx, m.time)))
          .toList();
    } catch (_) {
      // 中央气象台失败不影响主源
      return multi;
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

    // 1. Open-Meteo 三模型（并行）
    final meteoAll = await _meteo.fetchMultiModelMany(
      points,
      forecastDays: forecastDays,
    );
    if (!includeNmc) return meteoAll;

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
    if (cityCodes.isEmpty) return meteoAll;

    // 3. 并行拉取各城市天气
    final wxByCode = <String, NmcWeather>{};
    await Future.wait(cityCodes.values.map((c) async {
      try {
        wxByCode[c.code] = await _nmc.weather(c.code, cityName: c.city);
      } catch (_) {
        // 单城市失败忽略
      }
    }));

    // 4. 合并
    final out = <List<MultiModelHourly>>[];
    for (var i = 0; i < meteoAll.length; i++) {
      final code = cityOf[i]?.code;
      final wx = code == null ? null : wxByCode[code];
      if (wx == null) {
        out.add(meteoAll[i]);
        continue;
      }
      out.add(meteoAll[i]
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
    final f = wx.forecastAt(t);
    final temp = (t.hour >= 6 && t.hour < 18) ? f?.dayTemp : f?.nightTemp;
    final text = (t.hour >= 6 && t.hour < 18) ? f?.dayText : f?.nightText;
    return ModelForecast(
      model: 'nmc',
      displayName: '中央气象台',
      temperature: temp ?? wx.temperature,
      humidity: wx.humidity,
      precipitation: f?.precipitation,
      weatherText: text ?? wx.weatherText,
      isObservation: false,
    ).enriched();
  }
}
