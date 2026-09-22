/// **真实网络**验证：雷达选源（单站优先 / 查过过期才回退拼图）
///
/// 这个测试会真的去请求 `image.nmc.cn`，用于验证本轮重构的核心规则在
/// 现实数据下确实生效 —— 而不是只在单元测试里成立。
///
/// 默认 **skip**（避免污染常规 `flutter test`），需要时显式开启：
/// ```powershell
/// $env:LIVE_RADAR=1; flutter test test/radar_live_probe_test.dart
/// ```
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jishiweather/engine/radar_verdict.dart';
import 'package:jishiweather/services/amap_service.dart';
import 'package:jishiweather/services/multi_source_service.dart';
import 'package:jishiweather/services/nmc_city_repository.dart';
import 'package:jishiweather/services/nmc_service.dart';
import 'package:jishiweather/services/open_meteo.dart';
import 'package:jishiweather/services/radar_service.dart';
import 'package:jishiweather/services/radar_source.dart';

/// 是否跑真实网络用例
final bool _live = Platform.environment['LIVE_RADAR'] == '1';
final Object? _skip = _live ? null : '需要 LIVE_RADAR=1（真实网络，请求 image.nmc.cn）';

void main() {
  test('南京（AZ9250 覆盖内）→ 单站新鲜就用单站，否则回退拼图并带上「单站上次更新时间」',
      () async {
    final s = await RadarSourcePicker.pick(lat: 32.06, lon: 118.80, count: 1);

    // ignore: avoid_print
    print('[LIVE] 南京 → fromStation=${s.fromStation}\n'
        '       标签=${s.label}\n'
        '       帧数=${s.frames.length}\n'
        '       最近站=${s.station?.name}(${s.station?.code}) '
        '${s.stationDistanceKm?.toStringAsFixed(0)} km\n'
        '       单站上次更新=${s.stationLastTime}\n'
        '       投影=${s.projection.runtimeType} '
        '${s.projection.kmPerPixel} km/px\n'
        '       地图区=${s.projection.mapWidthPx}×${s.projection.mapHeightPx}');

    if (s.fromStation) {
      // 走单站分支：必须是新鲜的，且精度应约 0.68 km/px
      final age = DateTime.now().difference(s.frames.last.time).inMinutes;
      expect(age, lessThanOrEqualTo(RadarService.stationFreshMinutes),
          reason: '选了单站就说明它在新鲜窗口内');
      expect(s.projection.kmPerPixel, lessThan(1.0));
      // ignore: avoid_print
      print('[LIVE] ✓ 命中单站分支（${age} 分钟前，'
          '${s.projection.kmPerPixel} km/px ≈ 拼图的 '
          '${(2.6 / s.projection.kmPerPixel).toStringAsFixed(1)} 倍精度）');
    } else {
      // 回退拼图分支：必须能取到帧，且投影是拼图
      expect(s.frames.isNotEmpty, isTrue, reason: '拼图兜底应能取到帧');
      expect(s.projection.kmPerPixel, greaterThan(2.0));
      // ignore: avoid_print
      print('[LIVE] ✓ 命中拼图兜底分支（单站上次更新 ${s.stationLastTime}）');
    }
  }, timeout: const Timeout(Duration(minutes: 5)), skip: _skip);

  test('上海（AECN 拼图区域）→ 同样遵守「单站优先、过期回退」', () async {
    final s = await RadarSourcePicker.pick(lat: 31.23, lon: 121.47, count: 1);
    // ignore: avoid_print
    print('[LIVE] 上海 → fromStation=${s.fromStation} | ${s.label} | '
        '帧数=${s.frames.length} | 最近站=${s.station?.name} | '
        '单站上次更新=${s.stationLastTime} | ${s.projection.kmPerPixel} km/px');
    expect(s.frames.isNotEmpty, isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)), skip: _skip);

  test('拼图覆盖判定：上海在内；海外（纽博格林）即使取到拼图帧也不覆盖该点', () async {
    final s = await RadarSourcePicker.pick(lat: 50.3356, lon: 6.9475, count: 1);
    // ignore: avoid_print
    print('[LIVE] 纽博格林 → fromStation=${s.fromStation} | ${s.label} | '
        'covers=${s.projection.covers(50.3356, 6.9475)}');
    expect(s.fromStation, isFalse, reason: '海外无单站覆盖');
    expect(s.projection.covers(50.3356, 6.9475), isFalse,
        reason: '海外不在中国雷达覆盖内 —— 页面必须据此降级，而不是显示「无回波」');
  }, timeout: const Timeout(Duration(minutes: 5)), skip: _skip);

  test('单站图**真实解码**：回波坐标必须落在 765px 地图区内（右侧面板色标不得混入）',
      () async {
    final s = await RadarSourcePicker.pick(lat: 31.23, lon: 121.47, count: 1);
    if (!s.fromStation) {
      // ignore: avoid_print
      print('[LIVE] 上海单站当前不新鲜 → 跳过解码断言（兜底分支本已生效）');
      return;
    }
    final raw = s.frames.last;
    final f = await RadarService.analyze(raw.bytes, raw.time,
        projection: s.projection);
    expect(f, isNotNull);

    final maxX = f!.echoes.map((e) => e.x).reduce((a, b) => a > b ? a : b);
    // ignore: avoid_print
    print('[LIVE] 单站图 ${f.width}×${f.height} → 回波 ${f.echoes.length} 个，'
        '最大 x=$maxX，最强 ${f.maxDbz} dBZ，覆盖 ${f.coverage.toStringAsFixed(2)}%');
    expect(maxX, lessThan(765),
        reason: '右侧信息面板里的 dBZ 色标条与回波同色，绝不能并入回波统计');
    expect(f.maxDbz, lessThan(70));
  }, timeout: const Timeout(Duration(minutes: 5)), skip: _skip);

  test('完整链路 judge()：选源 → 解码 → 取样 → 结论', () async {
    final v = await RadarVerdictEngine.judge(
      lat: 31.23,
      lon: 121.47,
      models: const [],
      radarPath: null,
    );
    final r = v.radar;
    // ignore: avoid_print
    print('[LIVE] judge() → ${v.summary}\n'
        '       fromStation=${v.fromStation} | 依据=${v.scoreBasis}');
    if (r != null) {
      // ignore: avoid_print
      print('[LIVE] 回波=${r.dbzNow} dBZ（${r.echoText}）| 帧数=${r.framesUsed} | '
          '覆盖=${r.coverage.toStringAsFixed(1)}% | 最强=${r.maxDbz} dBZ | '
          '外推 ${r.leadMinutes} 分钟后=${r.forecastText} | '
          '源=${r.sourceLabel} | ${r.kmPerPixel} km/px');
    }
    expect(v.summary, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)), skip: _skip);

  test('海外赛道（纽博格林）多源取数：Open-Meteo 可用、央台自动跳过', () async {
    final meteo = OpenMeteoService();
    final nmc = NmcService();
    final amap = AmapService();
    final cityRepo = NmcCityRepository(nmc, amap);
    final multi = MultiSourceService(meteo: meteo, nmc: nmc, cityRepo: cityRepo);
    try {
      final list = await multi.fetch(
        lat: 50.3356,
        lon: 6.9475,
        place: '纽博格林北环赛道',
        forecastDays: 2,
      );
      expect(list, isNotEmpty, reason: 'Open-Meteo 全球覆盖，必须能取到数据');
      final m = list.first;
      final names = m.sources.map((s) => s.displayName).toList();
      // ignore: avoid_print
      print('[LIVE] 纽博格林 → ${list.length} 个时刻 | ${names.length} 源：'
          '${names.join(" / ")}');
      // ignore: avoid_print
      print('[LIVE] 首时刻 ${m.time} | 首源气温=${m.sources.first.temperature}°C '
          '降水=${m.sources.first.precipitation}mm');
      expect(m.sources.length, greaterThanOrEqualTo(3),
          reason: '至少应含 Open-Meteo 三模型');
      expect(names.contains('中央气象台'), isFalse,
          reason: '中央气象台仅覆盖中国，海外应由 try/catch 自动跳过');
    } finally {
      meteo.dispose();
      nmc.dispose();
      amap.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)), skip: _skip);
}
