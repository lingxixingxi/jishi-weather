import 'package:flutter_test/flutter_test.dart';
import 'package:jishiweather/models/hourly_weather.dart';
import 'package:jishiweather/services/multi_source_service.dart';
import 'package:jishiweather/services/nmc_service.dart';

/// 锁定「中心点天气现象」的口径 —— 2026-09-26 真机实测 bug 的回归测试。
///
/// **现象**：南京 2026-09-26 13:00 实况大雨（央台 `rain1h=13.5 mm/h`、
/// `real.weather.info="大雨"`、雷达 35 dBZ 中到大雨），地点页区域概览却显示
/// 「采用 中央气象台 / 中心 **阴** 22.2°」—— 温度、降水概率都是央台真值，
/// 唯独天气现象是「阴」。
///
/// **根因**（同一病根的三处实现，全都"只看云量、没有降水档"）：
/// 1. `MultiSourceService.nmcForecastAt()` 实测分支不传 weatherText
/// 2. `ModelForecast.enriched()` 无文字时 `_textFromCloud(cloud)` 反推 ——
///    而 `estimateCloudCover` 对降水直接给 90（≥85）→ 恒为「阴」
/// 3. 调用方 `src.weatherText ?? 云量共识` 回落 —— 共识同样只有 晴/少云/多云/阴
void main() {
  group('降水强度分级 HourlyWeather.levelOf', () {
    test('界限（小时雨强，与降水强度分级一致）', () {
      expect(HourlyWeather.levelOf(null), '未知');
      expect(HourlyWeather.levelOf(0), '无雨');
      expect(HourlyWeather.levelOf(0.09), '无雨');
      expect(HourlyWeather.levelOf(0.1), '小雨');
      expect(HourlyWeather.levelOf(2.49), '小雨');
      expect(HourlyWeather.levelOf(2.5), '中雨');
      expect(HourlyWeather.levelOf(7.99), '中雨');
      expect(HourlyWeather.levelOf(8.0), '大雨');
      expect(HourlyWeather.levelOf(15.99), '大雨');
      expect(HourlyWeather.levelOf(16.0), '暴雨');
    });

    test('实测样本：央台 13.5 mm/h → 大雨（与它自己的 info 一致）', () {
      expect(HourlyWeather.levelOf(13.5), '大雨');
    });
  });

  group('enriched() 的天气文字兜底', () {
    test('有降水 → 按降水强度给文字，不被云量带成「阴」', () {
      const f = ModelForecast(
        model: 'nmc',
        displayName: '中央气象台',
        temperature: 22.2,
        humidity: 100,
        precipitation: 13.5, // 实测 rain1h
      );
      final e = f.enriched();
      // 云量估算仍是 90（≥85，会反推出「阴」），但文字必须按降水走
      expect(e.cloudCover, 90);
      expect(e.weatherText, '大雨');
    });

    test('无降水 → 仍按云量反推（阴 / 多云 / 少云 / 晴）', () {
      const f = ModelForecast(
        model: 'nmc',
        displayName: '中央气象台',
        temperature: 22,
        precipitation: 0,
      );
      // 无文字、无降水 → estimateCloudCover 退化为 50 → 落在 30~60 → 少云
      expect(f.enriched().cloudCover, 50);
      expect(f.enriched().weatherText, '少云');
    });

    test('已有原文时不被改写', () {
      const f = ModelForecast(
        model: 'nmc',
        displayName: '中央气象台',
        precipitation: 13.5,
        weatherText: '大雨',
      );
      expect(f.enriched().weatherText, '大雨');
    });
  });

  group('nmcForecastAt 实测分支带上实况文字', () {
    NmcWeather buildNmc() => NmcWeather(
          stationId: 'CxOWZ',
          cityName: '南京',
          weatherText: '大雨', // real.weather.info
          temperature: 22.1,
          humidity: 100,
          rain: 13.5,
          history: [
            NmcHourlyPoint(
              time: DateTime.now(),
              temperature: 22.2,
              rain1h: 13.5,
              humidity: 100,
              windSpeed: 1.2,
              windDirection: 82,
            ),
          ],
        );

    test('当前时刻用 passedchart 实测，同时带上 info 原文', () {
      final f = MultiSourceService.nmcForecastAt(buildNmc(), DateTime.now());
      expect(f.isObservation, isTrue);
      expect(f.precipitation, 13.5);
      expect(f.weatherText, '大雨');
    });

    test('远离当前（>90 分钟）的过去时刻不贴「此刻的实况」文字', () {
      final t = DateTime.now().subtract(const Duration(hours: 5));
      final f = MultiSourceService.nmcForecastAt(buildNmc(), t);
      // 不贴实况 → 交给降水强度分级（13.5 → 大雨），总之不得是「阴」
      expect(f.weatherText, isNot('阴'));
    });
  });

  group('中心点文本决策 effectiveWeatherText', () {
    MultiModelHourly build({String? nmcText, double? nmcRain}) => MultiModelHourly(
          place: '南京市江宁区',
          lat: 31.9585,
          lon: 118.8318,
          time: DateTime(2026, 9, 26, 13),
          sources: [
            const ModelForecast(
              model: 'ecmwf_ifs025',
              displayName: 'ECMWF',
              temperature: 22.5,
              precipitation: 1.2,
              precipitationProbability: 95,
              cloudCover: 100,
            ),
            const ModelForecast(
              model: 'gfs',
              displayName: 'GFS',
              temperature: 22.3,
              precipitation: 0.8,
              precipitationProbability: 92,
              cloudCover: 100,
            ),
            ModelForecast(
              model: 'nmc',
              displayName: '中央气象台',
              temperature: 22.2,
              precipitation: nmcRain,
              precipitationProbability: 100,
              cloudCover: 95,
              weatherText: nmcText,
            ),
          ],
        );

    test('回归：有降水、原文缺失 → 按强度分级（大雨），绝不是「阴」', () {
      final m = build(nmcRain: 13.5);
      expect(m.effectiveWeatherText(sourceText: null, sourcePrecipitation: 13.5), '大雨');
    });

    test('有降水 + 原文与数值一致 → 结果相同（央台 info=暴雨、rain1h=20.7）', () {
      final m = build(nmcText: '暴雨', nmcRain: 20.7);
      expect(m.effectiveWeatherText(sourceText: '暴雨', sourcePrecipitation: 20.7), '暴雨');
    });

    test('回归：有降水时以**数值分级**为准，不采用与数值不符的定性词', () {
      final m = build(nmcText: '毛毛雨', nmcRain: 3.0);
      // 「毛毛雨」配 3.0 mm/h 是自相矛盾的（国标 2.5~8 为「中雨」）
      expect(m.effectiveWeatherText(sourceText: '毛毛雨', sourcePrecipitation: 3.0), '中雨');
    });

    test('回归：同一位置「当前」与「15 时」不再一个毛毛雨一个中雨', () {
      // 修前：当前时刻用最优源的**定性词**、未来时刻用**融合分级** ——
      // 用户实测「区域概览显示毛毛雨，点一下 15 时就变中雨」，无从判断哪个对。
      // 修后两者都由降水**数值**决定：数值相同 → 文字必然相同。
      final m = build();
      final now = m.effectiveWeatherText(sourceText: '毛毛雨', sourcePrecipitation: 3.0);
      final later = m.effectiveWeatherText(sourceText: '中雨', sourcePrecipitation: 3.0);
      expect(now, later);
      expect(now, '中雨');
    });

    test('无降水 → 才用云量共识（各源云量 95~100% → 阴）', () {
      final m = build(nmcRain: 0);
      expect(m.consensusWeatherText, '阴');
      expect(m.effectiveWeatherText(sourceText: null, sourcePrecipitation: 0), '阴');
    });
  });

  group('当前时刻实况优先（preferObservation）', () {
    /// 复现用户看到的「刚启动显示中雨，突然跳成暴雨」
    MultiModelHourly withObs() => MultiModelHourly(
          place: '南京市江宁区',
          lat: 31.9585,
          lon: 118.8318,
          time: DateTime(2026, 9, 26, 15),
          sources: [
            const ModelForecast(
              model: 'ecmwf_ifs025',
              displayName: 'ECMWF',
              precipitation: 2.0,
              precipitationProbability: 95,
              cloudCover: 100,
            ),
            const ModelForecast(
              model: 'gfs_seamless',
              displayName: 'GFS',
              precipitation: 0.1,
              precipitationProbability: 80,
              cloudCover: 100,
            ),
            const ModelForecast(
              model: 'nmc',
              displayName: '中央气象台',
              precipitation: 20.7, // 实测（passedchart rain1h）
              precipitationProbability: 100,
              cloudCover: 95,
              isObservation: true,
            ),
          ],
        );

    test('回归：实况不与预报平均 —— 融合均值给出中雨，实况优先给出暴雨', () {
      final m = withObs();
      // 融合均值 = (2.0 + 0.1 + 20.7) / 3 = 7.6 mm/h → 「中雨」
      expect(m.precipitation, closeTo(7.6, 0.01));
      expect(m.toHourlyWeather().weatherText, '中雨');

      // 实况优先 → 直接采用央台实测 20.7 → 「暴雨」
      final obs = m.toHourlyWeather(preferObservation: true);
      expect(obs.precipitation, 20.7);
      expect(obs.weatherText, '暴雨');
    });

    test('无实况源时 preferObservation 不改变结果（海外/央台失败场景）', () {
      final m = MultiModelHourly(
        place: '纽北',
        lat: 50.33,
        lon: 6.94,
        time: DateTime(2026, 9, 26, 15),
        sources: const [
          ModelForecast(
            model: 'ecmwf_ifs025',
            displayName: 'ECMWF',
            precipitation: 2.0,
            cloudCover: 100,
          ),
          ModelForecast(
            model: 'gfs_seamless',
            displayName: 'GFS',
            precipitation: 0.1,
            cloudCover: 100,
          ),
        ],
      );
      final fused = m.toHourlyWeather();
      final pref = m.toHourlyWeather(preferObservation: true);
      expect(pref.weatherText, fused.weatherText);
      expect(pref.precipitation, fused.precipitation);
    });
  });
}
