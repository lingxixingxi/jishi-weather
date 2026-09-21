import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'radar_service.dart';

/// 中央气象台「单站雷达」服务 —— 高精度数值读取
///
/// 与区域拼图（[RadarService]，覆盖华东全境、约 2.6 km/像素）不同，
/// 单站雷达**以某个雷达站为中心**，覆盖半径 256 km，分辨率约 **0.68 km/像素**
/// （精细约 4 倍），适合回答「我脚下这一格到底有没有雨」。
///
/// 页面规律：
///   https://www.nmc.cn/publish/radar/{省拼音}/{市拼音}.htm
/// 图片规律（与区域拼图同一套，只把区域码换成站点码）：
///   https://image.nmc.cn/product/{Y}/{M}/{D}/RDCP/
///       SEVP_AOC_RDCP_SLDAS3_ECREF_{站点码}_L88_PI_{UTC时间戳}.PNG
/// 例：南京站 `AZ9250`
///
/// 图上直接印着官方参数（右侧信息面板）：
///   「雷达站名：南京 / 数据范围：256 km / 观测时间：YYYY-MM-DD HH:MM:SS BJT」
/// 注意**观测时间是北京时间**，而文件名时间戳是 **UTC**（相差 8 小时）。
class NmcStationRadar {
  NmcStationRadar._();

  // ==================== 图像几何（2026-09-21 实测标定）====================
  //
  // 单站图整体 924×734，右侧约 159px 是信息面板（站名 / 数据范围 / 观测时间 /
  // dBZ 色标），左侧 [mapWidth] 宽的区域才是地图。地图以雷达站为中心，等距投影：
  //   dx_km = (lon - stLon) * 111.32 * cos(stLat)
  //   dy_km = (stLat - lat) * 110.57
  //   px = centerX + dx_km / kmPerPx
  //   py = centerY + dy_km / kmPerPx
  //
  // 三个参数由「cv2 检测图上城市标注圆点 + 70 个已知城市经纬度做迭代最小二乘」
  // 得出（残差中位约 13px）；由它反推的覆盖半径 260 km 与图上官方标注的
  // 256 km 吻合，说明投影假设成立。

  /// 地图区宽度（像素）；其右侧为信息面板
  static const int mapWidth = 765;

  /// 雷达站在地图区中的像素位置
  static const double centerX = 362.9;
  static const double centerY = 374.9;

  /// 每像素公里数（约 680 m/px）
  static const double kmPerPx = 0.67958;

  /// 官方标注的覆盖半径（km）
  static const double coverageKm = 256;

  static const double _kmPerLat = 110.57;
  static const double _kmPerLonAtEquator = 111.32;

  /// 纬度 → 单站图分辨率下的公里换算用的地球半径
  static const double _earthKm = 6371.0;

  /// 经纬度 → 单站图像素坐标
  ///
  /// [stLat] / [stLon] 为雷达站自身坐标。落在图外返回 null。
  static ({double x, double y})? latLonToPixel(
    double lat,
    double lon,
    double stLat,
    double stLon, {
    double mapHeight = 734,
  }) {
    final cosLat = math.cos(stLat * math.pi / 180).abs().clamp(0.2, 1.0);
    final dxKm = (lon - stLon) * _kmPerLonAtEquator * cosLat;
    final dyKm = (stLat - lat) * _kmPerLat;
    final x = centerX + dxKm / kmPerPx;
    final y = centerY + dyKm / kmPerPx;
    if (x < 0 || x >= mapWidth || y < 0 || y >= mapHeight) return null;
    return (x: x, y: y);
  }

  /// 该点是否落在单站图覆盖范围内
  static bool covers(
    double lat,
    double lon,
    double stLat,
    double stLon, {
    double mapHeight = 734,
  }) =>
      latLonToPixel(lat, lon, stLat, stLon, mapHeight: mapHeight) != null;

  /// 两点间距离（km，Haversine）
  static double distanceKm(double lat1, double lon1, double lat2, double lon2) {
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * _earthKm * math.asin(math.min(1.0, math.sqrt(a.toDouble())));
  }

  // ==================== 取图 ====================

  /// 从任意一帧 URL 取「文件名模板」，形如
  /// `SEVP_AOC_RDCP_SLDAS3_ECREF_AZ9250_L88_`（不含 `PI_` 前缀）
  static String? templateFromUrl(String url) {
    final name = url.split('/').last;
    final i = name.indexOf('PI_');
    return i < 0 ? null : name.substring(0, i);
  }

  /// 抓取单站雷达图（最新可用帧）
  ///
  /// 与 [RadarService.fetchRecentFrames] 同样的两个要点：
  /// · 文件名时间戳是 **UTC**，按当前 UTC 对齐到 6 分钟网格；
  /// · 从最新往旧逐帧试（产品有十几分钟延迟，且央台会很快清理过期文件）。
  /// 时间戳为 **17 位**（`YYYYMMDDHHMM` + `00000`），少写尾部 3 个 0 会全部 404。
  static Future<({DateTime time, Uint8List bytes})?> fetchLatest({
    required String stationCode,
    http.Client? client,
    DateTime? now,
  }) async {
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final template = 'SEVP_AOC_RDCP_SLDAS3_ECREF_${stationCode}_L88_';
      final base = (now ?? DateTime.now()).toUtc();
      var t =
          DateTime.utc(base.year, base.month, base.day, base.hour, base.minute)
              .subtract(const Duration(
                  minutes: RadarService.radarGenerationLagMinutes));
      t = DateTime.utc(
        t.year,
        t.month,
        t.day,
        t.hour,
        (t.minute ~/ RadarService.radarFrameMinutes) *
            RadarService.radarFrameMinutes,
      );

      for (var i = 0; i < 10; i++) {
        final stamp = '${t.year}${_p2(t.month)}${_p2(t.day)}'
            '${_p2(t.hour)}${_p2(t.minute)}00000';
        final url = 'https://image.nmc.cn/product/${t.year}/${_p2(t.month)}/'
            '${_p2(t.day)}/RDCP/$template'
            'PI_$stamp.PNG';
        try {
          final resp = await c.get(Uri.parse(url), headers: {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 13)',
            'Referer': 'https://www.nmc.cn/publish/radar/',
          }).timeout(const Duration(seconds: 20));
          if (resp.statusCode == 200 && resp.bodyBytes.length > 10000) {
            debugPrint('[单站雷达] $stationCode 取到 ${t.toLocal()} 帧 '
                '(${resp.bodyBytes.length} 字节)');
            return (time: t.toLocal(), bytes: resp.bodyBytes);
          }
        } catch (_) {
          // 该帧不可用，继续往前找
        }
        t = t.subtract(
            const Duration(minutes: RadarService.radarFrameMinutes));
      }
      debugPrint('[单站雷达] $stationCode 连续 10 帧均不可用');
      return null;
    } finally {
      if (own) c.close();
    }
  }

  // ==================== 像素取值 ====================

  /// 解码单站图并读取目标点的 dBZ
  ///
  /// [radiusPx] 为取样半径：单站图约 0.68 km/像素，取 1~2px（≈1.4 km）
  /// 与数据本身的空间精度匹配。取太大（如 8px≈5km）会把旁边的雨算到头上。
  ///
  /// 返回像素坐标（便于调试核对）与 dBZ；无回波时 [dbz] 为 null。
  static Future<({int? dbz, double x, double y, int width, int height})?>
      sample(
    Uint8List pngBytes,
    double lat,
    double lon,
    double stLat,
    double stLon, {
    int radiusPx = 1,
  }) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final w = img.width;
    final h = img.height;

    final p = latLonToPixel(lat, lon, stLat, stLon, mapHeight: h.toDouble());
    if (p == null) return null;

    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return null;
    final px = bd.buffer.asUint8List();

    var best = -1;
    for (var dy = -radiusPx; dy <= radiusPx; dy++) {
      for (var dx = -radiusPx; dx <= radiusPx; dx++) {
        final x = p.x.round() + dx;
        final y = p.y.round() + dy;
        if (x < 0 || x >= w || y < 0 || y >= h) continue;
        final i = (y * w + x) * 4;
        final dbz = RadarPalette.rgbToDbz(px[i], px[i + 1], px[i + 2]);
        if (dbz != null && dbz > best) best = dbz;
      }
    }
    return (
      dbz: best < 0 ? null : best,
      x: p.x,
      y: p.y,
      width: w,
      height: h,
    );
  }

  static String _p2(int v) => v.toString().padLeft(2, '0');
}
