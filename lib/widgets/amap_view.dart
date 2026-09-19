import 'dart:ui' as ui;

import 'package:amap_map/amap_map.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../config/secrets.dart';

/// 高德地图视图（封装隐私合规 + 手势 + 常用参数）
///
/// ⚠️ 高德 SDK 合规要求：必须先声明隐私政策已展示并获用户同意，
/// 三个标志任一为 false 都会导致地图白屏。
class AmapView extends StatefulWidget {
  final double lat;
  final double lon;
  final double zoom;
  final List<Marker> markers;
  final List<Polyline> polylines;

  /// 面状覆盖物：用于云量/降水热力格等叠加
  final List<Polygon> polygons;

  /// 是否独占手势。放在可滚动容器里必须为 true，
  /// 否则外层滚动视图会抢走手势，导致地图无法缩放/拖动。
  final bool interactive;

  /// 点击激活模式（滚动容器内推荐开启）：
  /// 开启后地图**默认不接管手势**（页面可正常上下滚动），
  /// 用户点击地图才进入可拖动/缩放状态，点「完成」退出。
  final bool tapToActivate;

  final void Function(AMapController controller)? onMapCreated;
  final void Function(LatLng target, double zoom)? onCameraMoveEnd;

  /// 需要自动框住的点集合（非空时，地图就绪/内容变化后自动缩放到该范围）
  final List<LatLng> fitPoints;

  const AmapView({
    super.key,
    required this.lat,
    required this.lon,
    this.zoom = 13,
    this.markers = const [],
    this.polylines = const [],
    this.polygons = const [],
    this.fitPoints = const [],
    this.interactive = true,
    this.tapToActivate = true,
    this.onMapCreated,
    this.onCameraMoveEnd,
  });

  @override
  State<AmapView> createState() => _AmapViewState();
}

class _AmapViewState extends State<AmapView> {
  bool _ready = false;

  /// 点击激活模式下：是否已进入「可操作地图」状态
  bool _activated = false;

  AMapController? _controller;

  static const _apiKey = AMapApiKey(
    androidKey: Secrets.amapAndroidKey,
    iosKey: '',
  );

  static const _privacy = AMapPrivacyStatement(
    hasContains: true, // 隐私政策已包含高德
    hasShow: true, // 已弹窗展示
    hasAgree: true, // 已获用户同意
  );

  @override
  void initState() {
    super.initState();
    // 必须等首帧后再初始化（AMapInitializer.init 需要 context）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AMapInitializer.init(context, apiKey: _apiKey);
      AMapInitializer.updatePrivacyAgree(_privacy);
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void didUpdateWidget(AmapView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // fitPoints 变化（如切换候选路线）→ 自动缩放到新范围
    if (!_samePoints(oldWidget.fitPoints, widget.fitPoints)) {
      _scheduleFit();
      return;
    }

    // 中心点变化（例如从「查询天气」切到「当前位置」）时，镜头自动跟过去
    final moved = (oldWidget.lat != widget.lat) || (oldWidget.lon != widget.lon);
    if (moved) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _controller?.moveCamera(CameraUpdate.newLatLngZoom(
          LatLng(widget.lat, widget.lon),
          widget.zoom,
        ));
      });
    }
  }

  bool _samePoints(List<LatLng> a, List<LatLng> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    // 只比较首尾，足够判断路线是否变化
    if (a.isEmpty) return true;
    return a.first.latitude == b.first.latitude &&
        a.first.longitude == b.first.longitude &&
        a.last.latitude == b.last.latitude &&
        a.last.longitude == b.last.longitude;
  }

  /// 由 fitPoints 直接算出的初始镜头（中心 + 适配 zoom）
  CameraPosition _initialCameraPosition() {
    final pts = widget.fitPoints;
    if (pts.isEmpty) {
      return CameraPosition(target: LatLng(widget.lat, widget.lon), zoom: widget.zoom);
    }
    var minLat = pts.first.latitude, maxLat = pts.first.latitude;
    var minLon = pts.first.longitude, maxLon = pts.first.longitude;
    for (final p in pts) {
      minLat = minLat < p.latitude ? minLat : p.latitude;
      maxLat = maxLat > p.latitude ? maxLat : p.latitude;
      minLon = minLon < p.longitude ? minLon : p.longitude;
      maxLon = maxLon > p.longitude ? maxLon : p.longitude;
    }
    final center = LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);
    final latSpan = (maxLat - minLat).abs();
    final lonSpan = (maxLon - minLon).abs();
    final span = latSpan > lonSpan ? latSpan : lonSpan;
    if (span < 1e-5) return CameraPosition(target: center, zoom: 14);
    // 粗略换算 zoom：跨度 0.1° ≈ z11，每翻倍降 1 级
    final z = 11 - (math.log(span / 0.1) / math.ln2);
    return CameraPosition(target: center, zoom: z.clamp(4.0, 17.0));
  }

  /// 延迟执行 fitBounds：地图刚创建时立即调用常不生效，多试几次
  void _scheduleFit() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyFit());
    for (final ms in [600, 1500, 3000]) {
      Future.delayed(Duration(milliseconds: ms), _applyFit);
    }
  }

  void _applyFit() {
    final c = _controller;
    final pts = widget.fitPoints;
    debugPrint('[AmapView] _applyFit controller=${c != null} points=${pts.length}');
    if (c == null || !mounted || pts.isEmpty) return;
    if (pts.length == 1) {
      c.moveCamera(CameraUpdate.newLatLngZoom(pts.first, 13));
      return;
    }
    var minLat = pts.first.latitude, maxLat = pts.first.latitude;
    var minLon = pts.first.longitude, maxLon = pts.first.longitude;
    for (final p in pts) {
      minLat = minLat < p.latitude ? minLat : p.latitude;
      maxLat = maxLat > p.latitude ? maxLat : p.latitude;
      minLon = minLon < p.longitude ? minLon : p.longitude;
      maxLon = maxLon > p.longitude ? maxLon : p.longitude;
    }
    if ((maxLat - minLat).abs() < 1e-4 && (maxLon - minLon).abs() < 1e-4) {
      c.moveCamera(CameraUpdate.newLatLngZoom(pts.first, 12));
      return;
    }
    debugPrint('[AmapView] moveCamera lat:$minLat~$maxLat lon:$minLon~$maxLon');
    c.moveCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(minLat, minLon),
        northeast: LatLng(maxLat, maxLon),
      ),
      56,
    ));
  }

  /// 供外部调用：把镜头移动到能框住全部点的范围
  void fitBounds(List<LatLng> points) {
    if (_controller == null || points.isEmpty) return;
    if (points.length == 1) {
      _controller!.moveCamera(CameraUpdate.newLatLngZoom(points.first, 13));
      return;
    }
    var minLat = points.first.latitude, maxLat = points.first.latitude;
    var minLon = points.first.longitude, maxLon = points.first.longitude;
    for (final p in points) {
      minLat = minLat < p.latitude ? minLat : p.latitude;
      maxLat = maxLat > p.latitude ? maxLat : p.latitude;
      minLon = minLon < p.longitude ? minLon : p.longitude;
      maxLon = maxLon > p.longitude ? maxLon : p.longitude;
    }
    // 单点/边界过小时给个合理 zoom
    if ((maxLat - minLat).abs() < 1e-4 && (maxLon - minLon).abs() < 1e-4) {
      _controller!.moveCamera(CameraUpdate.newLatLngZoom(points.first, 13));
      return;
    }
    _controller!.moveCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(minLat, minLon),
        northeast: LatLng(maxLat, maxLon),
      ),
      48, // padding
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFF0A928)),
        ),
      );
    }

    // 只有「已激活」或「非点击激活模式」才让地图独占手势
    final mapActive = widget.interactive && (!widget.tapToActivate || _activated);

    final map = AMapWidget(
      // 首次就用 fitPoints 算好的视野（避免依赖 moveCamera 的时序问题）
      initialCameraPosition: _initialCameraPosition(),
      markers: widget.markers.toSet(),
      polylines: widget.polylines.toSet(),
      polygons: widget.polygons.toSet(),
      onMapCreated: (c) {
        _controller = c;
        _scheduleFit(); // 地图就绪后自动框住 fitPoints
        widget.onMapCreated?.call(c);
      },
      onCameraMoveEnd: (pos) => widget.onCameraMoveEnd?.call(pos.target, pos.zoom),
      // 手势：仅在激活时独占，保证页面能正常滚动
      zoomGesturesEnabled: true,
      scrollGesturesEnabled: true,
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: false,
      gestureRecognizers: mapActive
          ? <Factory<OneSequenceGestureRecognizer>>{
              Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
            }
          : const <Factory<OneSequenceGestureRecognizer>>{},
      buildingsEnabled: true,
      labelsEnabled: true,
      compassEnabled: true,
      scaleEnabled: true,
    );

    // 非点击激活模式：直接返回地图
    if (!widget.tapToActivate) return map;

    // 已激活：右上角给一个「完成」退出交互
    if (_activated) {
      return Stack(
        children: [
          map,
          Positioned(
            right: 8,
            top: 8,
            child: GestureDetector(
              onTap: () => setState(() => _activated = false),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xE6141A24),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFF0A928)),
                ),
                child: const Text('完成',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFFF0A928))),
              ),
            ),
          ),
        ],
      );
    }

    // 未激活：盖一层只响应「点击」的透明层 —— 拖动会冒泡给外层滚动视图
    return Stack(
      children: [
        map,
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _activated = true),
            child: Container(
              color: Colors.transparent,
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xCC0C1119),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x55F0A928)),
                  ),
                  child: const Text(
                    '点击激活地图',
                    style: TextStyle(fontSize: 11, color: Color(0xFFF0A928), fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 生成「带文字」的地图标注图标（Marker 原生不支持常驻文字，只能自绘）
///
/// 画一个圆角胶囊：色块 + 白字，用于路线上直接标注温度/天气/SEG 等。
Future<BitmapDescriptor> buildLabelIcon({
  required String text,
  Color color = const Color(0xFFF0A928),
  Color textColor = const Color(0xFF14100A),
  double fontSize = 12,
}) async {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: textColor,
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  const padH = 7.0;
  const padV = 4.0;
  final w = tp.width + padH * 2;
  final h = tp.height + padV * 2;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rrect = RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, w, h),
    const Radius.circular(6),
  );
  canvas.drawRRect(rrect, Paint()..color = color);
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x55000000),
  );
  tp.paint(canvas, const Offset(padH, padV));

  final image = await recorder.endRecording().toImage(w.ceil(), h.ceil());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
}
