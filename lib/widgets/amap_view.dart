import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:amap_map/amap_map.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../services/api_keys.dart';

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

  /// 天气叠加图片（PNG 字节）—— 用 GroundOverlay 贴到地图上，
  /// **只占 1 个图层**，性能远好于成百上千个 Polygon，且是真正的位图平滑效果。
  final Uint8List? overlayImage;
  final LatLng? overlaySouthwest;
  final LatLng? overlayNortheast;
  final double overlayTransparency;

  /// 瓦片式叠加层的 URL 模板（形如 `https://host/{z}/{x}/{y}.png`）
  ///
  /// 与 [overlayImage] 二选一：瓦片在任意缩放级别都清晰，适合雷达数据；
  /// 单张图片则会随放大而模糊。
  final String? tileOverlayUrl;
  final double tileTransparency;

  const AmapView({
    super.key,
    required this.lat,
    required this.lon,
    this.zoom = 13,
    this.markers = const [],
    this.polylines = const [],
    this.polygons = const [],
    this.fitPoints = const [],
    this.overlayImage,
    this.overlaySouthwest,
    this.overlayNortheast,
    this.overlayTransparency = 0.0,
    this.tileOverlayUrl,
    this.tileTransparency = 0.3,
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

  /// 高德 Android 平台 Key —— **运行时**取，不能写 `const`
  ///
  /// 这个 Key 绑定「包名 + 签名 SHA1」，但它并非只能编译期注入：官方
  /// 支持运行时 `MapsInitializer.setApiKey()`，flutter_amap 插件已透传
  /// （`ConvertUtil.java` 里调的 `MapsInitializer.setApiKey`）。
  ///
  /// ⚠️ 千万别改回 `static const` —— 那样会在编译期把内置 Key 固化，
  /// 用户在设置页填的 Key 永远读不到，公测版就成了「只能用发布者的
  /// 额度」，人多必爆。
  AMapApiKey get _apiKey => AMapApiKey(
        androidKey: ApiKeys.amapAndroid,
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

    // 叠加图片变化（切换图层 / 拖动时间轴）→ 重新贴图
    if (!identical(oldWidget.overlayImage, widget.overlayImage)) {
      _applyOverlay();
    }

    // 瓦片 URL 变化（切换雷达瓦片源）→ 重建瓦片层
    if (oldWidget.tileOverlayUrl != widget.tileOverlayUrl) {
      _applyTileOverlay();
    }

    // fitPoints 变化（如切换候选路线）→ 自动缩放到新范围
    if (!_samePoints(oldWidget.fitPoints, widget.fitPoints)) {
      _scheduleFit();
      return;
    }

    // 中心点或缩放级别变化时，镜头自动跟过去
    final moved = (oldWidget.lat != widget.lat) ||
        (oldWidget.lon != widget.lon) ||
        (oldWidget.zoom != widget.zoom);
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
    return CameraPosition(target: center, zoom: z.clamp(4.0, 17.0).toDouble());
  }

  /// 应用/更新瓦片式叠加层（按 z/x/y 请求，任意缩放清晰）
  Future<void> _applyTileOverlay() async {
    final c = _controller;
    if (c == null || !mounted) return;
    final url = widget.tileOverlayUrl;
    try {
      if (url == null || url.isEmpty) {
        await c.removeTileOverlay();
        return;
      }
      await c.setTileOverlay(url, transparency: widget.tileTransparency);
      debugPrint('[AmapView] 瓦片叠加已设置');
    } catch (e) {
      debugPrint('[AmapView] 瓦片叠加失败: $e');
    }
  }

  /// 应用/更新天气叠加图片（GroundOverlay，仅占 1 个图层）
  Future<void> _applyOverlay() async {
    final c = _controller;
    if (c == null || !mounted) return;
    final img = widget.overlayImage;
    final sw = widget.overlaySouthwest;
    final ne = widget.overlayNortheast;
    try {
      if (img == null || sw == null || ne == null) {
        await c.removeGroundOverlay();
        return;
      }
      await c.setGroundOverlay(
        img,
        southwest: sw,
        northeast: ne,
        transparency: widget.overlayTransparency,
      );
      debugPrint('[AmapView] 叠加层已设置 (${img.length} 字节)');
    } catch (e) {
      debugPrint('[AmapView] 叠加层设置失败: $e');
    }
  }

  /// 是否正在由 `fitPoints` 驱动相机移动
  ///
  /// 这段窗口内的相机回调**不转发给外部**（见 [onCameraMoveEnd] 处的说明）：
  /// 否则会形成正反馈 —— fitPoints（由网格范围算出）→ moveCamera →
  /// zoom 变化 → 外部按新 zoom 重采网格 → 网格范围变 → fitPoints 变 →
  /// 再 moveCamera …（实测把 zoom 从 11.5 一路发散到 7.7）。
  bool _autoFitting = false;

  /// 延迟执行 fitBounds：地图刚创建时立即调用常不生效，多试几次
  void _scheduleFit() {    WidgetsBinding.instance.addPostFrameCallback((_) => _applyFit());
    for (final ms in [600, 1500, 3000]) {
      Future.delayed(Duration(milliseconds: ms), _applyFit);
    }
  }

  /// 上一次真正执行过的适配范围签名
  ///
  /// `_scheduleFit()` 会在 0/600/1500/3000ms 各调一次 `_applyFit`（地图刚创建时
  /// 立即调用常不生效）。若每次都真的 moveCamera，会有两个副作用：
  /// ① 反复重置 `_autoFitting` 抑制窗口，把用户的连续缩放一起吞掉；
  /// ② 频繁打断用户正在进行的捏合，缩放自然不顺滑。
  /// 用签名去重后，同一范围只适配一次。
  String? _lastFitKey;

  void _applyFit() {
    final c = _controller;
    final pts = widget.fitPoints;
    debugPrint('[AmapView] _applyFit controller=${c != null} points=${pts.length}');
    if (c == null || !mounted || pts.isEmpty) return;

    // 同一范围只适配一次。
    // ⚠️ 必须在**拿到 controller 之后**才记录签名 —— 否则地图尚未创建的那一次
    // 会把签名占掉，后续延迟重试全部被去重跳过，永远 fit 不上。
    final key = pts
        .map((p) => '${p.latitude.toStringAsFixed(6)},'
            '${p.longitude.toStringAsFixed(6)}')
        .join('|');
    if (key == _lastFitKey) return;
    _lastFitKey = key;

    // 标记「接下来这段相机变化是程序驱动的」，外部据此跳过重采等响应。
    // 窗口取 600ms：足够覆盖 moveCamera 的回调，又不长时间吞掉用户操作。
    _autoFitting = true;
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _autoFitting = false;
    });

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
        _applyOverlay(); // 应用天气叠加图片
        _applyTileOverlay(); // 应用瓦片叠加
        widget.onMapCreated?.call(c);
      },
      // ⚠️ 由 fitPoints 程序驱动的镜头移动**不转发给外部**，否则会形成正反馈：
      // fitPoints（由网格范围算出）→ moveCamera → zoom 变化 →
      // 外部按新 zoom 重采网格 → 网格范围变 → fitPoints 变 → 再 moveCamera …
      // 实测该循环会让 zoom 从 11.5 一路发散到 7.7，越缩越小。
      onCameraMoveEnd: (pos) {
        if (_autoFitting) return;
        widget.onCameraMoveEnd?.call(pos.target, pos.zoom);
      },
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
  double fontSize = 16,
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

  const padH = 9.0;
  const padV = 5.0;
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
