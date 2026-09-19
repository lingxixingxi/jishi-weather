package com.amap.flutter.map.core;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Point;
import android.location.Location;

import androidx.annotation.NonNull;

import com.amap.api.maps.AMap;
import com.amap.api.maps.CameraUpdate;
import com.amap.api.maps.CameraUpdateFactory;
import com.amap.api.maps.TextureMapView;
import com.amap.api.maps.model.BitmapDescriptorFactory;
import com.amap.api.maps.model.CameraPosition;
import com.amap.api.maps.model.CustomMapStyleOptions;
import com.amap.api.maps.model.GroundOverlay;
import com.amap.api.maps.model.GroundOverlayOptions;
import com.amap.api.maps.model.LatLng;
import com.amap.api.maps.model.LatLngBounds;
import com.amap.api.maps.model.MyLocationStyle;
import com.amap.api.maps.model.Poi;
import com.amap.api.maps.model.TileOverlay;
import com.amap.api.maps.model.TileOverlayOptions;
import com.amap.api.maps.model.UrlTileProvider;
import com.amap.flutter.map.MyMethodCallHandler;
import com.amap.flutter.map.utils.Const;
import com.amap.flutter.map.utils.ConvertUtil;
import com.amap.flutter.map.utils.LogUtil;

import java.io.ByteArrayOutputStream;
import java.net.URL;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * @author whm
 * @date 2020/11/11 7:00 PM
 * @mail hongming.whm@alibaba-inc.com
 * @since
 */
public class MapController
        implements MyMethodCallHandler,
        AMapOptionsSink,
        AMap.OnMapLoadedListener,
        AMap.OnMyLocationChangeListener,
        AMap.OnCameraChangeListener,
        AMap.OnMapClickListener,
        AMap.OnMapLongClickListener,
        AMap.OnPOIClickListener {
    private static final String CLASS_NAME = "MapController";
    private final MethodChannel methodChannel;
    private final AMap amap;
    private final TextureMapView mapView;
    private MethodChannel.Result mapReadyResult;
    private boolean mapLoaded = false;
    private boolean myLocationShowing = false;

    /** 天气叠加图片层（云图/雷达图），同一时刻只保留一个 */
    private GroundOverlay groundOverlay;

    /** 瓦片式叠加层（按 z/x/y 请求图片，任意缩放都清晰） */
    private TileOverlay tileOverlay;

    public MapController(MethodChannel methodChannel, TextureMapView mapView) {
        this.methodChannel = methodChannel;
        this.mapView = mapView;
        amap = mapView.getMap();

        amap.addOnMapLoadedListener(this);
        amap.addOnMyLocationChangeListener(this);
        amap.addOnCameraChangeListener(this);
        amap.addOnMapLongClickListener(this);
        amap.addOnMapClickListener(this);
        amap.addOnPOIClickListener(this);
    }

    @Override
    public String[] getRegisterMethodIdArray() {
        return Const.METHOD_ID_LIST_FOR_MAP;
    }

    @Override
    public void doMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        LogUtil.i(CLASS_NAME, "doMethodCall===>" + call.method);
        if (null == amap) {
            LogUtil.w(CLASS_NAME, "onMethodCall amap is null!!!");
            return;
        }
        switch (call.method) {
            case Const.METHOD_MAP_WAIT_FOR_MAP:
                if (mapLoaded) {
                    result.success(null);
                    return;
                }
                mapReadyResult = result;
                break;
            case Const.METHOD_MAP_SATELLITE_IMAGE_APPROVAL_NUMBER:
                result.success(amap.getSatelliteImageApprovalNumber());
                break;
            case Const.METHOD_MAP_CONTENT_APPROVAL_NUMBER:
                result.success(amap.getMapContentApprovalNumber());
                break;
            case Const.METHOD_MAP_UPDATE:
                ConvertUtil.interpretAMapOptions(call.argument("options"), this);
                result.success(ConvertUtil.cameraPositionToMap(getCameraPosition()));
                break;
            case Const.METHOD_MAP_MOVE_CAMERA:
                final CameraUpdate cameraUpdate = ConvertUtil.toCameraUpdate(call.argument("cameraUpdate"));
                final Object animatedObject = call.argument("animated");
                final Object durationObject = call.argument("duration");

                moveCamera(cameraUpdate, animatedObject, durationObject);
                break;
            case Const.METHOD_MAP_SET_RENDER_FPS:
                amap.setRenderFps((Integer) call.argument("fps"));
                result.success(null);
                break;
            case Const.METHOD_MAP_TAKE_SNAPSHOT:
                final MethodChannel.Result _result = result;
                amap.getMapScreenShot(new AMap.OnMapScreenShotListener() {
                    @Override
                    public void onMapScreenShot(Bitmap bitmap) {
                        ByteArrayOutputStream stream = new ByteArrayOutputStream();
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream);
                        byte[] byteArray = stream.toByteArray();
                        bitmap.recycle();
                        _result.success(byteArray);
                    }

                    @Override
                    public void onMapScreenShot(Bitmap bitmap, int i) {

                    }
                });
                break;
            case Const.METHOD_MAP_CLEAR_DISK:
                amap.removecache();
                result.success(null);
                break;
            case Const.METHOD_MAP_TO_SCREEN_COORDINATE:
                LatLng argLatLng = ConvertUtil.toLatLng(call.arguments);
                Point resScreenLocation = amap.getProjection().toScreenLocation(argLatLng);
                result.success(ConvertUtil.pointToJson(resScreenLocation));
                break;
            case Const.METHOD_MAP_FROM_SCREEN_COORDINATE:
                Point argPoint = ConvertUtil.pointFromMap(call.arguments);
                LatLng resLatLng = amap.getProjection().fromScreenLocation(argPoint);
                result.success(ConvertUtil.latLngToList(resLatLng));
                break;
            case Const.METHOD_MAP_GROUND_OVERLAY:
                // 天气叠加：把一张 PNG 按经纬度范围贴到地图上（云图/雷达图）
                setGroundOverlay(
                        call.argument("image"),
                        call.argument("southwest"),
                        call.argument("northeast"),
                        call.argument("transparency"));
                result.success(null);
                break;
            case Const.METHOD_MAP_REMOVE_GROUND_OVERLAY:
                removeGroundOverlay();
                result.success(null);
                break;
            case Const.METHOD_MAP_TILE_OVERLAY:
                // 瓦片式叠加：按 z/x/y 请求图片，任意缩放都清晰
                setTileOverlay(call.argument("urlTemplate"), call.argument("transparency"));
                result.success(null);
                break;
            case Const.METHOD_MAP_REMOVE_TILE_OVERLAY:
                removeTileOverlay();
                result.success(null);
                break;
            default:
                LogUtil.w(CLASS_NAME, "onMethodCall not find methodId:" + call.method);
                break;
        }

    }

    /**
     * 设置天气叠加图片层（云图/雷达图）
     *
     * 把一张 PNG（Flutter 侧按网格数据插值渲染好的平滑位图）
     * 按西南/东北角经纬度范围贴到地图上 —— 只占 1 个图层，性能极好。
     *
     * @param imageBytes    PNG 字节数组
     * @param southwestMap  西南角 {latitude, longitude}
     * @param northeastMap  东北角 {latitude, longitude}
     * @param transparency  透明度 0~1（0 = 不透明）
     */
    @SuppressWarnings("unchecked")
    public void setGroundOverlay(Object imageBytes, Object southwestMap, Object northeastMap, Object transparency) {
        if (amap == null || imageBytes == null || southwestMap == null || northeastMap == null) {
            return;
        }
        try {
            byte[] bytes = (byte[]) imageBytes;
            Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            if (bitmap == null) {
                LogUtil.w(CLASS_NAME, "setGroundOverlay decode failed");
                return;
            }

            if (groundOverlay != null) {
                groundOverlay.remove();
                groundOverlay = null;
            }

            // 注意：Dart 侧 LatLng.toJson() 返回的是 [lat, lon] 列表，不是 Map
            List<?> swList = (List<?>) southwestMap;
            List<?> neList = (List<?>) northeastMap;
            LatLng sw = new LatLng(
                    ((Number) swList.get(0)).doubleValue(),
                    ((Number) swList.get(1)).doubleValue());
            LatLng ne = new LatLng(
                    ((Number) neList.get(0)).doubleValue(),
                    ((Number) neList.get(1)).doubleValue());

            float t = transparency == null ? 0f : ((Number) transparency).floatValue();
            GroundOverlayOptions options = new GroundOverlayOptions()
                    .image(BitmapDescriptorFactory.fromBitmap(bitmap))
                    .positionFromBounds(new LatLngBounds(sw, ne))
                    .transparency(t);
            groundOverlay = amap.addGroundOverlay(options);
            LogUtil.i(CLASS_NAME, "setGroundOverlay success");
        } catch (Throwable e) {
            LogUtil.e(CLASS_NAME, "setGroundOverlay", e);
        }
    }

    /** 移除天气叠加层 */
    public void removeGroundOverlay() {
        try {
            if (groundOverlay != null) {
                groundOverlay.remove();
                groundOverlay = null;
            }
        } catch (Throwable e) {
            LogUtil.e(CLASS_NAME, "removeGroundOverlay", e);
        }
    }

    /**
     * 设置瓦片式叠加层（按 z/x/y 请求图片）
     *
     * 相比 GroundOverlay 的单张图片拉伸，瓦片在**任意缩放级别都清晰**，
     * 适合雷达/卫星等需要放大的叠加数据源。
     *
     * @param urlTemplate  形如 https://host/path/{z}/{x}/{y}.png
     * @param transparency 0~1（0 = 不透明）
     */
    public void setTileOverlay(Object urlTemplate, Object transparency) {
        if (amap == null || urlTemplate == null) {
            return;
        }
        try {
            final String template = urlTemplate.toString();
            if (tileOverlay != null) {
                tileOverlay.remove();
                tileOverlay = null;
            }

            UrlTileProvider provider = new UrlTileProvider(256, 256) {
                @Override
                public URL getTileUrl(int x, int y, int zoom) {
                    try {
                        String url = template
                                .replace("{x}", String.valueOf(x))
                                .replace("{y}", String.valueOf(y))
                                .replace("{z}", String.valueOf(zoom));
                        return new URL(url);
                    } catch (Throwable e) {
                        return null;
                    }
                }
            };
            // 注意：高德的 TileOverlayOptions **没有** transparency() 方法
            // （只有 GroundOverlayOptions 有）。好在雷达瓦片自身就是透明的
            // （仅回波像素有颜色），因此无需额外控制透明度。
            TileOverlayOptions options = new TileOverlayOptions()
                    .tileProvider(provider)
                    .zIndex(1f);
            tileOverlay = amap.addTileOverlay(options);
            LogUtil.i(CLASS_NAME, "setTileOverlay success");
        } catch (Throwable e) {
            LogUtil.e(CLASS_NAME, "setTileOverlay", e);
        }
    }

    /** 移除瓦片叠加层 */
    public void removeTileOverlay() {
        try {
            if (tileOverlay != null) {
                tileOverlay.remove();
                tileOverlay = null;
            }
        } catch (Throwable e) {
            LogUtil.e(CLASS_NAME, "removeTileOverlay", e);
        }
    }

    @Override
    public void onMapLoaded() {        LogUtil.i(CLASS_NAME, "onMapLoaded==>");
        try {
            mapLoaded = true;
            if (null != mapReadyResult) {
                mapReadyResult.success(null);
                mapReadyResult = null;
            }
        } catch (Throwable e) {
            LogUtil.e(CLASS_NAME, "onMapLoaded", e);
        }
    }

    @Override
    public void setCamera(CameraPosition camera) {
        amap.moveCamera(CameraUpdateFactory.newCameraPosition(camera));
    }

    @Override
    public void setMapType(int mapType) {
        amap.setMapType(mapType);
    }

    @Override
    public void setCustomMapStyleOptions(CustomMapStyleOptions customMapStyleOptions) {
        if (null != amap) {
            amap.setCustomMapStyle(customMapStyleOptions);
        }
    }

    @Override
    public void setMyLocationStyle(MyLocationStyle myLocationStyle) {
        if (null != amap) {
            myLocationShowing = myLocationStyle.isMyLocationShowing();
            amap.setMyLocationEnabled(myLocationShowing);
            amap.setMyLocationStyle(myLocationStyle);
        }
    }

    @Override
    public void setScreenAnchor(float x, float y) {
        amap.setPointToCenter(Float.valueOf(mapView.getWidth() * x).intValue(), Float.valueOf(mapView.getHeight() * y).intValue());
    }

    @Override
    public void setMinZoomLevel(float minZoomLevel) {
        amap.setMinZoomLevel(minZoomLevel);
    }

    @Override
    public void setMaxZoomLevel(float maxZoomLevel) {
        amap.setMaxZoomLevel(maxZoomLevel);
    }

    @Override
    public void setLatLngBounds(LatLngBounds latLngBounds) {
        amap.setMapStatusLimits(latLngBounds);
    }

    @Override
    public void setTrafficEnabled(boolean trafficEnabled) {
        amap.setTrafficEnabled(trafficEnabled);
    }

    @Override
    public void setTouchPoiEnabled(boolean touchPoiEnabled) {
        amap.setTouchPoiEnable(touchPoiEnabled);
    }

    @Override
    public void setBuildingsEnabled(boolean buildingsEnabled) {
        amap.showBuildings(buildingsEnabled);
    }

    @Override
    public void setLabelsEnabled(boolean labelsEnabled) {
        amap.showMapText(labelsEnabled);
    }

    @Override
    public void setCompassEnabled(boolean compassEnabled) {
        amap.getUiSettings().setCompassEnabled(compassEnabled);
    }

    @Override
    public void setScaleEnabled(boolean scaleEnabled) {
        amap.getUiSettings().setScaleControlsEnabled(scaleEnabled);
    }

    @Override
    public void setZoomGesturesEnabled(boolean zoomGesturesEnabled) {
        amap.getUiSettings().setZoomGesturesEnabled(zoomGesturesEnabled);
    }

    @Override
    public void setScrollGesturesEnabled(boolean scrollGesturesEnabled) {
        amap.getUiSettings().setScrollGesturesEnabled(scrollGesturesEnabled);
    }

    @Override
    public void setRotateGesturesEnabled(boolean rotateGesturesEnabled) {
        amap.getUiSettings().setRotateGesturesEnabled(rotateGesturesEnabled);
    }

    @Override
    public void setTiltGesturesEnabled(boolean tiltGesturesEnabled) {
        amap.getUiSettings().setTiltGesturesEnabled(tiltGesturesEnabled);
    }

    private CameraPosition getCameraPosition() {
        if (null != amap) {
            return amap.getCameraPosition();
        }
        return null;
    }

    @Override
    public void onMyLocationChange(Location location) {
        if (null != methodChannel && myLocationShowing) {
            final Map<String, Object> arguments = new HashMap<String, Object>(2);
            arguments.put("location", ConvertUtil.location2Map(location));
            methodChannel.invokeMethod("location#changed", arguments);
            LogUtil.i(CLASS_NAME, "onMyLocationChange===>" + arguments);
        }
    }

    @Override
    public void onCameraChange(CameraPosition cameraPosition) {
        if (null != methodChannel) {
            final Map<String, Object> arguments = new HashMap<String, Object>(2);
            arguments.put("position", ConvertUtil.cameraPositionToMap(cameraPosition));
            methodChannel.invokeMethod("camera#onMove", arguments);
            LogUtil.i(CLASS_NAME, "onCameraChange===>" + arguments);
        }
    }

    @Override
    public void onCameraChangeFinish(CameraPosition cameraPosition) {
        if (null != methodChannel) {
            final Map<String, Object> arguments = new HashMap<String, Object>(2);
            arguments.put("position", ConvertUtil.cameraPositionToMap(cameraPosition));
            methodChannel.invokeMethod("camera#onMoveEnd", arguments);
            LogUtil.i(CLASS_NAME, "onCameraChangeFinish===>" + arguments);
        }
    }


    @Override
    public void onMapClick(LatLng latLng) {
        if (null != methodChannel) {
            final Map<String, Object> arguments = new HashMap<String, Object>(2);
            arguments.put("latLng", ConvertUtil.latLngToList(latLng));
            methodChannel.invokeMethod("map#onTap", arguments);
            LogUtil.i(CLASS_NAME, "onMapClick===>" + arguments);
        }
    }

    @Override
    public void onMapLongClick(LatLng latLng) {
        if (null != methodChannel) {
            final Map<String, Object> arguments = new HashMap<String, Object>(2);
            arguments.put("latLng", ConvertUtil.latLngToList(latLng));
            methodChannel.invokeMethod("map#onLongPress", arguments);
            LogUtil.i(CLASS_NAME, "onMapLongClick===>" + arguments);
        }
    }

    @Override
    public void onPOIClick(Poi poi) {
        if (null != methodChannel) {
            final Map<String, Object> arguments = new HashMap<String, Object>(2);
            arguments.put("poi", ConvertUtil.poiToMap(poi));
            methodChannel.invokeMethod("map#onPoiTouched", arguments);
            LogUtil.i(CLASS_NAME, "onPOIClick===>" + arguments);
        }
    }

    private void moveCamera(CameraUpdate cameraUpdate, Object animatedObject, Object durationObject) {
        boolean animated = false;
        long duration = 250;
        if (null != animatedObject) {
            animated = (Boolean) animatedObject;
        }
        if (null != durationObject) {
            duration = ((Number) durationObject).intValue();
        }
        if (null != amap) {
            if (animated) {
                amap.animateCamera(cameraUpdate, duration, null);
            } else {
                amap.moveCamera(cameraUpdate);
            }
        }
    }

    @Override
    public void setInitialMarkers(Object initialMarkers) {
        //不实现
    }

    @Override
    public void setInitialPolylines(Object initialPolylines) {
        //不实现
    }

    @Override
    public void setInitialPolygons(Object polygonsObject) {
        //不实现
    }

    @Override
    public void setMapLanguage(String mapLanguage) {
        if (null != amap) {
            amap.setMapLanguage(mapLanguage);
        }
    }


    @Override
    public void setLogoPosition(int logoPosition) {
        if (null != amap) {
            amap.getUiSettings().setLogoPosition(logoPosition);
        }
    }

    @Override
    public int getLogoPosition() {
        return null != amap ? amap.getUiSettings().getLogoPosition() : 0;
    }

    @Override
    public void setLogoBottomMargin(int pixels) {
        if (null != amap) {
            amap.getUiSettings().setLogoBottomMargin(pixels);
        }
    }

    @Override
    public void setLogoLeftMargin(int pixels) {
        if (null != amap) {
            amap.getUiSettings().setLogoLeftMargin(pixels);
        }
    }
}
