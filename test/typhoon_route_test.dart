import 'package:flutter_test/flutter_test.dart';
import 'package:jishiweather/engine/typhoon_verdict.dart';
import 'package:jishiweather/models/typhoon_track.dart';

/// 台风 × 路线重叠分析测试
///
/// 样本取自计划任务 4-1 的测试设计：模拟台风从东海南下、中心经过上海附近，
/// 路线取「上海 → 杭州」，8 月 12 日 8:00 出发。
void main() {
  TyphoonPoint pt(
    DateTime t,
    double lat,
    double lon, {
    String level = 'TY',
    double? wind,
    List<TyphoonWindCircle> circles = const [],
  }) =>
      TyphoonPoint(
        time: t,
        lat: lat,
        lon: lon,
        levelCode: level,
        windSpeed: wind,
        windCircles: circles,
      );

  final d0 = DateTime(2026, 8, 12, 0);
  final d6 = DateTime(2026, 8, 12, 6);
  final d12 = DateTime(2026, 8, 12, 12);

  /// 模拟台风：8/12 12:00 中心在 (120.5, 30.5)，离杭州很近
  TyphoonDetail mock({Map<String, List<TyphoonPoint>> agencies = const {}}) =>
      TyphoonDetail(
        id: '1',
        nameEn: 'TEST',
        nameCn: '模拟台风',
        number: '2612',
        status: 'start',
        observed: [
          pt(d0, 33.0, 124.0, wind: 33),
          pt(d6, 31.5, 122.0, wind: 35),
          pt(d12, 30.5, 120.5, level: 'STS', wind: 30),
        ],
        forecast: const [],
        agencyForecasts: agencies,
      );

  /// 上海 → 杭州，10 个采样点，8:00 出发每 20 分钟一点
  List<RouteSample> route() {
    const lat0 = 31.23, lon0 = 121.47;
    const lat1 = 30.28, lon1 = 120.15;
    return List.generate(10, (i) {
      final f = i / 9;
      return RouteSample(
        km: 170.0 * f,
        time: DateTime(2026, 8, 12, 8).add(Duration(minutes: 20 * i)),
        lat: lat0 + (lat1 - lat0) * f,
        lon: lon0 + (lon1 - lon0) * f,
        label: '上海 → 杭州',
      );
    });
  }

  group('台风 × 路线重叠', () {
    test('路线穿过台风附近 → 标记受影响路段', () {
      final r = TyphoonVerdictEngine.routeImpact(
        typhoon: mock(),
        samples: route(),
      );
      expect(r.affected, isTrue);
      expect(r.segments, isNotEmpty);
      // 计划测试断言：最近距离 < 300km
      expect(r.nearestKm, isNotNull);
      expect(r.nearestKm!, lessThan(300));
      expect(r.sampleCount, 10);
      expect(r.advice, contains('模拟台风'));
    });

    test('最近的采样点应在路线南端（接近台风中心）', () {
      final r = TyphoonVerdictEngine.routeImpact(
        typhoon: mock(),
        samples: route(),
      );
      expect(r.nearestKmMark, isNotNull);
      // 台风在杭州附近 → 最近点里程应偏大（路线后段）
      expect(r.nearestKmMark!, greaterThan(80));
    });

    test('远离台风 → 判定无影响', () {
      // 把路线挪到北京
      final far = List.generate(5, (i) => RouteSample(
            km: 20.0 * i,
            time: DateTime(2026, 8, 12, 8).add(Duration(minutes: 30 * i)),
            lat: 39.9 + i * 0.05,
            lon: 116.4 + i * 0.05,
          ));
      final r = TyphoonVerdictEngine.routeImpact(typhoon: mock(), samples: far);
      expect(r.affected, isFalse);
      expect(r.segments, isEmpty);
      expect(r.worstRisk, '无');
      expect(r.nearestKm, isNotNull);
      expect(r.nearestKm!, greaterThan(500));
    });

    test('±6 小时时间窗：时刻对不上的采样点不参与判定', () {
      // 采样点在 8/20（距台风路径 8 天），应找不到窗口内的台风点
      final offTime = List.generate(5, (i) => RouteSample(
            km: 20.0 * i,
            time: DateTime(2026, 8, 20, 8).add(Duration(minutes: 30 * i)),
            lat: 30.5 + i * 0.05,
            lon: 120.5 + i * 0.05,
          ));
      final r = TyphoonVerdictEngine.routeImpact(typhoon: mock(), samples: offTime);
      expect(r.affected, isFalse);
      // 最近距离为 null（没有任何点在时间窗内）
      expect(r.nearestKm, isNull);
    });

    test('7 级风圈半径优先用台风真实数据', () {
      // 给 12:00 的点加一个 60km 的 7 级风圈（比默认 200km 小）
      final t = TyphoonDetail(
        id: '1',
        nameEn: 'TEST',
        nameCn: '小风圈台风',
        number: '2612',
        status: 'start',
        observed: [
          pt(d12, 30.5, 120.5, level: 'STS', wind: 30, circles: const [
            TyphoonWindCircle(name: '30KTS', ne: 60, se: 60, sw: 60, nw: 60),
          ]),
        ],
      );
      final r = TyphoonVerdictEngine.routeImpact(typhoon: t, samples: route());
      // 杭州端点距中心约 40km < 60km → 仍受影响
      expect(r.affected, isTrue);
    });

    test('无路径数据时给出说明而不是崩溃', () {
      final empty = TyphoonDetail(
        id: '1',
        nameEn: 'X',
        nameCn: '空',
        number: '2601',
        status: 'stop',
      );
      final r = TyphoonVerdictEngine.routeImpact(typhoon: empty, samples: route());
      expect(r.affected, isFalse);
      expect(r.advice, contains('无有效路径'));
    });
  });

  group('机构分歧', () {
    test('单机构 → 0', () {
      final t = mock(agencies: {
        'BABJ': [pt(d12, 30.5, 120.5)],
      });
      expect(TyphoonVerdictEngine.agencySpread(t), 0);
    });

    test('多机构偏差取最大值', () {
      final t = mock(agencies: {
        'BABJ': [pt(d12, 30.5, 120.5), pt(d12.add(const Duration(hours: 12)), 31.0, 121.0)],
        // 日本：第一个点偏 0.5° 纬度（≈55km），第二个点偏 1° 经度
        'RJTD': [pt(d12, 31.0, 120.5), pt(d12.add(const Duration(hours: 12)), 31.0, 122.0)],
      });
      final spread = TyphoonVerdictEngine.agencySpread(t);
      expect(spread, greaterThan(40));
      expect(spread, lessThan(150));
    });

    test('分歧在判定结果里透出', () {
      final t = mock(agencies: {
        'BABJ': [pt(d12, 30.5, 120.5)],
        'RJTD': [pt(d12, 32.0, 120.5)],
      });
      final r = TyphoonVerdictEngine.routeImpact(typhoon: t, samples: route());
      expect(r.agencyCount, 2);
      expect(r.agencySpreadKm, greaterThan(0));
    });
  });
}
