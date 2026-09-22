import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:jishiweather/data/radar_stations.dart';
import 'package:jishiweather/services/nmc_station_radar.dart';
import 'package:jishiweather/services/radar_projection.dart';
import 'package:jishiweather/services/radar_service.dart';

/// 单站雷达：站点表 + 投影换算 + 覆盖判定
/// 投影抽象：拼图 / 单站两套几何，以及产品码识别
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
      expect((p!.x - StationProjection.centerX).abs(), lessThan(0.01));
      expect((p.y - StationProjection.centerY).abs(), lessThan(0.01));
    });

    test('上海在南京东南方向 → 像素位于中心右下', () {
      final p = NmcStationRadar.latLonToPixel(31.23, 121.47, stLat, stLon);
      expect(p, isNotNull);
      expect(p!.x, greaterThan(StationProjection.centerX));
      expect(p.y, greaterThan(StationProjection.centerY));
      // 上海在南京以东约 253km、以南约 92km
      expect((p.x - StationProjection.centerX) * NmcStationRadar.kmPerPx,
          closeTo(253, 12));
      expect((p.y - StationProjection.centerY) * NmcStationRadar.kmPerPx,
          closeTo(92, 12));
    });

    test('杭州在图内，且距离与实测一致', () {
      final p = NmcStationRadar.latLonToPixel(30.27, 120.15, stLat, stLon);
      expect(p, isNotNull);
      final d = NmcStationRadar.distanceKm(stLat, stLon, 30.27, 120.15);
      // 像素距离换算回公里，应与大圆距离接近（等距投影的固有误差 < 3%）
      final pxDist = math.sqrt(
          math.pow(p!.x - StationProjection.centerX, 2) +
              math.pow(p.y - StationProjection.centerY, 2));
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

  group('投影抽象（拼图 / 单站）', () {
    test('拼图投影：经纬度往返换算自洽', () {
      const p = EastChinaProjection();
      final px = p.latLonToPixel(31.23, 121.47);
      final back = p.pixelToLatLon(px.x, px.y);
      expect(back.lat, closeTo(31.23, 1e-6));
      expect(back.lon, closeTo(121.47, 1e-6));
      expect(p.width, 774);
      expect(p.height, 1326);
      // 底部图例（色标）必须排除：mapHeightPx 应小于 1251（实测色带起点）
      expect(p.mapHeightPx, lessThan(1251));
      expect(p.mapHeightPx, greaterThan(1240));
      expect(p.mapWidthPx, 774);
    });

    test('拼图覆盖判定：上海在内、乌鲁木齐在外', () {
      const p = EastChinaProjection();
      expect(p.covers(31.23, 121.47), isTrue);
      // 乌鲁木齐 ≈ 87.6°E，远在拼图西边界（111.7°E）之外
      expect(p.covers(43.83, 87.62), isFalse);
    });

    test('单站投影：地图区宽度排除右侧信息面板', () {
      const p = StationProjection(
        stationCode: 'AZ9250',
        stationName: '南京',
        stationLat: 32.06,
        stationLon: 118.80,
      );
      expect(p.width, 924);
      expect(p.height, 734);
      // 右侧 159px 是信息面板（内含与回波同色的 dBZ 色标条）→ 必须排除
      expect(p.mapWidthPx, 765);
      expect(p.mapHeightPx, 734);
      expect(p.kmPerPixel, closeTo(0.68, 0.01));
      expect(p.label, contains('南京'));
      expect(p.label, contains('AZ9250'));
    });

    test('单站投影：站点自身落在中心，远端越界', () {
      const p = StationProjection(
        stationCode: 'AZ9250',
        stationName: '南京',
        stationLat: 32.06,
        stationLon: 118.80,
      );
      final c = p.latLonToPixel(32.06, 118.80);
      expect(c.x, closeTo(StationProjection.centerX, 0.01));
      expect(c.y, closeTo(StationProjection.centerY, 0.01));
      expect(p.covers(32.06, 118.80), isTrue);
      // 北京 ~900km，远超 256km 覆盖
      expect(p.covers(39.90, 116.41), isFalse);
      // 像素往返自洽
      final back = p.pixelToLatLon(c.x, c.y);
      expect(back.lat, closeTo(32.06, 1e-6));
      expect(back.lon, closeTo(118.80, 1e-6));
    });

    test('两种投影的 km/像素 相差约 4 倍（这正是要区分它们的原因）', () {
      const mosaic = EastChinaProjection();
      const station = StationProjection(
        stationCode: 'AZ9250',
        stationName: '南京',
        stationLat: 32.06,
        stationLon: 118.80,
      );
      expect(mosaic.kmPerPixel / station.kmPerPixel, closeTo(3.8, 0.5));
    });
  });

  group('雷达产品码识别（选源用）', () {
    test('从 URL 提取产品码', () {
      expect(
        RadarService.productCode('https://image.nmc.cn/product/2026/09/22/RDCP/'
            'SEVP_AOC_RDCP_SLDAS3_ECREF_AZ9250_L88_PI_20260922095400000.PNG'),
        'AZ9250',
      );
      expect(
        RadarService.productCode('/product/2026/09/22/RDCP/'
            'SEVP_AOC_RDCP_SLDAS3_ECREF_AECN_L88_PI_20260922095400000.PNG'),
        'AECN',
      );
      expect(RadarService.productCode('没有产品码'), isNull);
    });

    test('单站码识别（AZ 开头）', () {
      expect(RadarService.isStationCode('AZ9250'), isTrue);
      expect(RadarService.isStationCode('AECN'), isFalse);
      expect(RadarService.isStationCode(null), isFalse);
    });

    test('改写为拼图模板：站点码被替换，已是拼图则保持', () {
      expect(
        RadarService.asMosaicTemplate('SEVP_AOC_RDCP_SLDAS3_ECREF_AZ9250_L88_'),
        'SEVP_AOC_RDCP_SLDAS3_ECREF_AECN_L88_',
      );
      expect(
        RadarService.asMosaicTemplate('SEVP_AOC_RDCP_SLDAS3_ECREF_AECN_L88_'),
        'SEVP_AOC_RDCP_SLDAS3_ECREF_AECN_L88_',
      );
    });

    test('单站新鲜度阈值 = 60 分钟（用户口径：当前小时内有更新）', () {
      expect(RadarService.stationFreshMinutes, 60);
      // 外推可信范围仍是 2 小时
      expect(RadarService.forecastMaxMinutes, 120);
    });
  });

  group('回波色标判据（防底图被误判为强回波）', () {
    test('底图浅灰紫/浅蓝灰不得被判成 65 dBZ（实测误报源）', () {
      // 单站图底图上的这些像素到 65 dBZ 紫色 (173,144,240) 距离仅 72~96，
      // 旧判据（阈值 96、无饱和度门槛）会把它们判成「强降水/冰雹」。
      expect(RadarPalette.rgbToDbz(187, 187, 255), isNull);
      expect(RadarPalette.rgbToDbz(154, 187, 255), isNull);
      expect(RadarPalette.rgbToDbz(154, 154, 187), isNull);
      expect(RadarPalette.rgbToDbz(187, 187, 221), isNull);
      // 纯灰（地形晕渲 / 城市标注边缘）
      expect(RadarPalette.rgbToDbz(173, 173, 173), isNull);
      expect(RadarPalette.rgbToDbz(120, 120, 120), isNull);
    });

    test('色标本色仍须正确识别（不得误杀真实回波）', () {
      expect(RadarPalette.rgbToDbz(65, 157, 241), 5); // 浅蓝
      expect(RadarPalette.rgbToDbz(109, 250, 61), 15); // 亮绿
      expect(RadarPalette.rgbToDbz(0, 216, 0), 20); // 绿
      expect(RadarPalette.rgbToDbz(255, 255, 0), 30); // 黄
      expect(RadarPalette.rgbToDbz(255, 0, 0), 45); // 红
      expect(RadarPalette.rgbToDbz(255, 0, 240), 60); // 品红
      expect(RadarPalette.rgbToDbz(173, 144, 240), 65); // 紫
    });

    test('背景色仍被排除', () {
      expect(RadarPalette.rgbToDbz(179, 230, 255), isNull); // 海洋浅蓝
      expect(RadarPalette.rgbToDbz(255, 255, 255), isNull);
      expect(RadarPalette.rgbToDbz(236, 251, 236), isNull); // 浅绿陆地
      expect(RadarPalette.rgbToDbz(0, 0, 0), isNull);
    });

    test('阈值常量（收紧的量化依据）', () {
      expect(RadarPalette.maxColorDistance, 60);
      expect(RadarPalette.minSaturation, 80);
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
