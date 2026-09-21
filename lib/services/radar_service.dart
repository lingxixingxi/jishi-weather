import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../engine/weather_estimator.dart';

/// 雷达拼图的 dBZ 色标（从中央气象台华东雷达拼图**实测提取**）
///
/// 色带位于图片底部 y≈1251~1263，每段约 45.6px，
/// 起点 x=33 对应 5 dBZ，公式 `dBZ = 5 + (x-33)/45.6*5`。
/// 颜色定义对应中央气象台 [组合反射率] 标准色标。
class RadarPalette {
  RadarPalette._();

  static const List<({int dbz, int r, int g, int b})> entries = [
    (dbz: 5, r: 65, g: 157, b: 241), // 浅蓝
    (dbz: 10, r: 100, g: 231, b: 235), // 青
    (dbz: 15, r: 109, g: 250, b: 61), // 亮绿
    (dbz: 20, r: 0, g: 216, b: 0), // 绿
    (dbz: 25, r: 1, g: 144, b: 0), // 深绿
    (dbz: 30, r: 255, g: 255, b: 0), // 黄
    (dbz: 35, r: 231, g: 192, b: 0), // 金黄
    (dbz: 40, r: 255, g: 144, b: 0), // 橙
    (dbz: 45, r: 255, g: 0, b: 0), // 红
    (dbz: 50, r: 214, g: 0, b: 0), // 深红
    (dbz: 55, r: 192, g: 0, b: 0), // 暗红
    (dbz: 60, r: 255, g: 0, b: 240), // 品红
    (dbz: 65, r: 173, g: 144, b: 240), // 紫
  ];

  /// 背景色（海洋/陆地/边界），这些不算回波
  static const List<({int r, int g, int b})> backgrounds = [
    (r: 179, g: 230, b: 255), // 海洋浅蓝
    (r: 255, g: 255, b: 255), // 白
    (r: 236, g: 251, b: 236), // 浅绿陆地
    (r: 240, g: 255, b: 240),
    (r: 0, g: 0, b: 0), // 边界/文字
    (r: 115, g: 115, b: 115),
    (r: 102, g: 102, b: 102),
    (r: 204, g: 204, b: 204),
  ];

  /// RGB → dBZ（容差匹配，找不到回波返回 null）
  ///
  /// 雷达图经缩放/压缩后颜色会有偏移，所以用最近邻 + 容差判断。
  static int? rgbToDbz(int r, int g, int b, {int tolerance = 32}) {
    // 先排除背景
    for (final bg in backgrounds) {
      if ((r - bg.r).abs() + (g - bg.g).abs() + (b - bg.b).abs() < tolerance) {
        return null;
      }
    }
    // 找最近色标
    int bestDbz = 0;
    var bestDist = 1 << 30;
    for (final e in entries) {
      final d = (r - e.r).abs() + (g - e.g).abs() + (b - e.b).abs();
      if (d < bestDist) {
        bestDist = d;
        bestDbz = e.dbz;
      }
    }
    if (bestDist > tolerance * 3) return null;
    return bestDbz;
  }

  /// dBZ → 颜色（用于渲染叠加层）
  static ({int r, int g, int b})? dbzToRgb(int dbz) {
    if (dbz < entries.first.dbz) return null;
    var best = entries.first;
    for (final e in entries) {
      if (e.dbz <= dbz) best = e;
    }
    return (r: best.r, g: best.g, b: best.b);
  }

  /// dBZ 等级描述
  static String dbzLevel(int dbz) {
    if (dbz < 15) return '弱回波';
    if (dbz < 30) return '小到中雨';
    if (dbz < 40) return '中到大雨';
    if (dbz < 50) return '大到暴雨';
    return '强降水/冰雹';
  }
}

/// 雷达拼图的经纬度标定（华东区域）
///
/// 参数由**图上地理特征反演**得到（中央气象台未公开投影参数）：
/// · 经度：台湾本岛最西 120.03°E @x=470，最东 121.99°E @x=545
///   → kLon = 0.02627 °/px，lonMin(x=0) = 107.68
/// · 纬度：台湾本岛最南 21.90°N @y=1170，最北 25.30°N @y=930
///   → kLat = 0.01417 °/px，latMax(y=0) = 38.48
///
/// ✅ 交叉验证：台北市 (121.57°E, 25.03°N) → 图上 (529, 949)，
///    与图中「台北」标注圆点 (528, 948) 吻合。
///
/// ⚠️ 注意 x / y 方向的 °/px 不同，说明该拼图的经纬度比例并非 1:1，
///    因此**不能**用单一比例换算。
///
/// **参数校准（2026-09-21，自动拟合）**：
/// 该拼图自带地理底图（省界/海岸线/城市标注），于是用 cv2 检测出图上
/// 每个城市标注旁的小圆点，与 70 个已知城市经纬度做迭代最小二乘拟合
/// （残差中位 13.7px，全图 774×1326）。
///
/// 旧值 kLon=0.02627 / lonMin=107.68 是把经度跨度估计得过大，
/// 导致叠加层整体向右上方偏移 —— 这正是「大丰区跑到海上、叠加图与底图对不上」的原因。
class RadarGeo {
  /// 经度：每像素度数
  static const double kLon = 0.019867;

  /// 经度起点（x=0）
  static const double lonMin = 111.710;

  /// 纬度：每像素度数
  static const double kLat = 0.016279;

  /// 纬度起点（y=0）
  static const double latMax = 39.205;

  /// 地图区占整图的高度比例
  ///
  /// **实测校准（2026-09-21，774×1326 原图）**：底部图例（产品标题 + dBZ 色标 +
  /// 审图号）的**色带从 y≈1251 开始**，即约 5.7%。
  ///
  /// 取 0.942（= y 1250）而不是 0.95：色标的颜色和回波色完全一样，
  /// 若只裁到 y=1259 会留下一条彩色色带，被回波提取判为回波留在图上
  /// （实测在「泰国」上方出现一条彩色横条）。多裁几像素把它切干净。
  static const double mapHeightRatio = 0.942;

  RadarGeo._();

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

  /// 该坐标是否落在雷达图覆盖范围内
  static bool covers(double lat, double lon, {int width = 774, int height = 1326}) {
    final p = latLonToPixel(lat, lon);
    return p.x >= 0 && p.x < width && p.y >= 0 && p.y < height * mapHeightRatio;
  }
}

/// 单帧雷达分析结果
class RadarFrame {
  final DateTime time;
  final int width;
  final int height;

  /// 回波格点（稀疏：只存有回波的）
  final List<({int x, int y, int dbz})> echoes;

  /// 回波质心（像素坐标）
  final double? centroidX;
  final double? centroidY;

  /// 回波覆盖率（%）
  final double coverage;

  /// 最大 dBZ
  final int maxDbz;

  /// 平均 dBZ（仅回波区）
  final double avgDbz;

  const RadarFrame({
    required this.time,
    required this.width,
    required this.height,
    required this.echoes,
    this.centroidX,
    this.centroidY,
    this.coverage = 0,
    this.maxDbz = 0,
    this.avgDbz = 0,
  });

  bool get hasEcho => echoes.isNotEmpty;
}

/// 回波运动矢量（像素/帧 → 可换算为 km/h）
class RadarMotion {
  final double dxPerFrame; // 像素/帧
  final double dyPerFrame;
  final int frameMinutes; // 每帧间隔（分钟）
  final double kmPerPixel; // 图像比例（km/像素）

  const RadarMotion({
    required this.dxPerFrame,
    required this.dyPerFrame,
    this.frameMinutes = 6,
    this.kmPerPixel = 2.0,
  });

  /// 移动速度（km/h）
  double get speedKmh {
    final distPx = math.sqrt(dxPerFrame * dxPerFrame + dyPerFrame * dyPerFrame);
    final distKm = distPx * kmPerPixel;
    return distKm / (frameMinutes / 60.0);
  }

  /// 移动方向（度，气象习惯：风的来向，0=北 顺时针）
  double get directionDeg {
    // 图像 y 向下，转成地理：上=北
    final geoDx = dxPerFrame;
    final geoDy = -dyPerFrame;
    var deg = math.atan2(geoDx, geoDy) * 180 / math.pi; // 从北顺时针
    if (deg < 0) deg += 360;
    // 这是「去向」，气象用「来向」→ +180
    return (deg + 180) % 360;
  }

  /// 方位文字
  String get directionText {
    const names = ['北', '东北', '东', '东南', '南', '西南', '西', '西北'];
    final idx = (((directionDeg + 22.5) % 360) / 45).floor() % 8;
    return names[idx];
  }
}

/// 雷达图像分析与回波外推服务
///
/// 中央气象台只提供**栅格拼图 PNG**（无原始 dBZ 数据），
/// 所以这里走「图像级」分析路线：
///   1. 按色标把像素反演为 dBZ
///   2. 提取回波区、算质心与强度分布
///   3. 多帧质心追踪 → 简易光流（运动矢量）
///   4. 按运动矢量外推 → 判断某点未来是否有降水
///
/// 参考：Z-R 关系 Marshall-Palmer(1948) 在 [WeatherEstimator] 中实现。
class RadarService {
  RadarService._();

  /// 解码 PNG 并分析回波
  ///
  /// [sampleStep] 采样步长（1=全像素，2=隔一个取一个，用于提速）
  static Future<RadarFrame?> analyze(
    Uint8List pngBytes,
    DateTime time, {
    int sampleStep = 2,
    int minDbz = 5,
  }) async {
    // 解码
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frameInfo = await codec.getNextFrame();
    final image = frameInfo.image;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;

    final w = image.width;
    final h = image.height;
    final pixels = byteData.buffer.asUint8List();

    // 只分析地图区域（去掉底部色标与标题：下 12% 不分析）
    final mapBottom = (h * 0.88).round();

    final echoes = <({int x, int y, int dbz})>[];
    var sumX = 0.0, sumY = 0.0, sumDbz = 0.0;
    var maxDbz = 0;

    for (var y = 0; y < mapBottom; y += sampleStep) {
      for (var x = 0; x < w; x += sampleStep) {
        final i = (y * w + x) * 4;
        final r = pixels[i];
        final g = pixels[i + 1];
        final b = pixels[i + 2];
        final a = pixels[i + 3];
        if (a < 128) continue;
        final dbz = RadarPalette.rgbToDbz(r, g, b);
        if (dbz == null || dbz < minDbz) continue;
        echoes.add((x: x, y: y, dbz: dbz));
        sumX += x;
        sumY += y;
        sumDbz += dbz;
        if (dbz > maxDbz) maxDbz = dbz;
      }
    }

    final total = (mapBottom / sampleStep).round() * (w / sampleStep).round();
    return RadarFrame(
      time: time,
      width: w,
      height: h,
      echoes: echoes,
      centroidX: echoes.isEmpty ? null : sumX / echoes.length,
      centroidY: echoes.isEmpty ? null : sumY / echoes.length,
      coverage: total == 0 ? 0 : echoes.length * 100.0 / total,
      maxDbz: maxDbz,
      avgDbz: echoes.isEmpty ? 0 : sumDbz / echoes.length,
    );
  }

  /// 由多帧质心位移估算回波运动矢量（简易光流）
  ///
  /// 帧按时间**正序**传入（旧 → 新）。
  static RadarMotion? estimateMotion(
    List<RadarFrame> frames, {
    double kmPerPixel = 2.0,
  }) {
    final valid = frames.where((f) => f.hasEcho && f.centroidX != null).toList();
    if (valid.length < 2) return null;

    final first = valid.first;
    final last = valid.last;
    final dtMin = last.time.difference(first.time).inMinutes;
    if (dtMin <= 0) return null;

    // 总位移 / 帧数
    final totalDx = last.centroidX! - first.centroidX!;
    final totalDy = last.centroidY! - first.centroidY!;
    final frameCount = valid.length - 1;

    return RadarMotion(
      dxPerFrame: totalDx / frameCount,
      dyPerFrame: totalDy / frameCount,
      frameMinutes: dtMin ~/ frameCount,
      kmPerPixel: kmPerPixel,
    );
  }

  /// **目标点回波外推预测** —— 预测 [minutesAhead] 分钟后该点的回波强度
  ///
  /// ⚠️ 与 [predictCentroid] 的区别（那个只跟踪回波块的中心，用处有限）：
  /// 降水预报真正关心的是「**目标点上方未来会不会有回波飘过来**」。
  ///
  /// 做法（避免重建整张图）：回波以速度 v 平移，则
  ///   目标点 T 在 t 分钟后的回波 ≡ 当前位置 **(T − v·t)** 处的当前回波
  /// 即把目标点沿运动方向**反向平移**后，查当前回波场即可。
  ///
  /// 适用尺度：雷达外推在 **0~2 小时**内显著优于数值模式（短临预报），
  /// 超过 2~3 小时后外推误差迅速增大，应由模式接管。
  static int? forecastDbzAt(
    RadarFrame latest,
    RadarMotion motion,
    double lat,
    double lon,
    int minutesAhead, {
    int radiusPx = 1,
  }) {
    final p = RadarGeo.latLonToPixel(lat, lon);
    final steps = minutesAhead / motion.frameMinutes;
    final srcX = p.x - motion.dxPerFrame * steps;
    final srcY = p.y - motion.dyPerFrame * steps;

    int? best;
    var bestDist = double.infinity;
    for (final e in latest.echoes) {
      final dx = (e.x - srcX).abs();
      final dy = (e.y - srcY).abs();
      if (dx > radiusPx || dy > radiusPx) continue;
      final d = dx + dy;
      if (d < bestDist) {
        bestDist = d;
        best = e.dbz;
      }
    }
    return best;
  }

  /// 回波外推预测的**有效时限**（分钟）
  ///
  /// 实测经验：30~60 分钟外推可信度高；2 小时以上误差明显增大。
  static const int forecastMaxMinutes = 120;

  /// 雷达拼图的**产品生成延迟**（分钟）
  ///
  /// 拼图每 6 分钟一张，但从观测到出图有几分钟滞后。取帧时以
  /// 「当前时间 − 该延迟」再对齐到 6 分钟网格作为起点，避免总是先撞 404。
  static const int radarGenerationLagMinutes = 6;

  /// 雷达拼图的标称时间间隔（分钟）
  static const int radarFrameMinutes = 6;

  /// 按运动矢量外推：预测 [minutesAhead] 分钟后回波质心位置
  static ({double x, double y})? predictCentroid(
    RadarFrame last,
    RadarMotion motion,
    int minutesAhead,
  ) {
    if (last.centroidX == null || last.centroidY == null) return null;
    final steps = minutesAhead / motion.frameMinutes;
    return (
      x: last.centroidX! + motion.dxPerFrame * steps,
      y: last.centroidY! + motion.dyPerFrame * steps,
    );
  }

  /// 拉取最近 N 帧雷达图（间隔 6 分钟，按时间正序返回）
  ///
  /// [radarPath] 来自 `NmcService.weather()` 的 `radarImagePath`，
  /// 形如 `/product/2026/09/19/RDCP/SEVP_..._PI_20260919073600000.PNG`。
  /// **这里只用它取「文件名模板」**（产品名与区域码），时间戳一律按当前时间重算。
  ///
  /// ⚠️ **为什么不能用 radarPath 里的时间戳**（这是个实际踩过的坑）：
  /// 那个 path 是上一次调央台接口时拿到的。若 App 在后台挂了几小时，
  /// 缓存的 path 就指向几小时前的时刻 —— 而央台会清理过期产品，
  /// 于是构造出的 URL 全部 404，表现为**「雷达图获取不到」**，
  /// 重启 App 重新拉接口后才恢复。
  static Future<List<({DateTime time, Uint8List bytes})>> fetchRecentFrames({
    required String radarPath,
    int count = 3,
    http.Client? client,
    DateTime? now,
  }) async {
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final fileName = radarPath.split('/').last;
      final piIdx = fileName.indexOf('PI_');
      if (piIdx < 0) return const [];
      final namePrefix = fileName.substring(0, piIdx);

      // ⚠️ 文件名里的时间戳是 **UTC**，不是北京时间！
      // 实测：央台页面显示「制作时间 09/21 20:36」，而该帧的文件名是
      // `..._PI_20260921123600000.PNG` —— 正好差 8 小时。
      // 用本地时间去拼会一直去查 8 小时后的未来文件，全部 404。
      final base = (now ?? DateTime.now()).toUtc();
      var t = DateTime.utc(base.year, base.month, base.day, base.hour, base.minute)
          .subtract(const Duration(minutes: radarGenerationLagMinutes));
      t = DateTime.utc(t.year, t.month, t.day, t.hour,
          (t.minute ~/ radarFrameMinutes) * radarFrameMinutes);

      final out = <({DateTime time, Uint8List bytes})>[];
      var attempts = 0;
      final maxAttempts = count + 6; // 允许最新几帧尚未生成完
      while (out.length < count && attempts < maxAttempts) {
        // ⚠️ 时间戳是 17 位：`YYYYMMDDHHMM` + `00000`
        // （例：2026-09-21 20:48 北京 → `20260921124800000`）
        // 少写尾部 3 个 0 会全部 404 —— 这是实际踩过的坑。
        final stamp = '${t.year}${_p2(t.month)}${_p2(t.day)}'
            '${_p2(t.hour)}${_p2(t.minute)}00000';
        final url = '/product/${t.year}/${_p2(t.month)}/${_p2(t.day)}/RDCP/'
            '${namePrefix}PI_$stamp.PNG';
        try {
          final resp = await c
              .get(Uri.parse('https://image.nmc.cn$url'), headers: {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 13)',
            'Referer': 'http://www.nmc.cn/',
          })
              .timeout(const Duration(seconds: 20));
          if (resp.statusCode == 200 && resp.bodyBytes.length > 10000) {
            // 对外仍按北京时间上报，避免后续时刻显示差 8 小时
            out.add((time: t.toLocal(), bytes: resp.bodyBytes));
          }
        } catch (_) {
          // 单帧失败跳过，继续往前找
        }
        t = t.subtract(const Duration(minutes: radarFrameMinutes));
        attempts++;
      }
      out.sort((a, b) => a.time.compareTo(b.time));
      debugPrint('[雷达] 取帧 ${out.length}/$count'
          '（模板 ${namePrefix}PI_*.PNG，最新帧 ${out.isEmpty ? "无" : out.last.time}）');
      return out;
    } finally {
      if (own) c.close();
    }
  }

  static String _p2(int v) => v.toString().padLeft(2, '0');

  /// 裁掉底部图例，并**把非回波像素设为透明**（只留回波）
  ///
  /// 两件事：
  /// 1. 中央气象台拼图底部约 5% 是「产品标题 / dBZ 色标 / 审图号」，直接叠加很难看；
  /// 2. ⚠️ **该拼图是自带地理底图的成品图**（省界、海岸线、城市名、海洋底色）。
  ///    直接贴到高德地图上会形成「双重地图」—— 两张地图的城市标注位置不一致，
  ///    看起来就是「叠加图和正式地图对不上」。所以这里按 dBZ 色标逐像素过滤，
  ///    **只保留回波色、其余全部透明**，顺带把颜色标准化成色标原色。
  static Future<Uint8List?> cropToMapArea(Uint8List pngBytes) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    final newH = (src.height * RadarGeo.mapHeightRatio).round();

    final bd = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return null;
    final px = bd.buffer.asUint8List();

    final stride = src.width * 4;
    final cropped = Uint8List(stride * newH);
    cropped.setRange(0, stride * newH, px);

    // ---- 只留回波：非回波像素透明化，回波像素标准化为色标原色 ----
    var echoes = 0;
    for (var i = 0; i < cropped.length; i += 4) {
      final dbz = RadarPalette.rgbToDbz(cropped[i], cropped[i + 1], cropped[i + 2]);
      if (dbz == null) {
        cropped[i + 3] = 0;
        continue;
      }
      final c = RadarPalette.dbzToRgb(dbz);
      if (c != null) {
        cropped[i] = c.r;
        cropped[i + 1] = c.g;
        cropped[i + 2] = c.b;
      }
      cropped[i + 3] = 255;
      echoes++;
    }
    debugPrint('[雷达] 回波提取：${cropped.length ~/ 4} 像素中 $echoes 个回波'
        '（${(echoes / (cropped.length / 4) * 100).toStringAsFixed(2)}%），其余已透明化');

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      cropped,
      src.width,
      newH,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final img = await completer.future;
    final out = await img.toByteData(format: ui.ImageByteFormat.png);
    return out?.buffer.asUint8List();
  }

  /// 雷达图（地图区）在地图上的覆盖范围
  ///
  /// 返回 (西南角, 东北角) 供 GroundOverlay 使用。
  static ({double swLat, double swLon, double neLat, double neLon}) overlayBounds({
    int width = 774,
    double mapHeightRatio = RadarGeo.mapHeightRatio,
    int height = 1326,
  }) {
    final sw = RadarGeo.pixelToLatLon(0, height * mapHeightRatio);
    final ne = RadarGeo.pixelToLatLon(width.toDouble(), 0);
    return (swLat: sw.lat, swLon: sw.lon, neLat: ne.lat, neLon: ne.lon);
  }

  /// 回波强度 → 降水强度（mm/h），用 Z-R 关系反演
  static double dbzToRainRate(int dbz) => WeatherEstimator.dbzToRainRate(dbz.toDouble());

  /// 查询某经纬度上的回波强度（dBZ），无回波返回 null
  ///
  /// ⚠️ 两个关键点（之前实现有误，导致误报）：
  /// 1. **半径要小**：拼图分辨率 1px ≈ 2.6km，之前默认 8px ≈ **21km**，
  ///    会把 20km 外的回波算到目标点头上 → 明明是阴天却报「中到大雨」。
  ///    现在默认 1px（≈2.6km），与数据源本身的空间精度匹配。
  /// 2. **取最近点而非最大值**：目标点是否有雨取决于**它自己**的回波，
  ///    而不是附近最强的回波。
  static int? sampleAt(
    RadarFrame frame,
    double lat,
    double lon, {
    int radiusPx = 1,
  }) {
    final p = RadarGeo.latLonToPixel(lat, lon);
    int? best;
    var bestDist = double.infinity;
    for (final e in frame.echoes) {
      final dx = (e.x - p.x).abs();
      final dy = (e.y - p.y).abs();
      if (dx > radiusPx || dy > radiusPx) continue;
      final d = dx + dy; // 曼哈顿距离即可
      if (d < bestDist) {
        bestDist = d;
        best = e.dbz;
      }
    }
    return best;
  }

  /// 目标点**及其周边**的最大回波（用于判断「附近有雨」而不是「正上方有雨」）
  ///
  /// [radiusPx] 建议不超过 3（≈8km），过大会把远处回波算进来。
  static int? maxEchoNear(
    RadarFrame frame,
    double lat,
    double lon, {
    int radiusPx = 3,
  }) {
    final p = RadarGeo.latLonToPixel(lat, lon);
    int? best;
    for (final e in frame.echoes) {
      if ((e.x - p.x).abs() <= radiusPx && (e.y - p.y).abs() <= radiusPx) {
        if (best == null || e.dbz > best) best = e.dbz;
      }
    }
    return best;
  }

  /// 查询某经纬度的降水强度（mm/h），由 dBZ 经 Z-R 关系反演
  static double? rainRateAt(RadarFrame frame, double lat, double lon, {int radiusPx = 1}) {
    final dbz = sampleAt(frame, lat, lon, radiusPx: radiusPx);
    return dbz == null ? null : dbzToRainRate(dbz);
  }

  /// 检查某区域矩形内是否有回波（用于路线覆盖性判断）
  static bool hasEchoInBounds(
    RadarFrame frame, {
    required double latMin,
    required double lonMin,
    required double latMax,
    required double lonMax,
  }) {
    final p1 = RadarGeo.latLonToPixel(latMin, lonMin);
    final p2 = RadarGeo.latLonToPixel(latMax, lonMax);
    final x0 = math.min(p1.x, p2.x), x1 = math.max(p1.x, p2.x);
    final y0 = math.min(p1.y, p2.y), y1 = math.max(p1.y, p2.y);
    for (final e in frame.echoes) {
      if (e.x >= x0 && e.x <= x1 && e.y >= y0 && e.y <= y1) return true;
    }
    return false;
  }
}
