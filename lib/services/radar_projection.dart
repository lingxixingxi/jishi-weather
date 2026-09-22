import 'dart:math' as math;

/// 雷达图的投影 —— 把经纬度换算成图像像素
///
/// **为什么需要这一层抽象**：
/// 中央气象台提供两类雷达产品，URL 结构完全相同，但**几何完全不同**：
///   · 区域拼图（`AECN` 等区域码）：固定经纬度范围的等经纬投影，774×1326
///   · 单站雷达（`AZ####` 站点码）：**以雷达站为中心**的等距投影，924×734
///
/// 早期实现把拼图的标定参数硬编码在取样函数里，于是单站图喂进分析链路后
/// 坐标全错，当时只能用「检测到站点码就替换成拼图」来绕开 —— 那等于主动
/// 放弃了单站图约 **4 倍**的空间精度（0.68 km/px vs 2.6 km/px）。
///
/// 现在把投影抽象出来、由 [RadarFrame] 携带，各取样函数一律走
/// `frame.projection`，两类产品即可共用同一套分析链路，也就实现了
/// 「单站当前小时有更新就用单站，查过过期才回退拼图」。
abstract class RadarProjection {
  const RadarProjection();

  /// 整图宽度（像素，**含**右侧信息面板）
  int get width;

  /// 整图高度（像素）
  int get height;

  /// 地图区宽度占整图的比例（右侧信息面板不计入）
  double get mapWidthRatio => 1.0;

  /// 地图区高度占整图的比例（底部图例 / dBZ 色标不计入）
  double get mapHeightRatio;

  /// 每像素代表多少公里（用于把回波位移换算成 km/h）
  double get kmPerPixel;

  /// 数据源标签（日志与 UI 显示，如「单站雷达 南京站」）
  String get label;

  /// 地图区像素宽度
  int get mapWidthPx => (width * mapWidthRatio).round();

  /// 地图区像素高度
  int get mapHeightPx => (height * mapHeightRatio).round();

  /// 经纬度 → 像素
  ///
  /// **允许返回图外坐标**（不在此处判空）：取样函数遍历回波时自然找不到点，
  /// 而裁剪/叠加等场景需要知道越界后的坐标值。[covers] 负责范围判断。
  ({double x, double y}) latLonToPixel(double lat, double lon);

  /// 像素 → 经纬度
  ({double lat, double lon}) pixelToLatLon(double x, double y);

  /// 该坐标是否落在地图区内
  bool covers(double lat, double lon) {
    final p = latLonToPixel(lat, lon);
    return p.x >= 0 && p.x < mapWidthPx && p.y >= 0 && p.y < mapHeightPx;
  }
}

/// 华东区域拼图投影（中央气象台区域码，如 `AECN`）
///
/// 参数由**图上地理特征反演**得到（中央气象台未公开投影参数）。
/// 该拼图自带地理底图（省界 / 海岸线 / 城市标注），因此用 cv2 检测出图上
/// 每个城市标注旁的小圆点，与 70 个已知城市经纬度做迭代最小二乘拟合，
/// 残差中位 **13.7 px**（全图 774×1326）。
///
/// ⚠️ 校准史：旧值 `kLon=0.02627 / lonMin=107.68` 是把经度跨度估计得过大
/// （当年只用台湾本岛两点估算），导致叠加层整体向右上方偏移约 52px ——
/// 这正是「大丰区跑到海上、叠加图与底图对不上」的根因。
///
/// ⚠️ x / y 方向的 °/px **不同**，说明该拼图的经纬度比例并非 1:1，
/// 因此不能用单一比例换算。
class EastChinaProjection extends RadarProjection {
  const EastChinaProjection();

  /// 经度：每像素度数
  static const double kLon = 0.019867;

  /// 经度起点（x = 0）
  static const double lonMin = 111.710;

  /// 纬度：每像素度数
  static const double kLat = 0.016279;

  /// 纬度起点（y = 0）
  static const double latMax = 39.205;

  @override
  int get width => 774;

  @override
  int get height => 1326;

  /// 地图区占整图的高度比例
  ///
  /// **实测校准（774×1326 原图）**：底部图例（产品标题 + dBZ 色标 + 审图号）
  /// 的**色带从 y≈1251 开始**，即约 5.7%。
  ///
  /// 取 0.942（= y 1250）而不是 0.95：色标的颜色与回波色完全一样，
  /// 若只裁到 y=1259 会留下一条彩色色带被回波提取判为回波
  /// （实测表现为图上「泰国」上方出现一条彩色横条）。多裁几像素切干净。
  @override
  double get mapHeightRatio => 0.942;

  @override
  double get kmPerPixel => 2.6;

  @override
  String get label => '区域拼图（华东）';

  @override
  ({double x, double y}) latLonToPixel(double lat, double lon) => (
        x: (lon - lonMin) / kLon,
        y: (latMax - lat) / kLat,
      );

  @override
  ({double lat, double lon}) pixelToLatLon(double x, double y) => (
        lat: latMax - y * kLat,
        lon: lonMin + x * kLon,
      );
}

/// 单站雷达投影（中央气象台 `AZ####` 站点码）
///
/// 单站图**以雷达站为中心**，覆盖半径 256 km，约 **0.68 km/像素**
/// （区域拼图是 2.6 km/像素，粗约 4 倍）。
///
/// ## 图像结构（实测 924×734）
/// ```text
/// ┌──────────────────────────┬──────────────┐
/// │        地图区 765 px      │ 信息面板 159 │
/// │  （自带地理底图：省界/     │ 组合反射率    │
/// │    海岸线/地形晕渲/城市）  │ 雷达站名:南京 │
/// │   中心 = 雷达站           │ 数据范围256km │
/// │                          │ dBZ 色标条 ←  │
/// └──────────────────────────┴──────────────┘
/// ```
/// ⚠️ 右侧面板里的**色标条与回波同色**，若把面板纳入回波统计会凭空多出
/// 大量 60/65 dBZ 假回波（实测含面板时 60/65 dBZ 各 260+ 像素）。
/// 因此 [mapWidthRatio] 必须限定在 765px。底部无图例（仅灰色审图号文字，
/// 不会被判为回波），故 [mapHeightRatio] 取 1.0。
///
/// ## 投影公式（等距投影）
/// ```
/// dx_km = (lon - stLon) * 111.32 * cos(stLat)
/// dy_km = (stLat - lat) * 110.57
/// px = centerX + dx_km / kmPerPixel
/// py = centerY + dy_km / kmPerPixel
/// ```
/// [centerX] / [centerY] / [kmPerPixel] 由「cv2 检测图上城市标注圆点 +
/// 70 个已知城市经纬度做迭代最小二乘」标定（残差中位约 13px）；
/// 由其反推的覆盖半径 260 km 与图上官方标注的 **256 km** 吻合，
/// 说明投影假设成立。
///
/// 图上还直接印着官方参数，可用于核对：
/// 「雷达站名：南京 / 数据范围：256 km / 观测时间：YYYY-MM-DD HH:MM:SS BJT」。
class StationProjection extends RadarProjection {
  const StationProjection({
    required this.stationCode,
    required this.stationName,
    required this.stationLat,
    required this.stationLon,
  });

  /// 站点码（如 `AZ9250`）
  final String stationCode;

  /// 站点名（如「南京」）
  final String stationName;

  /// 雷达站坐标（取 `radar_stations.dart` 中经高德 POI 实测的站址）
  final double stationLat;
  final double stationLon;

  // ==================== 图像几何常量 ====================

  /// 地图区宽度（像素）；其右侧为信息面板
  static const int mapWidth = 765;

  /// 雷达站在地图区中的像素位置
  static const double centerX = 362.9;
  static const double centerY = 374.9;

  /// 每像素公里数（约 680 m/px）
  static const double stationKmPerPx = 0.67958;

  /// 官方标注的覆盖半径（km）
  static const double coverageKm = 256;

  static const double _kmPerLat = 110.57;
  static const double _kmPerLonAtEquator = 111.32;

  @override
  int get width => 924;

  @override
  int get height => 734;

  @override
  double get mapWidthRatio => mapWidth / width;

  @override
  double get mapHeightRatio => 1.0;

  @override
  double get kmPerPixel => stationKmPerPx;

  @override
  String get label => '单站雷达 $stationName站（$stationCode）';

  /// 该站在此纬度上的经度压缩系数（等距投影用）
  double get _cosLat =>
      math.cos(stationLat * math.pi / 180).abs().clamp(0.2, 1.0);

  @override
  ({double x, double y}) latLonToPixel(double lat, double lon) {
    final dxKm = (lon - stationLon) * _kmPerLonAtEquator * _cosLat;
    final dyKm = (stationLat - lat) * _kmPerLat;
    return (
      x: centerX + dxKm / stationKmPerPx,
      y: centerY + dyKm / stationKmPerPx,
    );
  }

  @override
  ({double lat, double lon}) pixelToLatLon(double x, double y) {
    final dxKm = (x - centerX) * stationKmPerPx;
    final dyKm = (y - centerY) * stationKmPerPx;
    return (
      lat: stationLat - dyKm / _kmPerLat,
      lon: stationLon + dxKm / (_kmPerLonAtEquator * _cosLat),
    );
  }

  /// 与雷达站的距离（km，Haversine）
  static double distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const earthKm = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * earthKm * math.asin(math.min(1.0, math.sqrt(a.toDouble())));
  }
}
