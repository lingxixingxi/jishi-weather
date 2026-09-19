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

  /// 是否独占手势。放在可滚动容器里必须为 true，
  /// 否则外层滚动视图会抢走手势，导致地图无法缩放/拖动。
  final bool interactive;

  final void Function(AMapController controller)? onMapCreated;
  final void Function(LatLng target, double zoom)? onCameraMoveEnd;

  const AmapView({
    super.key,
    required this.lat,
    required this.lon,
    this.zoom = 13,
    this.markers = const [],
    this.polylines = const [],
    this.interactive = true,
    this.onMapCreated,
    this.onCameraMoveEnd,
  });

  @override
  State<AmapView> createState() => _AmapViewState();
}

class _AmapViewState extends State<AmapView> {
  bool _ready = false;
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
    return AMapWidget(
      initialCameraPosition: CameraPosition(
        target: LatLng(widget.lat, widget.lon),
        zoom: widget.zoom,
      ),
      markers: widget.markers.toSet(),
      polylines: widget.polylines.toSet(),
      onMapCreated: (c) {
        _controller = c;
        widget.onMapCreated?.call(c);
      },
      onCameraMoveEnd: (pos) => widget.onCameraMoveEnd?.call(pos.target, pos.zoom),
      // 手势：可缩放拖动（标注锚定经纬度自动跟随）
      zoomGesturesEnabled: true,
      scrollGesturesEnabled: true,
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: false,
      // 关键：独占手势，避免被外层 CustomScrollView 抢走
      gestureRecognizers: widget.interactive
          ? <Factory<OneSequenceGestureRecognizer>>{
              Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
            }
          : const <Factory<OneSequenceGestureRecognizer>>{},
      buildingsEnabled: true,
      labelsEnabled: true,
      compassEnabled: true,
      scaleEnabled: true,
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
