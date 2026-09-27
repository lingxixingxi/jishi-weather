import 'package:flutter_test/flutter_test.dart';
import 'package:jishiweather/engine/route_analyzer.dart';
import 'package:jishiweather/models/hourly_weather.dart';
import 'package:jishiweather/services/amap_service.dart';

/// 路线分段 · **逐点给源**（2026-09-27 由「全线共用一个源」改来）
///
/// 背景：雷达定调原本只在路线中点做一次，却拿它的结论管全线。长途路线上
/// 起点与终点可能压根不是同一个天气型。现在沿途取多个校验点，每个采样点
/// 用离它最近那个校验点的结论 —— 于是 `buildSegments` 收的是
/// `preferredModels`（与采样点一一对应的列表），而不是单个 `preferredModel`。
void main() {
  final t0 = DateTime(2026, 9, 27, 10, 0);

  HourlyWeather w(double km, double precip) => HourlyWeather(
        place: '${km.round()}km',
        lat: 31.2,
        lon: 121.3,
        time: t0,
        source: 'multi-model',
        precipitation: precip,
      );

  MultiModelHourly mm(double km) => MultiModelHourly(
        place: '${km.round()}km',
        lat: 31.2,
        lon: 121.3,
        time: t0,
        sources: const [
          ModelForecast(
              model: 'ecmwf_ifs025', displayName: 'ECMWF', temperature: 25),
          ModelForecast(
              model: 'icon_seamless', displayName: 'ICON', temperature: 26),
        ],
      );

  List<({GeoPoint point, double kmFromStart})> samplesOf(List<double> kms) => [
        for (final k in kms)
          (point: const GeoPoint(lat: 31.2, lon: 121.3), kmFromStart: k),
      ];

  group('路线分段 · 逐点给源', () {
    test('preferredModels 按采样点逐个生效（不再全线共用一个源）', () {
      final segments = RouteAnalyzer.buildSegments(
        samples: samplesOf([0, 20, 40]),
        // 第 1 个点有雨、后两点无雨 → 降水等级变化，切成两段
        weathers: [w(0, 2.0), w(20, 0.0), w(40, 0.0)],
        departAt: t0,
        totalMinutes: 60,
        totalKm: 40,
        originName: '起点',
        destinationName: '终点',
        multiModels: [mm(0), mm(20), mm(40)],
        // 段 1 的起点是采样点 0 → 用 ECMWF；段 2 的起点是采样点 1 → null
        preferredModels: const ['ecmwf_ifs025', null, 'icon_seamless'],
      );

      expect(segments.length, 2, reason: '降水等级变化应切成两段');
      expect(segments[0].adoptedSource, 'ECMWF',
          reason: '第 1 段取采样点 0 的定源');
      expect(segments[1].adoptedSource, isNull,
          reason: '第 2 段对应采样点 1 的源为 null → 保持多源融合');
    });

    test('同一段内取的是「该段起点」采样点的源，不是全线第一个', () {
      // 让整条路线天气一致 → 只有一段；它的起点是采样点 0，
      // 此时 preferredModels[0] 才该生效（用来锁住下标不是写死的）
      final segments = RouteAnalyzer.buildSegments(
        samples: samplesOf([0, 20, 40]),
        weathers: [w(0, 0.0), w(20, 0.0), w(40, 0.0)],
        departAt: t0,
        totalMinutes: 60,
        totalKm: 40,
        originName: '起点',
        destinationName: '终点',
        multiModels: [mm(0), mm(20), mm(40)],
        preferredModels: const ['icon_seamless'],
      );

      expect(segments.length, 1);
      expect(segments[0].adoptedSource, 'ICON');
    });

    test('preferredModels 为空或短于采样点数时，缺的部分按多源融合处理', () {
      final short = RouteAnalyzer.buildSegments(
        samples: samplesOf([0, 20, 40]),
        weathers: [w(0, 2.0), w(20, 0.0), w(40, 0.0)],
        departAt: t0,
        totalMinutes: 60,
        totalKm: 40,
        originName: '起点',
        destinationName: '终点',
        multiModels: [mm(0), mm(20), mm(40)],
        // 只给 1 个，第 2 段的下标 1 越界 → 必须安全退回融合值，不能崩
        preferredModels: const ['ecmwf_ifs025'],
      );
      expect(short.length, 2);
      expect(short[0].adoptedSource, 'ECMWF');
      expect(short[1].adoptedSource, isNull);

      final none = RouteAnalyzer.buildSegments(
        samples: samplesOf([0, 20, 40]),
        weathers: [w(0, 2.0), w(20, 0.0), w(40, 0.0)],
        departAt: t0,
        totalMinutes: 60,
        totalKm: 40,
        originName: '起点',
        destinationName: '终点',
        multiModels: [mm(0), mm(20), mm(40)],
        // 完全不传（默认空列表）—— 老调用方的行为必须保持
      );
      expect(none.length, 2);
      expect(none.every((s) => s.adoptedSource == null), isTrue);
    });

    test('定源后各要素确实取自该源，多源比对信息依然保留', () {
      final segments = RouteAnalyzer.buildSegments(
        samples: samplesOf([0, 20, 40]),
        weathers: [w(0, 0.0), w(20, 0.0), w(40, 0.0)],
        departAt: t0,
        totalMinutes: 60,
        totalKm: 40,
        originName: '起点',
        destinationName: '终点',
        multiModels: [mm(0), mm(20), mm(40)],
        preferredModels: const ['ecmwf_ifs025'],
      );

      final seg = segments.first;
      expect(seg.temperature, 25, reason: '温度应取自 ECMWF 而非融合平均');
      expect(seg.basis.any((b) => b.label == '多源温度'), isTrue,
          reason: '多源并列信息不能因为定源而丢失');
      expect(
        seg.basis.firstWhere((b) => b.label == '采用源').value,
        contains('ECMWF'),
      );
    });
  });
}
