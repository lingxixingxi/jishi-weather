import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 卫星云图的经纬度标定（风云四号 FY-4B · ACHN 中国区域）
///
/// 参数由图上地理特征反演（官方未直接公开该 JPG 产品的角点）：
/// · 渤海湾（约 120°E, 39°N）落在 x≈640, y≈190
/// · 印度半岛南端（约 77°E, 8°N）落在 x≈250, y≈480
/// 反解得：
///   经度 49.4 ~ 144.4（跨度 95°）→ kLon = 95/860 ≈ 0.1105 °/px
///   纬度  1.6 ~  59.3（跨度 57.7°）→ kLat = 57.7/540 ≈ 0.1069 °/px
///
/// ⚠️ 该产品分辨率约 **11 km/px**（远粗于雷达的 2.6 km/px），
/// 因此**只适合中小比例尺**看整体云系，放大后会明显模糊。
class SatelliteGeo {
  static const double lonMin = 49.4;
  static const double lonMax = 144.4;
  static const double latMin = 1.6;
  static const double latMax = 59.3;

  /// 参考图宽度（medium 尺寸）
  static const int refWidth = 860;

  /// 参考图高度（medium 尺寸）
  static const int refHeight = 540;

  SatelliteGeo._();

  static double get kLon => (lonMax - lonMin) / refWidth;
  static double get kLat => (latMax - latMin) / refHeight;

  /// 像素 → 经纬度
  static ({double lat, double lon}) pixelToLatLon(double x, double y) => (
        lat: latMax - y * kLat,
        lon: lonMin + x * kLon,
      );

  /// 经纬度 → 像素
  static ({double x, double y}) latLonToPixel(double lat, double lon) => (
        x: (lon - lonMin) / kLon,
        y: (latMax - lat) / kLat,
      );

  /// 是否在覆盖范围内
  static bool covers(double lat, double lon) =>
      lat >= latMin && lat <= latMax && lon >= lonMin && lon <= lonMax;
}

/// 卫星云图服务（中央气象台 / 国家卫星气象中心 FY-4B 真彩色）
///
/// 与雷达拼图**互补**：雷达只有降水回波，云系要靠卫星云图。
/// · 域名：`image.nmc.cn`（与雷达的 www.nmc.cn 不同）
/// · 路径：`/product/{Y}/{M}/{D}/WXBL/{size}/SEVP_NSMC_WXBL_FY4B_ETCC_ACHN_LNO_PY_{ts}.JPG`
/// · 尺寸：`medium` = 860×540（172KB）、`small` = 500×314
/// · 间隔：**30 分钟**
class SatelliteService {
  /// 从卫星云图页面抓到的产品路径模板（不含时间戳与域名）
  static const String _pathTemplate = '/product/{y}/{m}/{d}/WXBL/medium/'
      'SEVP_NSMC_WXBL_FY4B_ETCC_ACHN_LNO_PY_{ts}.JPG';

  static const String _host = 'http://image.nmc.cn';

  final http.Client _client;
  SatelliteService({http.Client? client}) : _client = client ?? http.Client();

  /// 构造最近一帧的卫星云图 URL
  ///
  /// 产品按 30 分钟更新（00/30 分），所以时间向下取整到最近半小时。
  static String urlFor(DateTime t, {String size = 'medium'}) {
    final minute = t.minute < 30 ? 0 : 30;
    final stamp = '${t.year}${_p(t.month)}${_p(t.day)}${_p(t.hour)}${_p(minute)}00000';
    final path = _pathTemplate
        .replaceAll('{y}', '${t.year}')
        .replaceAll('{m}', _p(t.month))
        .replaceAll('{d}', _p(t.day))
        .replaceAll('{ts}', stamp)
        .replaceAll('/medium/', '/$size/');
    return '$_host$path';
  }

  static String _p(int v) => v.toString().padLeft(2, '0');

  /// 从卫星云图**页面**抓取最新的可用帧
  ///
  /// ⚠️ 不能按当前时间推算帧号！实测产品生成有延迟
  /// （某天页面最新帧只到 10:00，而当前时间是 18:45），
  /// 按时间推算会一路 404。页面上的帧列表才是权威来源。
  Future<({DateTime time, String url})?> latestFromPage() async {
    // 可见光页面的 HTML 里直接带图片路径（红外页是 SPA 空壳，抓不到）
    const page = 'http://www.nmc.cn/publish/satellite/fy4b-visible.htm';
    try {
      final resp = await _client.get(
        Uri.parse(page),
        headers: {'User-Agent': 'Mozilla/5.0', 'Referer': 'http://www.nmc.cn/'},
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final html = utf8.decode(resp.bodyBytes, allowMalformed: true);

      final re = RegExp(r'//image\.nmc\.cn(/product/[\w/\.\-]*WXBL[\w/\.\-]*\.JPG)');
      String? bestPath;
      DateTime? bestTime;
      for (final m in re.allMatches(html)) {
        final path = m.group(1)!;
        final ts = RegExp(r'PY_(\d{14})').firstMatch(path)?.group(1);
        if (ts == null || ts.length < 14) continue;
        final t = DateTime(
          int.parse(ts.substring(0, 4)),
          int.parse(ts.substring(4, 6)),
          int.parse(ts.substring(6, 8)),
          int.parse(ts.substring(8, 10)),
          int.parse(ts.substring(10, 12)),
          int.parse(ts.substring(12, 14)),
        );
        if (bestTime == null || t.isAfter(bestTime)) {
          bestTime = t;
          bestPath = path;
        }
      }
      if (bestPath == null || bestTime == null) {
        debugPrint('[卫星云图] 页面未解析到帧');
        return null;
      }
      debugPrint('[卫星云图] 页面最新帧: $bestTime');
      return (time: bestTime, url: '$_host$bestPath');
    } catch (e) {
      debugPrint('[卫星云图] 抓页面失败: $e');
      return null;
    }
  }

  /// 拉取最近一帧
  ///
  /// 优先**从页面抓最新帧**（权威）；失败时退回按当前时间推算。
  Future<({DateTime time, Uint8List bytes})?> fetchLatest({int maxBack = 4}) async {
    // ① 先试页面（拿到的一定是存在的帧）
    final fromPage = await latestFromPage();
    if (fromPage != null) {
      final got = await _download(fromPage.url);
      if (got != null) return (time: fromPage.time, bytes: got);
    }

    // ② 退回：按当前时间向前回退尝试
    final now = DateTime.now().toUtc().add(const Duration(hours: 8)); // 北京时间
    for (var i = 0; i < maxBack; i++) {
      final t = now.subtract(Duration(minutes: 30 * i));
      final url = urlFor(t);
      final got = await _download(url);
      if (got != null) return (time: t, bytes: got);
    }
    return null;
  }

  Future<Uint8List?> _download(String url) async {
    try {
      final resp = await _client.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Mozilla/5.0', 'Referer': 'http://www.nmc.cn/'},
      ).timeout(const Duration(seconds: 25));
      debugPrint('[卫星云图] GET -> HTTP ${resp.statusCode} ${resp.bodyBytes.length}B');
      if (resp.statusCode == 200 && resp.bodyBytes.length > 20000) {
        return resp.bodyBytes;
      }
    } catch (e) {
      debugPrint('[卫星云图] GET 异常: $e');
    }
    return null;
  }

  /// 裁剪为可叠加的地图区域
  ///
  /// 卫星云图本身没有标题栏，直接使用整图；这里只做尺寸规整
  /// （保证与 [SatelliteGeo] 的参考尺寸一致，避免比例错位）。
  static Future<Uint8List?> normalize(Uint8List jpgBytes) async {
    final codec = await ui.instantiateImageCodec(jpgBytes);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    if (src.width == SatelliteGeo.refWidth && src.height == SatelliteGeo.refHeight) {
      return jpgBytes;
    }
    final bd = await src.toByteData(format: ui.ImageByteFormat.png);
    return bd?.buffer.asUint8List();
  }

  void dispose() => _client.close();
}
