import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'radar_projection.dart';
import 'radar_service.dart';

/// 中央气象台「单站雷达」**取图**服务
///
/// 单站雷达以某个雷达站为中心，覆盖半径 256 km，分辨率约 **0.68 km/像素**
/// （区域拼图是 2.6 km/像素，粗约 4 倍），适合回答「我脚下这一格到底有没有雨」。
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
///
/// ## 重构说明（重要）
/// 几何换算（投影、距离、覆盖判断）**已全部迁到 [StationProjection]**，
/// 本类只负责取图。取样请统一走
/// `RadarService.analyze(bytes, t, projection: StationProjection(...))`
/// + `RadarService.sampleAt(frame, lat, lon)`，
/// 这样单站与拼图共用同一套分析链路，不会出现两套坐标换算各算各的。
class NmcStationRadar {
  NmcStationRadar._();

  // ==================== 几何（转发 StationProjection）====================

  /// 地图区宽度（像素）；其右侧为信息面板
  static const int mapWidth = StationProjection.mapWidth;

  /// 官方标注的覆盖半径（km）
  static const double coverageKm = StationProjection.coverageKm;

  /// 每像素公里数（约 680 m/px）
  static const double kmPerPx = StationProjection.stationKmPerPx;

  /// 两点间距离（km，Haversine）
  static double distanceKm(double lat1, double lon1, double lat2, double lon2) =>
      StationProjection.distanceKm(lat1, lon1, lat2, lon2);

  /// 经纬度 → 单站图像素坐标（落在图外返回 null）
  static ({double x, double y})? latLonToPixel(
    double lat,
    double lon,
    double stLat,
    double stLon, {
    double mapHeight = 734,
  }) {
    final proj = StationProjection(
      stationCode: '',
      stationName: '',
      stationLat: stLat,
      stationLon: stLon,
    );
    final p = proj.latLonToPixel(lat, lon);
    if (p.x < 0 || p.x >= StationProjection.mapWidth || p.y < 0 || p.y >= mapHeight) {
      return null;
    }
    return p;
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

  // ==================== 取图 ====================

  /// 从任意一帧 URL 取「文件名模板」，形如
  /// `SEVP_AOC_RDCP_SLDAS3_ECREF_AZ9250_L88_`（不含 `PI_` 前缀）
  static String? templateFromUrl(String url) {
    final name = url.split('/').last;
    final i = name.indexOf('PI_');
    return i < 0 ? null : name.substring(0, i);
  }

  /// 抓取**最近 N 帧**单站雷达图（按时间正序返回，旧 → 新）
  ///
  /// 多个帧用于回波运动矢量的质心追踪（单帧无法估算移动方向）。
  ///
  /// ⚠️ 回退帧数必须给足：**单站雷达的生成极不规律**。
  /// 实测（4 小时窗口）：
  ///   南京站  只命中 4/40 帧，且最新帧可能已是 2 小时 46 分前；
  ///   青浦站  只命中 5~6/40 帧，最新帧 58 分钟前。
  /// 各站似乎只在「自己有观测」时才出图，所以最新可用帧可能滞后 1~3 小时。
  /// 只试 10 帧（1 小时）会经常一帧都取不到 —— 这是「雷达图拉取失败」的根因。
  /// 现在默认回退 40 帧（4 小时）。
  ///
  /// 注意：即使回退到 4 小时前才凑齐帧，也不代表这些帧「新鲜」——
  /// 是否可用由调用方按 `RadarService.stationFreshMinutes` 判定
  /// （见 `RadarSourcePicker`）。
  static Future<List<RadarRawFrame>> fetchRecent({
    required String stationCode,
    int count = 3,
    int maxBackFrames = 40,
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

      final out = <RadarRawFrame>[];
      var attempts = 0;
      while (out.length < count && attempts < maxBackFrames) {
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
            out.add((time: t.toLocal(), bytes: resp.bodyBytes));
          }
        } catch (_) {
          // 该帧不可用，继续往前找
        }
        t = t.subtract(
            const Duration(minutes: RadarService.radarFrameMinutes));
        attempts++;
      }
      out.sort((a, b) => a.time.compareTo(b.time));
      debugPrint('[单站雷达] $stationCode 取到 ${out.length}/$count 帧'
          '（尝试 $attempts 帧，最新 ${out.isEmpty ? "无" : out.last.time}）');
      return out;
    } finally {
      if (own) c.close();
    }
  }

  /// 抓取**最新一帧**单站雷达图（薄封装，保留给只需单帧的场景）
  static Future<RadarRawFrame?> fetchLatest({
    required String stationCode,
    http.Client? client,
    DateTime? now,
  }) async {
    final list = await fetchRecent(
      stationCode: stationCode,
      count: 1,
      client: client,
      now: now,
    );
    return list.isEmpty ? null : list.last;
  }

  // ==================== 像素取值 ====================

  /// 解码单站图并读取目标点的 dBZ
  ///
  /// ⚠️ **保留为向后兼容的便捷方法**；新代码请用
  /// `RadarService.analyze(...)` + `RadarService.sampleAt(...)`，
  /// 以便与拼图链路共用同一套投影与取样逻辑。
  ///
  /// [radiusPx] 为取样半径：单站图约 0.68 km/像素，取 1~2px（≈1.4 km）
  /// 与数据本身的空间精度匹配。取太大（如 8px≈5km）会把旁边的雨算到头上。
  static Future<({int? dbz, double x, double y, int width, int height})?>
      sample(
    Uint8List pngBytes,
    double lat,
    double lon,
    double stLat,
    double stLon, {
    int radiusPx = 1,
  }) async {
    final proj = StationProjection(
      stationCode: '',
      stationName: '',
      stationLat: stLat,
      stationLon: stLon,
    );
    final frame = await RadarService.analyze(pngBytes, DateTime.now(),
        projection: proj, sampleStep: 1);
    if (frame == null) return null;

    final p = proj.latLonToPixel(lat, lon);
    return (
      dbz: RadarService.sampleAt(frame, lat, lon, radiusPx: radiusPx),
      x: p.x,
      y: p.y,
      width: frame.width,
      height: frame.height,
    );
  }

  static String _p2(int v) => v.toString().padLeft(2, '0');
}
