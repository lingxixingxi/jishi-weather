import 'package:flutter_test/flutter_test.dart';
import 'package:jishiweather/engine/radar_cross_check.dart';

/// 单站雷达 × 和风 的交叉验证：分歧判定与「信央台」策略
void main() {
  RadarCrossCheck make({double? station, double? qw, bool avail = true}) =>
      RadarCrossCheck(
        stationDbz: station == null ? null : 20,
        stationRainMmh: station,
        qweatherRainMmh: qw,
        stationName: '南京',
        qweatherAvailable: avail,
      );

  group('一致的情形', () {
    test('都没雨 → 不分歧', () {
      final c = make(station: 0, qw: 0);
      expect(c.diverged, isFalse);
      expect(c.conclusion, contains('一致'));
      expect(c.conclusion, contains('无降水'));
    });

    test('都有雨且接近 → 不分歧', () {
      final c = make(station: 1.2, qw: 1.0);
      expect(c.diverged, isFalse);
      expect(c.conclusion, contains('一致'));
    });

    test('雷达无回波(0) 与和风微量(0.05) → 不分歧', () {
      final c = make(station: 0, qw: 0.05);
      expect(c.diverged, isFalse);
    });
  });

  group('分歧的情形（一律信央台）', () {
    test('雷达有雨、和风报无雨 → 分歧，采用雷达值', () {
      final c = make(station: 3.5, qw: 0);
      expect(c.diverged, isTrue);
      expect(c.adoptedRainMmh, 3.5);
      expect(c.conclusion, contains('以雷达为准'));
      expect(c.conclusion, contains('雷达有回波'));
    });

    test('和风报有雨、雷达无回波 → 分歧，采用雷达（无雨）', () {
      final c = make(station: 0, qw: 4.0);
      expect(c.diverged, isTrue);
      expect(c.adoptedRainMmh, 0);
      expect(c.conclusion, contains('当前无降水'));
    });

    test('都有雨但差值 ≥2mm/h → 分歧', () {
      final c = make(station: 6.0, qw: 1.0);
      expect(c.diverged, isTrue);
      expect(c.adoptedRainMmh, 6.0);
    });

    test('都有雨、差值小但倍数 ≥3 → 分歧', () {
      // 0.5 vs 1.8：差 1.3（<2），但倍数 3.6（≥3）
      final c = make(station: 1.8, qw: 0.5);
      expect(c.diverged, isTrue);
    });

    test('和风不可用时不算分歧', () {
      final c = make(station: 5.0, qw: 5.0, avail: false);
      expect(c.diverged, isFalse);
      expect(c.conclusion, contains('无和风数据可比对'));
    });

    test('和风值为 null 时不算分歧', () {
      final c = make(station: 5.0, qw: null);
      expect(c.diverged, isFalse);
    });
  });

  group('dBZ → 降水', () {
    test('null 进 null 出', () {
      expect(RadarCrossCheck.rainFromDbz(null), isNull);
    });

    test('越强回波对应越大的降水', () {
      final weak = RadarCrossCheck.rainFromDbz(15)!;
      final mid = RadarCrossCheck.rainFromDbz(30)!;
      final heavy = RadarCrossCheck.rainFromDbz(45)!;
      expect(mid, greaterThan(weak));
      expect(heavy, greaterThan(mid));
    });
  });
}
