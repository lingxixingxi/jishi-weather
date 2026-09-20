import 'package:flutter_test/flutter_test.dart';
import 'package:jishiweather/data/bortle_scale.dart';
import 'package:jishiweather/engine/moon_calculator.dart';
import 'package:jishiweather/engine/photo_index.dart';
import 'package:jishiweather/engine/solar_calculator.dart';
import 'package:jishiweather/services/open_meteo_extra.dart';

/// 摄影指数回归测试
///
/// 起点是一个**真实 bug**：2026-09-20 南京是阴天（总云量 84%、WMO 天气码 3），
/// App 却给出「火烧云 91 分 极佳」。根因是模型只看分层云量做加权平均，
/// 总云量根本没参与，且「中云 82% + 高云 0%」被算术平均成 41%（落进最佳区间）。
///
/// 本文件锁定修复后的行为。
void main() {
  // 南京
  const lat = 31.9585;
  const lon = 118.8317;

  ExtraHourly mk({
    required DateTime time,
    double? cloud,
    double? low,
    double? mid,
    double? high,
    double? vis,
    double? hum,
    double? precip,
    int? prob,
    int? code,
    double? aod,
    double? pm25,
    int? aqi,
  }) =>
      ExtraHourly(
        time: time,
        cloudCover: cloud,
        cloudLow: low,
        cloudMid: mid,
        cloudHigh: high,
        visibility: vis,
        humidity: hum,
        precipitation: precip,
        precipProb: prob,
        weatherCode: code,
        aod: aod,
        pm25: pm25,
        aqi: aqi,
      );

  ExtraWeather wrap(
    List<ExtraHourly> list, {
    DateTime? sunrise,
    DateTime? sunset,
  }) =>
      ExtraWeather(
        hourly: list,
        sunrise: sunrise == null ? const {} : {ExtraWeather.dayKey(sunrise): sunrise},
        sunset: sunset == null ? const {} : {ExtraWeather.dayKey(sunset): sunset},
        lat: lat,
        lon: lon,
      );

  group('阴天否决（回归 91 分 bug）', () {
    // 2026-09-20 18:00 的实测值：总云量 84%、中云 82%、高云 0%、低云 16%
    final sunsetTime = DateTime(2026, 9, 20, 18, 4);
    final sample = mk(
      time: DateTime(2026, 9, 20, 18, 0),
      cloud: 84,
      low: 16,
      mid: 82,
      high: 0,
      vis: 11.26,
      hum: 82,
      precip: 0,
      prob: 0,
      code: 3, // 阴
      aod: 0.55,
      pm25: 36.6,
    );

    test('阴天（总云量 84%）不得判为「极佳」', () {
      final s = PhotoIndexEngine.sunset(wrap([sample], sunset: sunsetTime), sunsetTime);
      expect(s, isNotNull);
      // 修复前是 91；修复后应落在「较差」
      expect(s!.score, lessThan(30));
      expect(s.grade, '较差');
      expect(s.cloudGate, lessThan(0.3));
    });

    test('总云量 100%（全阴）几乎归零', () {
      final full = mk(
        time: DateTime(2026, 9, 20, 18, 0),
        cloud: 100,
        low: 5,
        mid: 100,
        high: 0,
        vis: 20,
        hum: 70,
        precip: 0,
        prob: 0,
        code: 3,
        aod: 0.1,
      );
      final s = PhotoIndexEngine.sunset(wrap([full], sunset: sunsetTime), sunsetTime);
      expect(s!.score, lessThan(8));
    });

    test('理想多云（可照亮云量 50%、总云量 45%）应得高分', () {
      final good = mk(
        time: DateTime(2026, 9, 20, 18, 0),
        cloud: 45,
        low: 10,
        mid: 30,
        high: 30,
        vis: 22,
        hum: 60,
        precip: 0,
        prob: 5,
        code: 2,
        aod: 0.12,
      );
      final s = PhotoIndexEngine.sunset(wrap([good], sunset: sunsetTime), sunsetTime);
      expect(s!.score, greaterThan(70));
    });
  });

  group('中高云用并集而非平均', () {
    test('中云82+高云0 合成 82%，不被误判为最佳区间', () {
      expect(PhotoIndexEngine.canvasCloud(82, 0), closeTo(82, 0.01));
      expect(PhotoIndexEngine.canvasCloud(0, 82), closeTo(82, 0.01));
      // 并集公式：1-(1-0.4)(1-0.3)=0.58
      expect(PhotoIndexEngine.canvasCloud(40, 30), closeTo(58, 0.01));
      expect(PhotoIndexEngine.canvasCloud(0, 0), 0);
      expect(PhotoIndexEngine.canvasCloud(100, 100), 100);
    });
  });

  group('星空的云门槛比火烧云更严', () {
    test('同样 30% 总云量，星空门槛远低于火烧云', () {
      final sun = PhotoIndexEngine.sunCloudGate(total: 30, low: 5, code: 1);
      final star = PhotoIndexEngine.starCloudGate(total: 30, low: 5, code: 1);
      expect(sun, closeTo(1.0, 0.01)); // 火烧云此时仍满分
      expect(star, lessThan(0.35)); // 观星已大幅压制
    });

    test('观星要「万里无云」：5% 才满分，15% 已明显打折', () {
      expect(PhotoIndexEngine.starCloudGate(total: 5, low: 0, code: 0), closeTo(1.0, 0.01));
      expect(PhotoIndexEngine.starCloudGate(total: 10, low: 0, code: 0), lessThan(0.9));
      expect(PhotoIndexEngine.starCloudGate(total: 15, low: 0, code: 0), closeTo(0.75, 0.02));
      expect(PhotoIndexEngine.starCloudGate(total: 40, low: 0, code: 0), lessThan(0.25));
      expect(PhotoIndexEngine.starCloudGate(total: 70, low: 0, code: 0), lessThan(0.06));
    });
  });

  group('月相（月明星稀）', () {
    test('2026-09-11 是新月', () {
      final m = MoonCalculator.at(DateTime(2026, 9, 11, 20), lat, lon);
      expect(m.illumination, lessThan(0.03));
      expect(m.phaseName, '新月');
      // 新月无月光干扰
      expect(m.darknessFactor, greaterThan(0.95));
    });

    test('2026-09-18 上弦月，照亮约 50%', () {
      final m = MoonCalculator.at(DateTime(2026, 9, 18, 20), lat, lon);
      expect(m.illumination, greaterThan(0.35));
      expect(m.illumination, lessThan(0.65));
      expect(m.phaseName, '上弦月');
    });

    test('2026-09-26 满月，照亮接近 100%', () {
      final m = MoonCalculator.at(DateTime(2026, 9, 26, 23), lat, lon);
      expect(m.illumination, greaterThan(0.95));
      expect(m.phaseName, '满月');
    });

    test('月亮在地平线下时不构成干扰', () {
      const m = MoonInfo(
        illumination: 1.0,
        ageDays: 14.7,
        phaseName: '满月',
        altitudeDeg: -12,
        azimuthDeg: 10,
      );
      expect(m.isUp, isFalse);
      expect(m.darknessFactor, 1.0);
    });

    test('满月比新月显著压低星空分（其余条件相同）', () {
      // 同样「万里无云 + 空气通透」的两夜
      final newMoonNight = DateTime(2026, 9, 11, 23);
      final fullMoonNight = DateTime(2026, 9, 26, 23);

      ExtraWeather night(DateTime t) => wrap([
            mk(
              time: t,
              cloud: 3,
              low: 0,
              mid: 0,
              high: 3,
              vis: 22,
              hum: 60,
              precip: 0,
              prob: 0,
              code: 0, // 晴
              aod: 0.10,
              pm25: 12,
            )
          ]);

      final a = PhotoIndexEngine.starry(night(newMoonNight), newMoonNight, bortle: 1);
      final b = PhotoIndexEngine.starry(night(fullMoonNight), fullMoonNight, bortle: 1);
      expect(a, isNotNull);
      expect(b, isNotNull);
      // 新月夜 + 极暗机位应接近满分
      expect(a!.score, greaterThan(75));
      // 满月夜即使万里无云也要被压到很低
      expect(b!.score, lessThan(30));
      expect(b.score, lessThan(a.score));
    });
  });

  group('光污染 Bortle', () {
    test('等级越高因子越低（与文档线性扣分等价）', () {
      expect(BortleScale.factor(1), closeTo(1.00, 0.001));
      expect(BortleScale.factor(5), closeTo(0.76, 0.001));
      expect(BortleScale.factor(7), closeTo(0.64, 0.001));
      expect(BortleScale.factor(9), closeTo(0.52, 0.001));
      // 单调不增
      for (var b = 1; b < 9; b++) {
        expect(BortleScale.factor(b) >= BortleScale.factor(b + 1), isTrue);
      }
    });

    test('只有 Bortle ≤ 4 才算"暗到能拍银河"', () {
      expect(BortleScale.isDarkEnough(1), isTrue);
      expect(BortleScale.isDarkEnough(4), isTrue);
      expect(BortleScale.isDarkEnough(5), isFalse);
      expect(BortleScale.isDarkEnough(9), isFalse);
    });

    test('同一夜不同光污染等级会拉开星空分', () {
      final t = DateTime(2026, 9, 11, 23); // 新月夜
      ExtraWeather night() => wrap([
            mk(
              time: t,
              cloud: 3,
              low: 0,
              mid: 0,
              high: 3,
              vis: 22,
              hum: 60,
              precip: 0,
              prob: 0,
              code: 0,
              aod: 0.10,
              pm25: 12,
            )
          ]);

      final dark = PhotoIndexEngine.starry(night(), t, bortle: 1)!; // 极暗荒野
      final rural = PhotoIndexEngine.starry(night(), t, bortle: 4)!; // 乡村
      final city = PhotoIndexEngine.starry(night(), t, bortle: 9)!; // 城市中心

      expect(dark.score, greaterThan(rural.score));
      expect(rural.score, greaterThan(city.score));
      // 城市中心即使万里无云、新月，也拍不出好星空
      expect(city.score, lessThan(dark.score * 0.6));
      // 因子出现在公式文案里
      expect(city.formulaText, contains('光污染'));
    });
  });

  group('空气质量', () {
    test('AOD 越低分越高', () {
      final clean = PhotoIndexEngine.airQualityScore(0.05, null);
      final good = PhotoIndexEngine.airQualityScore(0.15, null);
      final fair = PhotoIndexEngine.airQualityScore(0.40, null);
      final hazy = PhotoIndexEngine.airQualityScore(0.90, null);
      expect(clean, greaterThan(good));
      expect(good, greaterThan(fair));
      expect(fair, greaterThan(hazy));
      expect(clean, 100);
    });

    test('AOD 缺失时退回 PM2.5', () {
      expect(PhotoIndexEngine.airQualityScore(null, 10), 100);
      expect(PhotoIndexEngine.airQualityScore(null, 30), 85);
      expect(PhotoIndexEngine.airQualityScore(null, 60), 60);
      expect(PhotoIndexEngine.airQualityScore(null, 200), 10);
    });

    test('两者都缺失给中性分', () {
      expect(PhotoIndexEngine.airQualityScore(null, null), 60);
    });

    test('空气质量差会拉低火烧云分', () {
      final t = DateTime(2026, 9, 20, 18, 4);
      ExtraWeather at(double aod) => wrap(
            [
              mk(
                time: DateTime(2026, 9, 20, 18, 0),
                cloud: 45,
                low: 10,
                mid: 30,
                high: 30,
                vis: 22,
                hum: 60,
                precip: 0,
                prob: 5,
                code: 2,
                aod: aod,
              )
            ],
            sunset: t,
          );
      final clear = PhotoIndexEngine.sunset(at(0.08), t)!;
      final murky = PhotoIndexEngine.sunset(at(1.10), t)!;
      expect(clear.score, greaterThan(murky.score));
    });
  });

  group('恶劣天气否决', () {
    test('雾 / 雨 / 雪 / 雷暴都算恶劣天气，阴（码3）不算', () {
      expect(PhotoIndexEngine.isBadWeather(45), isTrue); // 雾
      expect(PhotoIndexEngine.isBadWeather(61), isTrue); // 雨
      expect(PhotoIndexEngine.isBadWeather(75), isTrue); // 雪
      expect(PhotoIndexEngine.isBadWeather(95), isTrue); // 雷暴
      expect(PhotoIndexEngine.isBadWeather(3), isFalse); // 阴 —— 由云量门槛处理
      expect(PhotoIndexEngine.isBadWeather(0), isFalse); // 晴
      expect(PhotoIndexEngine.isBadWeather(null), isFalse);
    });
  });

  group('天文时刻（太阳 / 月亮）', () {
    // 南京
    const lat = 31.9585;
    const lon = 118.8317;

    test('太阳高度角 0° 反算出的日落与 Open-Meteo 一致（±10 分钟）', () {
      // Open-Meteo 给的 2026-09-20 南京日落 = 18:04
      final sunset = SolarCalculator.crossing(
        DateTime(2026, 9, 20, 17, 0),
        DateTime(2026, 9, 20, 19, 0),
        0.0,
        lat,
        lon,
      );
      expect(sunset, isNotNull);
      final diff = sunset!.difference(DateTime(2026, 9, 20, 18, 4)).inMinutes.abs();
      expect(diff, lessThanOrEqualTo(10), reason: '自算日落 $sunset 与 18:04 偏差过大');
    });

    test('正午太阳高度角在合理范围（南京 9 月约 55~62°）', () {
      final noon = SolarCalculator.noonAltitude(DateTime(2026, 9, 20), lat, lon);
      expect(noon, greaterThan(50));
      expect(noon, lessThan(70));
    });

    test('傍晚：黄金时刻跨日落、蓝调紧随其后', () {
      final sunset = DateTime(2026, 9, 20, 18, 4);
      final golden = SolarCalculator.goldenHourEvening(sunset, lat, lon);
      final blue = SolarCalculator.blueHourEvening(sunset, lat, lon);

      expect(golden.isValid, isTrue);
      expect(blue.isValid, isTrue);
      // 黄金时刻：+6° 开始（日落前），到 −4° 结束（日落后）
      expect(golden.start!.isBefore(sunset), isTrue);
      expect(golden.end!.isAfter(sunset), isTrue);
      // 蓝调：−4° → −6°，完全在黄金时刻结束之后
      expect(blue.start!.isAfter(golden.end!.subtract(const Duration(minutes: 1))), isTrue);
      expect(blue.end!.isAfter(blue.start!), isTrue);
      // 蓝调时段（−4° → −7°）约 13 分钟（实际拍摄经验：10~15 分钟）
      final blueMin = blue.end!.difference(blue.start!).inMinutes;
      expect(blueMin, inInclusiveRange(10, 18));

      // 黄金时刻（+6° → −4°）约 40 分钟（实际经验：整个日落流程 30~45 分钟）
      final goldenMin = golden.end!.difference(golden.start!).inMinutes;
      expect(goldenMin, inInclusiveRange(30, 50));
    });

    test('清晨：蓝调在日出前、黄金时刻跨日出', () {
      final sunrise = DateTime(2026, 9, 20, 5, 51);
      final blue = SolarCalculator.blueHourMorning(sunrise, lat, lon);
      final golden = SolarCalculator.goldenHourMorning(sunrise, lat, lon);

      expect(blue.isValid, isTrue);
      expect(golden.isValid, isTrue);
      expect(blue.start!.isBefore(sunrise), isTrue);
      expect(blue.end!.isBefore(sunrise.add(const Duration(minutes: 1))), isTrue);
      expect(golden.start!.isBefore(sunrise), isTrue);
      expect(golden.end!.isAfter(sunrise), isTrue);
    });

    test('月出月落能算出（满月当天前后各有一次）', () {
      final rise = MoonCalculator.moonrise(DateTime(2026, 9, 26), lat, lon);
      final set = MoonCalculator.moonset(DateTime(2026, 9, 26), lat, lon);
      // 满月（9/26）当天：月出约在傍晚、月落约在清晨，两者都应能定位
      expect(rise, isNotNull, reason: '满月当天应能算出月出');
      expect(set, isNotNull, reason: '满月当天应能算出月落');
      expect(rise!.day, 26);
      expect(set!.day, 26);
      // 月出时刻的月亮应刚好在地平线附近
      final altAtRise = MoonCalculator.at(rise, lat, lon).altitudeDeg;
      expect(altAtRise.abs(), lessThan(1.0));
    });

    test('月出月落与新月/满月的关系合理', () {
      // 新月（9/11）当天，月亮基本与太阳同行：白天在天上，夜间在地平线下
      final m = MoonCalculator.at(DateTime(2026, 9, 11, 23), lat, lon);
      expect(m.isUp, isFalse, reason: '新月夜间月亮应已落下');
      // 满月（9/26）深夜，月亮应高挂
      final f = MoonCalculator.at(DateTime(2026, 9, 26, 23), lat, lon);
      expect(f.isUp, isTrue, reason: '满月深夜月亮应在天上');
      expect(f.altitudeDeg, greaterThan(20));
    });
  });
}
