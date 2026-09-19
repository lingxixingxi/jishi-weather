import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../config/secrets.dart';

/// 高德地图视图（封装隐私合规与常用参数）
///
/// ⚠️ 高德 SDK 合规要求：必须先声明隐私政策已展示并获用户同意，
/// 三个标志任一为 false 都会导致地图白屏。
class AmapView extends StatefulWidget {
  final double lat;
  final double lon;
  final double zoom;
  final List<Marker> markers;
  final List<Polyline> polylines;
  final void Function(AMapController controller)? onMapCreated;

  const AmapView({
    super.key,
    required this.lat,
    required this.lon,
    this.zoom = 13,
    this.markers = const [],
    this.polylines = const [],
    this.onMapCreated,
  });

  @override
  State<AmapView> createState() => _AmapViewState();
}

class _AmapViewState extends State<AmapView> {
  bool _ready = false;

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
      onMapCreated: widget.onMapCreated,
      // 手势：可缩放拖动（标注锚定经纬度自动跟随）
      zoomGesturesEnabled: true,
      scrollGesturesEnabled: true,
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: false,
      buildingsEnabled: true,
      labelsEnabled: true,
      compassEnabled: true,
      scaleEnabled: true,
    );
  }
}
