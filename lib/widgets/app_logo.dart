import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 迹时天气 Logo（矢量绘制）
///
/// 与 `weather-brief/logo/logo-final.svg` 同源：
/// **线条云**（琥珀描边 + 淡琥珀填充）+ **太阳轮廓圆**（与云交叠处被云体切割）
/// + **五节点轨迹**（呼应 5 源融合）。
///
/// 用 [CustomPainter] 而非 PNG 资源：
/// - 任意 DPI 都锐利（标题旁 28px 与启动图标 512px 共用同一份代码）
/// - 不增加包体
/// - 换色只改常量
///
/// 线条宽度会按**实际渲染像素**自适应加粗（见 [_strokeBoost]）——
/// 小尺寸下若按原始比例，线条会细到看不清。
class AppLogo extends StatelessWidget {
  final double size;

  /// 是否绘制圆角方形底色（App 标题旁用 false；启动图标用 true）
  final bool withBackground;

  const AppLogo({super.key, this.size = 28, this.withBackground = false});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _AppLogoPainter(withBackground: withBackground)),
      );
}

class _AppLogoPainter extends CustomPainter {
  final bool withBackground;

  const _AppLogoPainter({required this.withBackground});

  // ==================== 与 SVG 一致的关键参数 ====================
  // 云的原始形状定义在 24×24 网格上（见 _cloudPath），由下面两个常量缩放定位
  static const double _cloudScale = 26.196;
  static const double _cloudDx = 197.65;
  static const double _cloudDy = 140.65;

  static const Offset _sunCenter = Offset(725.6, 321);
  static const double _sunRadius = 138;

  /// 线条基准宽度（1024 坐标系，与 SVG 一致）
  static const double _sunStroke = 19;
  static const double _cloudStroke = 0.74 * _cloudScale; // ≈19.4
  static const double _trackStroke = 23;
  static const double _nodeRadius = 16;
  static const double _nodeStroke = 12;

  /// 轨迹五节点（呼应 5 源融合）
  static const List<Offset> _trackPoints = [
    Offset(270, 770),
    Offset(391, 718),
    Offset(512, 776),
    Offset(633, 724),
    Offset(754, 772),
  ];

  /// 内容实际边界（1024 坐标系）—— 用于裁掉画布上的多余留白，
  /// 这样小尺寸下图形占比更大、更清晰
  static const Rect _content = Rect.fromLTRB(197.65, 183, 864, 792);

  // ==================== 颜色 ====================
  static const Color _accentA = Color(0xFFFFC850);
  static const Color _accentB = Color(0xFFDE9018);
  static const Color _bgTop = Color(0xFF151C28);
  static const Color _bgBottom = Color(0xFF0A0E14);
  static const Color _nodeHole = Color(0xFF0E1420);

  /// 线条加粗系数
  ///
  /// 基准线条在 1024 画布上是 19px；缩到 28px 显示时只剩 0.5 逻辑像素，
  /// 细到几乎看不见。因此按 widget 的实际像素宽度分档加粗。
  static double _strokeBoost(double pixels) {
    if (pixels <= 32) return 1.65;
    if (pixels <= 64) return 1.35;
    if (pixels <= 128) return 1.15;
    return 1.0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final scale = math.min(
      size.width / _content.width,
      size.height / _content.height,
    );

    canvas.save();
    // 把 _content 区域映射到整个 widget
    canvas.translate(
      (size.width - _content.width * scale) / 2 - _content.left * scale,
      (size.height - _content.height * scale) / 2 - _content.top * scale,
    );
    canvas.scale(scale);

    final boost = _strokeBoost(size.width);

    if (withBackground) _paintBackground(canvas);

    final cloud = _cloudPath();
    _paintSun(canvas, cloud, boost);
    _paintCloud(canvas, cloud, boost);
    _paintTrack(canvas, boost);

    canvas.restore();
  }

  // ==================== 各部件 ====================

  void _paintBackground(Canvas canvas) {
    final rect = Rect.fromLTWH(
      _content.left - 40,
      _content.top - 40,
      _content.width + 80,
      _content.height + 80,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_bgTop, _bgBottom],
        ).createShader(rect),
    );
  }

  /// 太阳：描边圆，并用「云的区域」把交叠部分挖掉（等价于 SVG 的 mask）
  void _paintSun(Canvas canvas, Path cloud, double boost) {
    final stroke = _sunStroke * boost;
    final bounds = Rect.fromCircle(center: _sunCenter, radius: _sunRadius + stroke);
    canvas.saveLayer(bounds, Paint());

    final sun = Path()..addOval(Rect.fromCircle(center: _sunCenter, radius: _sunRadius));
    canvas.drawPath(
      sun,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..shader = _accentShader(bounds),
    );

    // 挖掉云体覆盖的部分：dstOut 按源的 alpha 清除已有像素
    canvas.drawPath(
      cloud,
      Paint()
        ..style = PaintingStyle.fill
        ..blendMode = BlendMode.dstOut,
    );

    canvas.restore();
  }

  void _paintCloud(Canvas canvas, Path cloud, double boost) {
    final bounds = cloud.getBounds();
    // 淡琥珀填充（初版的浓度）
    canvas.drawPath(
      cloud,
      Paint()
        ..style = PaintingStyle.fill
        ..color = const Color(0xFFF0A928).withValues(alpha: 0.10),
    );
    // 琥珀描边
    canvas.drawPath(
      cloud,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _cloudStroke * boost
        ..strokeJoin = StrokeJoin.round
        ..shader = _accentShader(bounds),
    );
  }

  void _paintTrack(Canvas canvas, double boost) {
    final track = Path()..moveTo(_trackPoints.first.dx, _trackPoints.first.dy);
    for (var i = 1; i < _trackPoints.length; i++) {
      track.lineTo(_trackPoints[i].dx, _trackPoints[i].dy);
    }
    final bounds = track.getBounds().inflate(_trackStroke * boost);

    canvas.drawPath(
      track,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _trackStroke * boost
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = _accentShader(bounds),
    );

    for (final p in _trackPoints) {
      // 节点底色（挖空感）
      canvas.drawCircle(p, _nodeRadius, Paint()..color = _nodeHole);
      canvas.drawCircle(
        p,
        _nodeRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _nodeStroke * boost
          ..shader = _accentShader(
            Rect.fromCircle(center: p, radius: _nodeRadius + _nodeStroke * boost),
          ),
      );
    }
  }

  Shader _accentShader(Rect bounds) => const LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [_accentA, _accentB],
      ).createShader(bounds);

  /// 云形状 —— 与 SVG 的 `#cloudShape` 完全相同（24×24 网格上的三次贝塞尔）
  ///
  /// 想换云形，改这里即可（改完请同步 `weather-brief/logo/logo-final.svg`）。
  Path _cloudPath() {
    final p = Path()
      ..moveTo(19.35, 10.04)
      ..cubicTo(18.67, 6.59, 15.64, 4, 12, 4)
      ..cubicTo(9.11, 4, 6.6, 5.64, 5.35, 8.04)
      ..cubicTo(2.34, 8.36, 0, 10.91, 0, 14)
      ..cubicTo(0, 17.31, 2.69, 20, 6, 20)
      ..lineTo(19, 20)
      ..cubicTo(21.76, 20, 24, 17.76, 24, 15)
      ..cubicTo(24, 12.36, 21.95, 10.22, 19.35, 10.04)
      ..close();

    return p.transform(
      (Matrix4.identity()
            ..translate(_cloudDx, _cloudDy)
            ..scale(_cloudScale, _cloudScale))
          .storage,
    );
  }

  @override
  bool shouldRepaint(covariant _AppLogoPainter old) =>
      old.withBackground != withBackground;
}
