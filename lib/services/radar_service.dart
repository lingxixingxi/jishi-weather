import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

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

  /// 回波强度 → 降水强度（mm/h），用 Z-R 关系反演
  static double dbzToRainRate(int dbz) => WeatherEstimator.dbzToRainRate(dbz.toDouble());
}
