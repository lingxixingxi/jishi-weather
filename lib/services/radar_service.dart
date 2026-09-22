import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../engine/weather_estimator.dart';
import 'radar_projection.dart';

/// 一帧雷达原始数据（时间 + PNG 字节）
typedef RadarRawFrame = ({DateTime time, Uint8List bytes});

/// 雷达图的 dBZ 色标（从中央气象台华东雷达拼图**实测提取**）
///
/// 色带位于图片底部 y≈1251~1263，每段约 45.6px，
/// 起点 x=33 对应 5 dBZ，公式 `dBZ = 5 + (x-33)/45.6*5`。
/// 颜色定义对应中央气象台 [组合反射率] 标准色标。
///
/// ⚠️ 单站雷达图（924×734）用的是**同一套色标**，只是位置不同
/// （印在右侧信息面板里，y≈240~590）—— 这也是必须把面板排除在
/// 回波统计之外的原因：色标色与回波色完全相同。
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
  ///
  /// 拼图底图（浅绿陆地 + 浅蓝海洋 + 白色）与单站图底图（灰白地形晕渲 +
  /// 蓝色水系 + 黑色标注）都靠这一组 + 容差判据排掉。
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

  /// 最近邻颜色距离上限
  ///
  /// ⚠️ 原实现用 `tolerance * 3 = 96`，过宽。实测单站图上一批
  /// `RGB(187,187,255)` 浅紫像素到 65 dBZ 紫色 `(173,144,240)` 的距离
  /// 只有 72，会被判成 **65 dBZ** —— 而 65 dBZ 在 [dbzLevel] 里是
  /// 「强降水/冰雹」，属严重误报（当时上海/南京并无强对流）。
  /// 收到 60 后单站图的 11 个假强回波全部消失。
  static const int maxColorDistance = 60;

  /// 饱和度门槛（`max(r,g,b) - min(r,g,b)`）
  ///
  /// 雷达色标**全部是高饱和颜色**（最低的 65 dBZ 紫色也有 96 的饱和度），
  /// 而地图底图上易被误判的像素（水系边缘、城市标注抗锯齿、灰度地形晕渲）
  /// 饱和度都很低。实测拼图/单站图加此门槛后，40 dBZ 以上的**真实强回波
  /// 计数一个没少**，只滤掉了弱回波的抗锯齿边缘。
  static const int minSaturation = 80;

  /// RGB → dBZ（容差匹配，找不到回波返回 null）
  ///
  /// 雷达图经缩放/压缩后颜色会有偏移，所以用最近邻 + 容差判断。
  ///
  /// **三道防线**（后两道为 2026-09-22 实测补上）：
  /// 1. 背景色排除（海洋浅蓝 / 白 / 浅绿陆地 / 黑灰标注）；
  /// 2. [minSaturation] 饱和度门槛；
  /// 3. [maxColorDistance] 最近邻距离上限。
  static int? rgbToDbz(int r, int g, int b, {int tolerance = 32}) {
    // ① 先排除背景
    for (final bg in backgrounds) {
      if ((r - bg.r).abs() + (g - bg.g).abs() + (b - bg.b).abs() < tolerance) {
        return null;
      }
    }
    // ② 饱和度门槛：滤掉灰 / 浅灰紫这类底图元素
    final mx = math.max(r, math.max(g, b));
    final mn = math.min(r, math.min(g, b));
    if (mx - mn < minSaturation) return null;
    // ③ 找最近色标
    int bestDbz = 0;
    var bestDist = 1 << 30;
    for (final e in entries) {
      final d = (r - e.r).abs() + (g - e.g).abs() + (b - e.b).abs();
      if (d < bestDist) {
        bestDist = d;
        bestDbz = e.dbz;
      }
    }
    if (bestDist > maxColorDistance) return null;
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

/// 单帧雷达分析结果
class RadarFrame {
  final DateTime time;
  final int width;
  final int height;

  /// 该帧所属的**投影** —— 所有经纬度↔像素换算都以它为准
  ///
  /// 这是本轮重构的核心：拼图（[EastChinaProjection]，2.6 km/px）与
  /// 单站图（[StationProjection]，0.68 km/px）几何完全不同，把投影挂在帧上
  /// 之后，取样/外推/边界判断就能共用一套代码，无需再靠「换成拼图」绕开。
  final RadarProjection projection;

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
    this.projection = const EastChinaProjection(),
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
/// 中央气象台只提供**栅格 PNG**（无原始 dBZ 数据），
/// 所以这里走「图像级」分析路线：
///   1. 按色标把像素反演为 dBZ
///   2. 提取回波区、算质心与强度分布
///   3. 多帧质心追踪 → 简易光流（运动矢量）
///   4. 按运动矢量外推 → 判断某点未来是否有降水
///
/// 参考：Z-R 关系 Marshall-Palmer(1948) 在 [WeatherEstimator] 中实现。
///
/// **两类产品**（URL 结构相同，仅产品码不同）：
/// · 区域拼图 `AECN`：774×1326，覆盖华东，2.6 km/px，底部有同色色标
/// · 单站雷达 `AZ####`：924×734，以站点为中心 256km，0.68 km/px，右侧面板有同色色标
/// 两者由 [RadarProjection] 区分，分析链路完全共用。
class RadarService {
  RadarService._();

  /// 解码 PNG 并分析回波
  ///
  /// [projection] 决定**地图区范围**与后续所有坐标换算：
  /// · 拼图：排除底部图例（色标与回波同色，不排除会凭空多出一条彩色横带）
  /// · 单站：排除右侧信息面板（内含 dBZ 色标条，实测含面板时 60/65 dBZ 各多 260+ 像素）
  ///
  /// [sampleStep] 采样步长（1=全像素，2=隔一个取一个，用于提速）
  static Future<RadarFrame?> analyze(
    Uint8List pngBytes,
    DateTime time, {
    RadarProjection projection = const EastChinaProjection(),
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

    // 只在**地图区**内提取回波（右边界与下边界都由投影给出）
    final mapRight = math.min(w, projection.mapWidthPx);
    final mapBottom = math.min(h, projection.mapHeightPx);

    final echoes = <({int x, int y, int dbz})>[];
    var sumX = 0.0, sumY = 0.0, sumDbz = 0.0;
    var maxDbz = 0;

    for (var y = 0; y < mapBottom; y += sampleStep) {
      for (var x = 0; x < mapRight; x += sampleStep) {
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

    final total = (mapBottom / sampleStep).round() *
        (mapRight / sampleStep).round();
    return RadarFrame(
      time: time,
      width: w,
      height: h,
      projection: projection,
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
  ///
  /// [kmPerPixel] 省略时取帧自带投影的比例（单站图 0.68 km/px 与
  /// 拼图 2.6 km/px 差近 4 倍，写死会导致速度算错 4 倍）。
  static RadarMotion? estimateMotion(
    List<RadarFrame> frames, {
    double? kmPerPixel,
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
      kmPerPixel: kmPerPixel ?? last.projection.kmPerPixel,
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
    final p = latest.projection.latLonToPixel(lat, lon);
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

  /// 雷达产品（拼图与单站共用）的**生成延迟**（分钟）
  ///
  /// 每 6 分钟一张，但从观测到出图有几分钟滞后。取帧时以
  /// 「当前时间 − 该延迟」再对齐到 6 分钟网格作为起点，避免总是先撞 404。
  static const int radarGenerationLagMinutes = 6;

  /// 雷达产品的标称时间间隔（分钟）
  static const int radarFrameMinutes = 6;

  /// **单站雷达的新鲜度阈值**（分钟）
  ///
  /// 单站雷达更新极不规律（实测 4 小时窗口仅约 10% 命中），所以判据是
  /// 「最近一帧距今 ≤ 60 分钟」→ 认为能代表「此刻」，用高精度的单站图定调；
  /// 超过则视为过期，**回退**到区域拼图（精度降到 2.6 km/px，但 80% 有数据）。
  ///
  /// 这正是用户要求的口径：**先查单站，查过且过期才回退拼图**，
  /// 而不是无条件用拼图。
  static const int stationFreshMinutes = 60;

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

  // ==================== 产品码 ====================

  /// 从 URL 或文件名模板里取产品码（区域码如 `AECN`，站点码如 `AZ9250`）
  static String? productCode(String radarPathOrTemplate) {
    final m = RegExp(r'ECREF_([A-Z0-9]+)_L88').firstMatch(radarPathOrTemplate);
    return m?.group(1);
  }

  /// 是否为**单站**产品码（中央气象台的站点码一律以 `AZ` 开头）
  static bool isStationCode(String? code) =>
      code != null && code.startsWith('AZ');

  /// 把任意产品模板改写成**华东拼图** `AECN`
  static String asMosaicTemplate(String template) =>
      template.contains('ECREF_AECN_')
          ? template
          : template.replaceFirst(
              RegExp(r'ECREF_[A-Z0-9]+_L88'), 'ECREF_AECN_L88');

  /// 拉取最近 N 帧雷达图（间隔 6 分钟，按时间正序返回）
  ///
  /// [radarPath] 来自 `NmcService.weather()` 的 `radarImagePath`，
  /// 形如 `/product/2026/09/19/RDCP/SEVP_..._PI_20260919073600000.PNG`。
  /// **这里只用它取「文件名模板」**（产品名与区域/站点码），时间戳一律按当前时间重算。
  ///
  /// ⚠️ **为什么不能用 radarPath 里的时间戳**（这是个实际踩过的坑）：
  /// 那个 path 是上一次调央台接口时拿到的。若 App 在后台挂了几小时，
  /// 缓存的 path 就指向几小时前的时刻 —— 而央台会清理过期产品，
  /// 于是构造出的 URL 全部 404，表现为**「雷达图获取不到」**，
  /// 重启 App 重新拉接口后才恢复。
  ///
  /// [forceMosaic] 为 true 时把产品码强制换成华东拼图 —— **仅用于地图叠加层**
  /// （叠加需要固定投影与固定经纬度范围）。用于「定调」的取样请走
  /// `RadarSourcePicker.pick()`，它会按「单站优先、过期回退拼图」选源。
  static Future<List<RadarRawFrame>> fetchRecentFrames({
    required String radarPath,
    int count = 3,
    http.Client? client,
    DateTime? now,
    bool forceMosaic = false,
  }) async {
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final fileName = radarPath.split('/').last;
      final piIdx = fileName.indexOf('PI_');
      if (piIdx < 0) return const [];
      var namePrefix = fileName.substring(0, piIdx);
      if (forceMosaic) namePrefix = asMosaicTemplate(namePrefix);

      // ⚠️ 文件名里的时间戳是 **UTC**，不是北京时间！
      // 实测：央台页面显示「制作时间 09/21 20:36」，而该帧的文件名是
      // `..._PI_20260921123600000.PNG` —— 正好差 8 小时。
      // 用本地时间去拼会一直去查 8 小时后的未来文件，全部 404。
      final base = (now ?? DateTime.now()).toUtc();
      var t = DateTime.utc(base.year, base.month, base.day, base.hour, base.minute)
          .subtract(const Duration(minutes: radarGenerationLagMinutes));
      t = DateTime.utc(t.year, t.month, t.day, t.hour,
          (t.minute ~/ radarFrameMinutes) * radarFrameMinutes);

      final out = <RadarRawFrame>[];
      var attempts = 0;
      // ⚠️ 回退帧数要够大：实测区域拼图**最新帧常滞后 20~40 分钟**，
      // 个别时段（如凌晨）可能更久。只给 10 帧（1 小时）会偶发一帧都取不到。
      // 给到 20 帧（2 小时）后，实测 80% 的窗口都能稳定拿到 3 帧。
      final maxAttempts = count + 17;
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
  static Future<Uint8List?> cropToMapArea(
    Uint8List pngBytes, {
    RadarProjection projection = const EastChinaProjection(),
  }) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    final newW = math.min(src.width, projection.mapWidthPx);
    final newH = math.min(src.height, projection.mapHeightPx);

    final bd = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return null;
    final px = bd.buffer.asUint8List();

    final srcStride = src.width * 4;
    final dstStride = newW * 4;
    final cropped = Uint8List(dstStride * newH);
    for (var y = 0; y < newH; y++) {
      cropped.setRange(y * dstStride, y * dstStride + dstStride,
          px, y * srcStride);
    }

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
      newW,
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
    RadarProjection projection = const EastChinaProjection(),
  }) {
    final sw = projection.pixelToLatLon(0, projection.mapHeightPx.toDouble());
    final ne = projection.pixelToLatLon(projection.mapWidthPx.toDouble(), 0);
    return (swLat: sw.lat, swLon: sw.lon, neLat: ne.lat, neLon: ne.lon);
  }

  /// 回波强度 → 降水强度（mm/h），用 Z-R 关系反演
  static double dbzToRainRate(int dbz) => WeatherEstimator.dbzToRainRate(dbz.toDouble());

  /// 查询某经纬度上的回波强度（dBZ），无回波返回 null
  ///
  /// ⚠️ 两个关键点（之前实现有误，导致误报）：
  /// 1. **半径要小**：拼图分辨率 1px ≈ 2.6km，之前默认 8px ≈ **21km**，
  ///    会把 20km 外的回波算到目标点头上 → 明明是阴天却报「中到大雨」。
  ///    现在默认 1px，与数据源本身的空间精度匹配（单站图 1px ≈ 0.68km）。
  /// 2. **取最近点而非最大值**：目标点是否有雨取决于**它自己**的回波，
  ///    而不是附近最强的回波。
  static int? sampleAt(
    RadarFrame frame,
    double lat,
    double lon, {
    int radiusPx = 1,
  }) {
    final p = frame.projection.latLonToPixel(lat, lon);
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
  /// [radiusPx] 建议不超过 3（拼图上 ≈8km），过大会把远处回波算进来。
  static int? maxEchoNear(
    RadarFrame frame,
    double lat,
    double lon, {
    int radiusPx = 3,
  }) {
    final p = frame.projection.latLonToPixel(lat, lon);
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
    final p1 = frame.projection.latLonToPixel(latMin, lonMin);
    final p2 = frame.projection.latLonToPixel(latMax, lonMax);
    final x0 = math.min(p1.x, p2.x), x1 = math.max(p1.x, p2.x);
    final y0 = math.min(p1.y, p2.y), y1 = math.max(p1.y, p2.y);
    for (final e in frame.echoes) {
      if (e.x >= x0 && e.x <= x1 && e.y >= y0 && e.y <= y1) return true;
    }
    return false;
  }
}
