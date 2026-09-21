import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:jishiweather/data/radar_stations.dart';
import 'package:jishiweather/services/nmc_station_radar.dart';

/// 单站雷达：站点表 + 投影换算 + 覆盖判定
void main() {
  group('站点表', () {
    test('站点数量与唯一性', () {
      expect(kRadarStations.length, greaterThan(150));
      final codes = kRadarStations.map((s) => s.code).toSet();
      expect(codes.length, kRadarStations.length, reason: '站点码应唯一');
      for (final s in kRadarStations) {
        expect(s.code, matches(RegExp(r'^AZ\d{4}$')));
        expect(s.lat.abs(), lessThanOrEqualTo(90));
        expect(s.lon.abs(), lessThanOrEqualTo(180));
      }
    });

    test('最近站点：南京 → 南京站', () {
      final s = nearestRadarStation(32.06, 118.80);
      expect(s.name, '南京');
      expect(s.code, 'AZ9250');
    });

    test('最近站点：上海 → 就近站（青浦/南汇/杭州之一）', () {
      final s = nearestRadarStation(31.23, 121.47);
      expect(['青浦', '南汇', '杭州', '嘉兴', '苏州'].contains(s.name), isTrue,
          reason: '实际选中 ${s.name}');
    });

    test('最近站点：北京 → 大兴站', () {
      final s = nearestRadarStation(39.90, 116.41);
      expect(s.code, 'AZ9010');
    });
  });

  group('单站图投影', () {
    // 南京站自身坐标
    const stLat = 32.06;
    const stLon = 118.80;

    test('雷达站本身落在图中心附近', () {
      final p = NmcStationRadar.latLonToPixel(stLat, stLon, stLat, stLon);
      expect(p, isNotNull);
      expect((p!.x - NmcStationRadar.centerX).abs(), lessThan(0.01));
      expect((p.y - NmcStationRadar.centerY).abs(), lessThan(0.01));
    });

    test('上海在南京东南方向 → 像素位于中心右下', () {
      final p = NmcStationRadar.latLonToPixel(31.23, 121.47, stLat, stLon);
      expect(p, isNotNull);
      expect(p!.x, greaterThan(NmcStationRadar.centerX));
      expect(p.y, greaterThan(NmcStationRadar.centerY));
      // 上海在南京以东约 253km、以南约 92km
      expect((p.x - NmcStationRadar.centerX) * NmcStationRadar.kmPerPx,
          closeTo(253, 12));
      expect((p.y - NmcStationRadar.centerY) * NmcStationRadar.kmPerPx,
          closeTo(92, 12));
    });

    test('杭州在图内，且距离与实测一致', () {
      final p = NmcStationRadar.latLonToPixel(30.27, 120.15, stLat, stLon);
      expect(p, isNotNull);
      final d = NmcStationRadar.distanceKm(stLat, stLon, 30.27, 120.15);
      // 像素距离换算回公里，应与大圆距离接近（等距投影的固有误差 < 3%）
      final pxDist = math.sqrt(math.pow(p!.x - NmcStationRadar.centerX, 2) +
          math.pow(p.y - NmcStationRadar.centerY, 2));
      expect(pxDist * NmcStationRadar.kmPerPx, closeTo(d, d * 0.05));
    });

    test('超出覆盖范围返回 null（官方 256km）', () {
      // 北京距南京约 900km，远超 256km
      expect(NmcStationRadar.latLonToPixel(39.90, 116.41, stLat, stLon), isNull);
      expect(NmcStationRadar.covers(39.90, 116.41, stLat, stLon), isFalse);
      // 合肥约 150km，应在范围内
      expect(NmcStationRadar.covers(31.86, 117.28, stLat, stLon), isTrue);
    });

    test('覆盖半径与官方标注吻合（反推 250~270km）', () {
      final inferred = (NmcStationRadar.mapWidth / 2) * NmcStationRadar.kmPerPx;
      expect(inferred, greaterThan(240));
      expect(inferred, lessThan(280));
      expect(NmcStationRadar.coverageKm, 256);
    });
  });

  group('工具函数', () {
    test('文件名模板提取', () {
      final t = NmcStationRadar.templateFromUrl(
        'https://image.nmc.cn/product/2026/09/21/RDCP/'
        'SEVP_AOC_RDCP_SLDAS3_ECREF_AZ9250_L88_PI_20260921130200000.PNG?v=1',
      );
      expect(t, 'SEVP_AOC_RDCP_SLDAS3_ECREF_AZ9250_L88_');
    });

    test('距离计算（南京-上海约 270km）', () {
      final d = NmcStationRadar.distanceKm(32.06, 118.80, 31.23, 121.47);
      expect(d, greaterThan(240));
      expect(d, lessThan(300));
    });
  });
}
