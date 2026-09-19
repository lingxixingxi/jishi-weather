// Copyright 2023-2024 kuloud
// Copyright 2020 lbs.amap.com
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,

part of '../amap_map.dart';

final MethodChannelAMapFlutterMap _methodChannel =
    AMapFlutterPlatform.instance as MethodChannelAMapFlutterMap;

/// 地图通信中心
class AMapController {
  final int mapId;
  final _MapState _mapState;

  AMapController._(CameraPosition initCameraPosition, this._mapState,
      {required this.mapId}) {
    _connectStreams(mapId);
  }

  ///根据传入的id初始化[AMapController]
  /// 主要用于在[AMapWidget]初始化时在[AMapWidget.onMapCreated]中初始化controller
  static Future<AMapController> init(
    int id,
    CameraPosition initialCameration,
    dynamic mapState,
  ) async {
    await _methodChannel.init(id);
    return AMapController._(
      initialCameration,
      mapState,
      mapId: id,
    );
  }

  ///只用于测试
  ///用于与native的通信
  @visibleForTesting
  MethodChannel get channel {
    return _methodChannel.channel(mapId);
  }

  void _connectStreams(int mapId) {
    _methodChannel.onLocationChanged(mapId: mapId).listen(
        (LocationChangedEvent e) =>
            _mapState.widget.onLocationChanged?.call(e.value));

    _methodChannel.onCameraMove(mapId: mapId).listen((CameraMoveEvent e) {
      _mapState.widget.onCameraMove?.call(e.value);
      if (_mapState.widget.infoWindowAdapter != null) {
        _mapState.updateMarkers();
      }
    });

    _methodChannel.onCameraMoveEnd(mapId: mapId).listen((CameraMoveEndEvent e) {
      _mapState.widget.onCameraMoveEnd?.call(e.value);
    });
    _methodChannel
        .onMapTap(mapId: mapId)
        .listen(((MapTapEvent e) => _mapState.widget.onTap?.call(e.value)));
    _methodChannel.onMapLongPress(mapId: mapId).listen(((MapLongPressEvent e) {
      _mapState.widget.onLongPress?.call(e.value);
    }));

    _methodChannel.onPoiTouched(mapId: mapId).listen(((MapPoiTouchEvent e) {
      _mapState.widget.onPoiTouched?.call(e.value);
    }));

    _methodChannel.onMarkerTap(mapId: mapId).listen((MarkerTapEvent e) {
      _mapState.onMarkerTap(e.value);
    });

    _methodChannel.onMarkerDragEnd(mapId: mapId).listen((MarkerDragEndEvent e) {
      _mapState.onMarkerDragEnd(e.value, e.position);
    });

    _methodChannel.onPolylineTap(mapId: mapId).listen((PolylineTapEvent e) {
      _mapState.onPolylineTap(e.value);
    });
  }

  void disponse() {
    _methodChannel.dispose(id: mapId);
  }

  Future<void> _updateMapOptions(Map<String, dynamic> optionsUpdate) {
    return _methodChannel.updateMapOptions(optionsUpdate, mapId: mapId);
  }

  Future<void> _updateMarkers(MarkerUpdates markerUpdates) {
    return _methodChannel.updateMarkers(markerUpdates, mapId: mapId);
  }

  Future<void> _updatePolylines(PolylineUpdates polylineUpdates) {
    return _methodChannel.updatePolylines(polylineUpdates, mapId: mapId);
  }

  Future<void> _updatePolygons(PolygonUpdates polygonUpdates) {
    return _methodChannel.updatePolygons(polygonUpdates, mapId: mapId);
  }

  ///改变地图视角
  ///
  ///通过[CameraUpdate]对象设置新的中心点、缩放比例、放大缩小、显示区域等内容
  ///
  ///（注意：iOS端设置显示区域时，不支持duration参数，动画时长使用iOS地图默认值350毫秒）
  ///
  ///可选属性[animated]用于控制是否执行动画移动
  ///
  ///可选属性[duration]用于控制执行动画的时长,默认250毫秒,单位:毫秒
  Future<void> moveCamera(CameraUpdate cameraUpdate,
      {bool animated = true, int duration = 250}) {
    return _methodChannel.moveCamera(cameraUpdate,
        mapId: mapId, animated: animated, duration: duration);
  }

  /// 地图截屏
  Future<Uint8List?> takeSnapshot() {
    return _methodChannel.takeSnapshot(mapId: mapId);
  }

  /// 天气叠加：把一张 PNG 按经纬度范围贴到地图上（云图/雷达图）
  ///
  /// 相比用几百个 Polygon 拼热力图，图片层只占 **1 个图层**，
  /// 性能极好，且能呈现真正连续的位图效果（卫星云图同款做法）。
  ///
  /// [imageBytes] PNG 字节；[southwest]/[northeast] 覆盖范围角点；
  /// [transparency] 0~1（0 = 完全不透明，1 = 全透明）
  Future<void> setGroundOverlay(
    Uint8List imageBytes, {
    required LatLng southwest,
    required LatLng northeast,
    double transparency = 0.0,
  }) {
    return _methodChannel.setGroundOverlay(
      imageBytes,
      southwest: southwest,
      northeast: northeast,
      transparency: transparency,
      mapId: mapId,
    );
  }

  /// 移除天气叠加层
  Future<void> removeGroundOverlay() {
    return _methodChannel.removeGroundOverlay(mapId: mapId);
  }

  /// 瓦片式叠加层（按 z/x/y 请求图片）
  ///
  /// 相比 [setGroundOverlay] 的单张图片拉伸，瓦片在**任意缩放级别都清晰**，
  /// 适合雷达/卫星等需要放大的叠加数据。
  ///
  /// [urlTemplate] 形如 `https://host/path/{z}/{x}/{y}.png`
  /// （`{x}` `{y}` `{z}` 会被自动替换）。
  Future<void> setTileOverlay(
    String urlTemplate, {
    double transparency = 0.0,
  }) {
    return _methodChannel.setTileOverlay(
      urlTemplate,
      transparency: transparency,
      mapId: mapId,
    );
  }

  /// 移除瓦片叠加层
  Future<void> removeTileOverlay() {
    return _methodChannel.removeTileOverlay(mapId: mapId);
  }

  /// 清空缓存
  Future<void> clearDisk() {
    return _methodChannel.clearDisk(mapId: mapId);
  }

  /// 经纬度转屏幕坐标 since v1.0.3
  Future<ScreenCoordinate> toScreenCoordinate(LatLng latLng) {
    return _methodChannel.toScreenLocation(latLng, mapId: mapId);
  }

  /// 屏幕坐标转经纬度 From v1.0.3
  Future<LatLng> fromScreenCoordinate(ScreenCoordinate screenCoordinate) {
    return _methodChannel.fromScreenLocation(screenCoordinate, mapId: mapId);
  }

  Future<String> getMapContentApprovalNumber() {
    return _methodChannel.getMapContentApprovalNumber(mapId: mapId);
  }

  Future<String> getSatelliteImageApprovalNumber() {
    return _methodChannel.getSatelliteImageApprovalNumber(mapId: mapId);
  }
}
