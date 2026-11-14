// 覆盖「境外主源（Open-Meteo）不可达时的降级」—— 2026-11-14 修的 bug
//
// 背景：Open-Meteo 在境外，链路抖动时整段超时（实测一次故障里 35 秒内零成功，
// 而同一分钟和风、中央气象台、高德全部正常）。早先 MultiSourceService 里
// `multi.isEmpty` 直接 return，和风与央台明明活着却被跳过，用户看到的是
// 笼统的「全部连不上」。
//
// ⚠️ 这些用例存在的意义：这条分支在正常网络下**根本走不到**，
// 装包点一遍界面验证不了它。必须用替身把「主源返回空」这件事造出来。

import 'package:flutter_test/flutter_test.dart';
import 'package:jishiweather/models/hourly_weather.dart';
import 'package:jishiweather/services/multi_source_service.dart';
import 'package:jishiweather/services/nmc_city_repository.dart';
import 'package:jishiweather/services/nmc_service.dart';
import 'package:jishiweather/services/open_meteo.dart';
import 'package:jishiweather/services/qweather_service.dart';

// ==================== 替身 ====================

/// 假和风：返回预先准备好的逐小时数据
class _FakeQWeather implements QWeatherService {
  _FakeQWeather(this.rows);

  final List<QWeatherHourly> rows;
  int callCount = 0;

  @override
  bool get isConfigured => true;

  @override
  Future<List<QWeatherHourly>> hourly(double lat, double lon, {int hours = 24}) async {
    callCount++;
    return rows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 假 Open-Meteo：分别控制单点与多点调用的返回
class _FakeMeteo implements OpenMeteoService {
  _FakeMeteo({this.single = const [], this.many});

  final List<MultiModelHourly> single;
  final List<List<MultiModelHourly>>? many;

  @override
  Future<List<MultiModelHourly>> fetchMultiModel({
    required double lat,
    required double lon,
    String place = '',
    List<String> models = OpenMeteoService.defaultModels,
    int forecastDays = 2,
    List<String>? variables,
  }) async =>
      single;

  @override
  Future<List<List<MultiModelHourly>>> fetchMultiModelMany({
    required List<({double lat, double lon, String place})> points,
    List<String> models = OpenMeteoService.defaultModels,
    int forecastDays = 2,
    List<String>? variables,
    Duration perPointTimeout = const Duration(seconds: 8),
    int maxConcurrent = 6,
  }) async =>
      many ?? List<List<MultiModelHourly>>.filled(points.length, const []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCityRepo implements NmcCityRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeNmc implements NmcService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ==================== 用例 ====================

void main() {
  final t0 = DateTime(2026, 11, 14, 12);

  List<QWeatherHourly> qwRows(int n) => List<QWeatherHourly>.generate(
        n,
        (i) => QWeatherHourly(
          time: t0.add(Duration(hours: i)),
          temperature: 20.0 + i,
          precipitationProbability: 10,
        ),
      );

  MultiModelHourly mainPoint(double lat, double lon, String place) => MultiModelHourly(
        place: place,
        lat: lat,
        lon: lon,
        time: t0,
        sources: const [
          ModelForecast(model: 'ecmwf_ifs', displayName: 'ECMWF', temperature: 21),
          ModelForecast(model: 'gfs_seamless', displayName: 'GFS', temperature: 22),
        ],
      );

  MultiSourceService build(_FakeMeteo meteo, _FakeQWeather qw) => MultiSourceService(
        meteo: meteo,
        nmc: _FakeNmc(),
        cityRepo: _FakeCityRepo(),
        qweather: qw,
      );

  test('主源为空 + 和风有数据 → 用和风搭骨架，而不是返回空', () async {
    final svc = build(_FakeMeteo(single: const []), _FakeQWeather(qwRows(3)));
    final out = await svc.fetch(lat: 32, lon: 118, includeNmc: false);

    expect(out.length, 3, reason: '应当返回和风的 3 个时刻，而不是空列表');
    expect(out.first.sources.length, 1);
    expect(out.first.sources.first.model, 'qweather');
  });

  test('主源正常 + 和风有数据 → 和风作为附加源叠加，不搭骨架', () async {
    final qw = _FakeQWeather(qwRows(3));
    final svc = build(_FakeMeteo(single: [mainPoint(32, 118, '中心')]), qw);
    final out = await svc.fetch(lat: 32, lon: 118, includeNmc: false);

    expect(out.length, 1);
    expect(out.first.sources.length, 3, reason: '2 个主源 + 1 个和风');
    expect(out.first.sources.map((s) => s.model), contains('qweather'));
    expect(qw.callCount, 1, reason: '和风整个流程只应请求一次');
  });

  test('主源与和风都为空 → 返回空，不伪造数据', () async {
    final svc = build(_FakeMeteo(single: const []), _FakeQWeather(const []));
    final out = await svc.fetch(lat: 32, lon: 118, includeNmc: false);
    expect(out, isEmpty);
  });

  test('fetchMany：主源逐点缺失时，缺的点用和风搭骨架、有的点叠加和风', () async {
    final meteo = _FakeMeteo(many: [
      const <MultiModelHourly>[],
      [mainPoint(32.1, 118.1, '点1')],
    ]);
    final svc = build(meteo, _FakeQWeather(qwRows(3)));

    final out = await svc.fetchMany(
      [
        (lat: 32.0, lon: 118.0, place: '点0'),
        (lat: 32.1, lon: 118.1, place: '点1'),
      ],
      includeNmc: false,
    );

    expect(out.length, 2);
    expect(out[0].length, 3, reason: '第 0 点主源缺失 → 用和风 3 个时刻搭骨架');
    expect(out[0].first.sources.single.model, 'qweather');
    expect(out[1].length, 1, reason: '第 1 点主源正常，骨架保持原样');
    expect(out[1].first.sources.length, 3, reason: '2 主源 + 和风');
  });
}
