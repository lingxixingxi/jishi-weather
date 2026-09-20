import 'package:flutter_test/flutter_test.dart';
import 'package:jishiweather/models/typhoon_track.dart';
import 'package:jishiweather/models/weather_warning.dart';
import 'package:jishiweather/services/warning_service.dart';

/// 锁定两处纯逻辑：
/// 1. 气象预警的标题解析与行政区划前缀匹配（正则 + adcode 规则）
/// 2. 台风等级的风速→中文映射（国标 GB/T 19201-2006 界限）
///
/// 样本全部取自 **2026-09-20 中央气象台接口实际返回**。
void main() {
  group('预警标题解析', () {
    test('标准标题：省市区 + 类型 + 颜色', () {
      final p = WeatherWarning.parseTitle('贵州省贵阳市白云区气象台发布大风蓝色预警信号');
      expect(p.region, '贵州省贵阳市白云区');
      expect(p.type, '大风');
      expect(p.severity, WarningSeverity.blue);
    });

    test('复合类型名（雷雨大风）不被截断', () {
      final p = WeatherWarning.parseTitle('广东省广州市从化区气象台发布雷雨大风黄色预警信号');
      expect(p.type, '雷雨大风');
      expect(p.severity, WarningSeverity.yellow);
    });

    test('四种颜色都能识别', () {
      expect(
        WeatherWarning.parseTitle('X气象台发布雷电蓝色预警信号').severity,
        WarningSeverity.blue,
      );
      expect(
        WeatherWarning.parseTitle('X气象台发布雷电黄色预警信号').severity,
        WarningSeverity.yellow,
      );
      expect(
        WeatherWarning.parseTitle('X气象台发布暴雨橙色预警信号').severity,
        WarningSeverity.orange,
      );
      expect(
        WeatherWarning.parseTitle('X气象台发布台风红色预警信号').severity,
        WarningSeverity.red,
      );
    });

    test('带后缀的标题仍能解析（[II级/严重] 之类）', () {
      final p = WeatherWarning.parseTitle('浙江省杭州市气象台发布暴雨橙色预警信号[II级/严重]');
      expect(p.type, '暴雨');
      expect(p.severity, WarningSeverity.orange);
    });

    test('非常规标题兜底：至少捞出颜色', () {
      final p = WeatherWarning.parseTitle('某地发布高温红色预警');
      expect(p.severity, WarningSeverity.red);
    });
  });

  group('预警解析（原始记录）', () {
    test('alertid 前 6 位作为行政区划码', () {
      final w = WeatherWarning.parse({
        'alertid': '52011341600000_20260920141525',
        'issuetime': '2026/09/20 14:15',
        'title': '贵州省贵阳市白云区气象台发布大风蓝色预警信号',
        'url': '/publish/alarm/x.html',
        'pic': 'https://image.nmc.cn/assets/img/alarm/p0007004.png',
      });
      expect(w, isNotNull);
      expect(w!.adcode, '520113');
      expect(w.issueTime, DateTime(2026, 9, 20, 14, 15));
      expect(w.detailUrl, 'http://www.nmc.cn/publish/alarm/x.html');
      expect(w.rank, 1);
    });

    test('alertid 过短则丢弃', () {
      expect(WeatherWarning.parse({'alertid': '123'}), isNull);
    });
  });

  group('行政区划前缀匹配', () {
    WeatherWarning mk(String adcode, WarningSeverity s) => WeatherWarning(
          id: '${adcode}000000_20260920120000',
          adcode: adcode,
          region: '测试',
          type: '大风',
          severity: s,
          title: '测试',
        );

    test('同区县 / 同市 / 同省 逐级退让', () {
      expect(mk('320115', WarningSeverity.blue).scopeFor('320115'),
          WarningScope.district);
      expect(mk('320102', WarningSeverity.blue).scopeFor('320115'),
          WarningScope.city);
      expect(mk('321002', WarningSeverity.blue).scopeFor('320115'),
          WarningScope.province);
      expect(mk('110101', WarningSeverity.blue).scopeFor('320115'), isNull);
    });

    test('过滤默认排除「同省」，按其可选开启', () {
      final all = [
        mk('320115', WarningSeverity.yellow), // 本区
        mk('320102', WarningSeverity.red), // 本市
        mk('321002', WarningSeverity.orange), // 同省
      ];
      final base = WarningService.filter(all, '320115');
      expect(base.length, 2);
      expect(base.every((w) => w.adcode != '321002'), isTrue);

      final withProv = WarningService.filter(all, '320115', includeProvince: true);
      expect(withProv.length, 3);
    });

    test('结果按危险度倒序（红色优先）', () {
      final all = [
        mk('320115', WarningSeverity.blue),
        mk('320116', WarningSeverity.red),
        mk('320117', WarningSeverity.yellow),
      ];
      final r = WarningService.filter(all, '320115');
      expect(r.map((w) => w.severity).toList(), [
        WarningSeverity.red,
        WarningSeverity.yellow,
        WarningSeverity.blue,
      ]);
    });

    test('adcode 非法时返回空', () {
      expect(WarningService.filter([mk('320115', WarningSeverity.red)], null), isEmpty);
      expect(WarningService.filter([mk('320115', WarningSeverity.red)], '32'), isEmpty);
    });
  });

  group('台风等级映射（国标界限）', () {
    test('各等级分界点', () {
      expect(TyphoonLevel.textByWind(10.8), '热带低压');
      expect(TyphoonLevel.textByWind(17.1), '热带低压');
      expect(TyphoonLevel.textByWind(17.2), '热带风暴');
      expect(TyphoonLevel.textByWind(24.4), '热带风暴');
      expect(TyphoonLevel.textByWind(24.5), '强热带风暴');
      expect(TyphoonLevel.textByWind(30.0), '强热带风暴'); // 实测杜鹃 30 m/s
      expect(TyphoonLevel.textByWind(32.6), '强热带风暴');
      expect(TyphoonLevel.textByWind(32.7), '台风');
      expect(TyphoonLevel.textByWind(41.4), '台风');
      expect(TyphoonLevel.textByWind(41.5), '强台风');
      expect(TyphoonLevel.textByWind(50.9), '强台风');
      expect(TyphoonLevel.textByWind(51.0), '超强台风');
    });

    test('等级码 → 中文', () {
      expect(TyphoonLevel.text('STS'), '强热带风暴');
      expect(TyphoonLevel.text('SuperTY'), '超强台风');
      expect(TyphoonLevel.text(null), '未知');
    });

    test('无名台风的 nameCn 即等级', () {
      expect(TyphoonLevel.isLevelText('热带低压'), isTrue);
      expect(TyphoonLevel.isLevelText('杜鹃'), isFalse);
    });

    test('移动方向与机构名', () {
      expect(TyphoonLevel.directionText('N'), '北');
      expect(TyphoonLevel.directionText('NNW'), '北西北');
      expect(TyphoonLevel.directionText(null), '—');
      expect(TyphoonLevel.agencyText('BABJ'), '中央气象台');
    });
  });

  group('距离计算', () {
    test('同点为 0', () {
      expect(distanceKm(31.0, 121.0, 31.0, 121.0), closeTo(0, 0.001));
    });

    test('纬度 1 度约 111 km', () {
      expect(distanceKm(31.0, 121.0, 32.0, 121.0), closeTo(111.2, 0.5));
    });
  });
}
