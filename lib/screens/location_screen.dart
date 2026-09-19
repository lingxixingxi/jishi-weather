import 'dart:async';
import 'dart:math' as math;

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../models/hourly_weather.dart';
import '../services/amap_location_service.dart';
import '../services/amap_service.dart';
import '../services/open_meteo.dart';
import '../theme/app_theme.dart';
import '../widgets/amap_view.dart';
import 'home_screen.dart' show ScreenScaffold, PanelCard;

/// 地点查询结果：方圆区域天气
class _AreaResult {
  final String placeName;
  final GeoPoint center;
  final List<({String label, GeoPoint point, HourlyWeather? weather})> samples;
  final double? minTemp;
  final double? maxTemp;
  final int? maxPop; // 最高降水概率

  /// 预生成的地图标注（带文字，Marker 不支持常驻文字故自绘）
  final List<Marker> markers;

  const _AreaResult({
    required this.placeName,
    required this.center,
    required this.samples,
    required this.markers,
    this.minTemp,
    this.maxTemp,
    this.maxPop,
  });
}

/// 地图叠加图层模式
enum _LayerMode { none, cloud, rain }

/// 地点查询页 —— 方圆 10km 区域天气
class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  final _input = TextEditingController(text: '上海虹桥站');
  final _amap = AmapService();
  final _meteo = OpenMeteoService();

  bool _loading = false;
  String? _error;
  _AreaResult? _result;

  // ===== 叠加图层：网格数据 + 模式 + 时间轴 =====
  List<GridPoint> _grid = const [];
  final int _gridN = 5;
  _LayerMode _layerMode = _LayerMode.cloud;
  int _timeIndex = 0;
  bool _playing = false;
  Timer? _animTimer;

  @override
  void dispose() {
    _animTimer?.cancel();
    _input.dispose();
    _amap.dispose();
    _meteo.dispose();
    super.dispose();
  }

  /// 网格各时刻的数量（用于时间轴范围）
  int get _timeCount => _grid.isEmpty ? 0 : _grid.first.length;

  /// 用当前位置
  ///
  /// **并行竞速**定位（避免逐级串行等待导致慢）：
  /// · 高德定位（WiFi+基站+GPS）与系统定位**同时启动**
  /// · 高德优先：8 秒内返回就用它（最准）
  /// · 高德没回来 → 用已并行跑着的系统定位结果
  /// · 都失败 → IP 定位兜底（1-2 秒）
  Future<void> _useCurrent() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 同时启动两条定位链路
      final amapFuture = AmapLocationService.locate(timeout: const Duration(seconds: 6));
      final geoFuture = _locateBySystem(timeout: const Duration(seconds: 6));

      // 高德优先；未回来则用系统定位（已在并行跑）
      final amapPoint = await amapFuture;
      final point = amapPoint ?? await geoFuture;

      if (point != null) {
        await _analyze(point);
        return;
      }

      // 最后兜底：IP 定位
      final ipPoint = await _amap.ipLocation();
      if (ipPoint != null) {
        await _analyze(ipPoint);
        return;
      }
      throw Exception('定位失败：请开启系统「位置信息」，或直接输入地点');
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 系统定位（geolocator）
  ///
  /// ⚠️ 关键：必须 `forceLocationManager: true`
  /// geolocator 默认走 Google FusedLocationProvider（fused provider），
  /// 但小米等国内设备的 fused provider 常为空 → 定位永远失败。
  /// 强制走系统原生 LocationManager 后，可直接使用 network provider
  /// （实测由高德提供，精度 ~30 米，室内可用）。
  Future<GeoPoint?> _locateBySystem({required Duration timeout}) async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm != LocationPermission.whileInUse && perm != LocationPermission.always) {
        return null;
      }

      final settings = AndroidSettings(
        accuracy: LocationAccuracy.low, // 网络定位，不强制 GPS
        forceLocationManager: true, // ← 绕开 fused，用系统 LocationManager
        timeLimit: timeout,
      );

      try {
        final pos = await Geolocator.getCurrentPosition(locationSettings: settings);
        return GeoPoint(lat: pos.latitude, lon: pos.longitude, name: '当前位置');
      } catch (_) {
        final last = await Geolocator.getLastKnownPosition();
        if (last == null) return null;
        return GeoPoint(lat: last.latitude, lon: last.longitude, name: '当前位置');
      }
    } catch (_) {
      return null;
    }
  }

  /// 按地名查询
  Future<void> _searchByName() async {
    final q = _input.text.trim();
    if (q.isEmpty) {
      setState(() => _error = '请输入地点名称');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await _amap.geocode(q);
      if (p == null) throw Exception('未找到该地点：$q');
      await _analyze(p);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 核心：中心点 + 4 方位采样（约 5km）→ 拉天气 → 汇总
  Future<void> _analyze(GeoPoint center) async {
    // 4 个方位点，距中心 5km
    // 纬度 1° ≈ 111km；经度 1° ≈ 111km × cos(纬度)（高纬处经线间距变小）
    const dLat = 5.0 / 111.0;
    final dLon = dLat / math.cos(center.lat * math.pi / 180.0).abs().clamp(0.2, 1.0);
    final points = <({String label, GeoPoint point})>[
      (label: '中心', point: center),
      (label: '北 5km', point: GeoPoint(lat: center.lat + dLat, lon: center.lon)),
      (label: '南 5km', point: GeoPoint(lat: center.lat - dLat, lon: center.lon)),
      (label: '东 5km', point: GeoPoint(lat: center.lat, lon: center.lon + dLon)),
      (label: '西 5km', point: GeoPoint(lat: center.lat, lon: center.lon - dLon)),
    ];

    final forecasts = await _meteo.fetchMany(
      points.map((p) => (lat: p.point.lat, lon: p.point.lon, place: p.label)).toList(),
      forecastDays: 1, // 只取当天，减小响应体积
    );

    final now = DateTime.now();
    final samples = <({String label, GeoPoint point, HourlyWeather? weather})>[];
    final temps = <double>[];
    int? maxPop;

    for (var i = 0; i < points.length; i++) {
      final w = _nearest(forecasts[i], now);
      samples.add((label: points[i].label, point: points[i].point, weather: w));
      final t = w?.temperature;
      if (t != null) temps.add(t);
      final pop = w?.precipitationProbability;
      if (pop != null) {
        maxPop = (maxPop == null || pop > maxPop) ? pop : maxPop;
      }
    }

    // 生成「带文字」的标注：直接标出方位 + 温度（无需点击即可读）
    final markers = <Marker>[];
    for (final s in samples) {
      final w = s.weather;
      final isCenter = s.label == '中心';
      final tempText = w?.temperature == null ? '--' : '${w!.temperature!.round()}°';
      markers.add(Marker(
        position: LatLng(s.point.lat, s.point.lon),
        icon: await buildLabelIcon(
          text: '${s.label} $tempText',
          color: isCenter ? AppTheme.accent : AppTheme.cyan,
          textColor: isCenter ? const Color(0xFF14100A) : Colors.white,
          fontSize: 17, // 放大地图标签（原来 12 太小看不清）
        ),
        infoWindow: InfoWindow(
          title: s.label,
          snippet: w == null
              ? '无数据'
              : '${w.weatherText ?? ''} ${w.temperature?.toStringAsFixed(1) ?? '--'}° '
                  '降水${w.precipitationProbability ?? '--'}%',
        ),
      ));
    }

    // 网格数据（云量+雨量逐小时，用于叠加图层与时间轴动画）
    var grid = const <GridPoint>[];
    try {
      grid = await _meteo.fetchGrid(
        centerLat: center.lat,
        centerLon: center.lon,
        spanKm: 24,
        n: _gridN,
      );
      debugPrint('[网格] 点数=${grid.length} 时刻数=${grid.isEmpty ? 0 : grid.first.length}');
    } catch (e) {
      debugPrint('[网格] 失败: $e');
    }

    // 时间轴默认定位到「当前小时」（数据含过去 24h + 未来 24h）
    var startIdx = 0;
    if (grid.isNotEmpty) {
      final times = grid.first.times;
      final now = DateTime.now();
      final target = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}T${now.hour.toString().padLeft(2, '0')}:00';
      final idx = times.indexOf(target);
      startIdx = idx >= 0 ? idx : (24 + now.hour).clamp(0, math.max(0, times.length - 1));
    }

    setState(() {
      _grid = grid;
      _timeIndex = startIdx;
      _playing = false;
      _animTimer?.cancel();
      _loading = false;
      _result = _AreaResult(
        placeName: center.name.isEmpty ? '所选位置' : center.name,
        center: center,
        samples: samples,
        markers: markers,
        minTemp: temps.isEmpty ? null : temps.reduce((a, b) => a < b ? a : b),
        maxTemp: temps.isEmpty ? null : temps.reduce((a, b) => a > b ? a : b),
        maxPop: maxPop,
      );
    });
  }

  HourlyWeather? _nearest(List<HourlyWeather> list, DateTime t) {
    if (list.isEmpty) return null;
    HourlyWeather? best;
    var bestDiff = 1 << 30;
    for (final w in list) {
      final d = (w.time.difference(t).inMinutes).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = w;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: '地点查询',
      subtitle: '方圆 10km 区域天气 · 多地采样交叉验证',
      children: [
        PanelCard(
          heading: '查询地点',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _input,
                style: const TextStyle(color: AppTheme.text, fontSize: 14.5),
                decoration: const InputDecoration(
                  hintText: '输入地点，如：上海市静安区',
                  prefixIcon: Icon(Icons.search, size: 20, color: AppTheme.textDim),
                ),
                onSubmitted: (_) => _searchByName(),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _loading ? null : _searchByName,
                      child: _loading
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF14100A)))
                          : const Text('查询天气'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _useCurrent,
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text('当前位置'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.accent,
                      side: const BorderSide(color: AppTheme.accent),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: AppTheme.red, fontSize: 12.5)),
              ],
            ],
          ),
        ),
        if (_result != null) ..._resultWidgets(_result!),
      ],
    );
  }

  List<Widget> _resultWidgets(_AreaResult r) {
    return [
      PanelCard(
        heading: '区域概览',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.placeName,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.text)),
            const SizedBox(height: 2),
            Text('${r.center.lat.toStringAsFixed(4)}, ${r.center.lon.toStringAsFixed(4)}',
                style: const TextStyle(fontSize: 11.5, color: AppTheme.textFaint)),
            const SizedBox(height: 14),
            Row(
              children: [
                _metric('最高温', r.maxTemp == null ? '—' : '${r.maxTemp!.toStringAsFixed(1)}°'),
                _metric('最低温', r.minTemp == null ? '—' : '${r.minTemp!.toStringAsFixed(1)}°'),
                _metric('降水概率', r.maxPop == null ? '—' : '${r.maxPop}%'),
              ],
            ),
          ],
        ),
      ),
      PanelCard(
        heading: '采样点明细（中心 + 4 方位）',
        child: Column(
          children: r.samples.map((s) => _sampleRow(s)).toList(),
        ),
      ),
      PanelCard(
        heading: '地图 · 天气叠加',
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ===== 图层切换 =====
            Row(
              children: [
                _layerChip('关闭', _LayerMode.none),
                const SizedBox(width: 6),
                _layerChip('云量', _LayerMode.cloud),
                const SizedBox(width: 6),
                _layerChip('雨量', _LayerMode.rain),
                const Spacer(),
                if (_layerMode != _LayerMode.none && _timeCount > 0)
                  Text(_timeLabel,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppTheme.accent, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 300,
                child: AmapView(
                  lat: r.center.lat,
                  lon: r.center.lon,
                  zoom: 11.5,
                  markers: r.markers, // 带文字标注
                  polygons: _layerPolygons(), // 云量/雨量热力格
                  interactive: true,
                ),
              ),
            ),
            // ===== 时间轴（看云/雨往哪飘）=====
            if (_layerMode != _LayerMode.none && _timeCount > 0) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  InkWell(
                    onTap: _togglePlay,
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: AppTheme.accentDim,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppTheme.accent),
                      ),
                      child: Icon(_playing ? Icons.pause : Icons.play_arrow,
                          size: 18, color: AppTheme.accent),
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                        activeTrackColor: AppTheme.accent,
                        inactiveTrackColor: AppTheme.border,
                        thumbColor: AppTheme.accent,
                      ),
                      child: Slider(
                        value: _timeIndex.toDouble().clamp(
                            0, math.max(0, _timeCount - 1).toDouble()),
                        min: 0,
                        max: math.max(1, _timeCount - 1).toDouble(),
                        divisions: _timeCount > 1 ? _timeCount - 1 : null,
                        onChanged: (v) {
                          _animTimer?.cancel();
                          setState(() {
                            _timeIndex = v.round();
                            _playing = false;
                          });
                        },
                      ),
                    ),
                  ),
                ],
              ),
              _layerLegend(),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _layerChip(String label, _LayerMode mode) {
    final on = _layerMode == mode;
    return InkWell(
      onTap: () {
        _animTimer?.cancel();
        setState(() {
          _layerMode = mode;
          _playing = false;
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: on ? AppTheme.accentDim : AppTheme.bgInset,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: on ? AppTheme.accent : AppTheme.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: on ? AppTheme.accent : AppTheme.textDim,
          ),
        ),
      ),
    );
  }

  /// 图层图例（色阶说明）
  Widget _layerLegend() {
    final items = _layerMode == _LayerMode.cloud
        ? [
            (const Color(0x2EECF1FC), '少云'),
            (const Color(0x80ECF1FC), '多云'),
            (const Color(0xCCECF1FC), '阴'),
          ]
        : [
            (const Color(0x994FC3F7), '小雨'),
            (const Color(0xBB2979FF), '中雨'),
            (const Color(0xDD7C4DFF), '大雨'),
            (const Color(0xEEB388FF), '暴雨'),
          ];
    return Padding(
      padding: const EdgeInsets.only(top: 2, left: 4),
      child: Row(
        children: [
          for (final it in items) ...[
            Container(
              width: 16,
              height: 9,
              decoration: BoxDecoration(
                color: it.$1,
                border: Border.all(color: AppTheme.borderSoft),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 4),
            Text(it.$2, style: const TextStyle(fontSize: 10, color: AppTheme.textFaint)),
            const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }

  /// 当前图层模式 + 当前时刻对应的热力格
  List<Polygon> _layerPolygons() {
    if (_layerMode == _LayerMode.none || _grid.isEmpty) return const [];
    final n = _gridN;
    final t = _timeIndex.clamp(0, math.max(0, _timeCount - 1)).toInt();
    final polys = <Polygon>[];

    for (var r = 0; r < n - 1; r++) {
      for (var c = 0; c < n - 1; c++) {
        final p00 = _grid[r * n + c];
        final p01 = _grid[r * n + c + 1];
        final p11 = _grid[(r + 1) * n + c + 1];
        final p10 = _grid[(r + 1) * n + c];

        final value = _layerMode == _LayerMode.cloud ? p00.cloudAt(t) : p00.rainAt(t);
        if (value == null) continue;
        final color = _layerMode == _LayerMode.cloud ? _cloudColor(value) : _rainColor(value);
        if (color.a == 0) continue;

        polys.add(Polygon(
          points: [
            LatLng(p00.lat, p00.lon),
            LatLng(p01.lat, p01.lon),
            LatLng(p11.lat, p11.lon),
            LatLng(p10.lat, p10.lon),
          ],
          strokeWidth: 0.1,
          strokeColor: Colors.transparent,
          fillColor: color,
        ));
      }
    }
    return polys;
  }

  /// 云量(0-100) → 颜色：云越厚越白越不透明（已加强可见度）
  Color _cloudColor(double cloud) {
    final a = (0.18 + cloud / 100.0 * 0.62).clamp(0.0, 0.8);
    return Color.fromRGBO(236, 241, 252, a);
  }

  /// 雨量(mm/h) → 颜色：小雨蓝 → 中雨深蓝 → 大雨紫 → 暴雨亮紫
  Color _rainColor(double rain) {
    if (rain < 0.1) return const Color(0x00000000);
    if (rain < 2.5) return const Color(0x994FC3F7);
    if (rain < 8.0) return const Color(0xBB2979FF);
    if (rain < 16.0) return const Color(0xDD7C4DFF);
    return const Color(0xEEB388FF);
  }

  /// 当前时刻标签（时间轴显示用）
  String get _timeLabel {
    if (_grid.isEmpty || _timeCount == 0) return '';
    final t = _timeIndex.clamp(0, _timeCount - 1);
    final raw = _grid.first.times;
    if (t < raw.length && raw[t].length >= 13) {
      return raw[t].substring(5, 16).replaceFirst('T', ' '); // MM-DD HH:mm
    }
    return '第 $t 小时';
  }

  /// 播放/暂停时间轴动画（看云/雨往哪飘）
  void _togglePlay() {
    if (_timeCount == 0) return;
    setState(() => _playing = !_playing);
    _animTimer?.cancel();
    if (!_playing) return;
    _animTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted) return;
      setState(() {
        _timeIndex = (_timeIndex + 1) % _timeCount;
      });
    });
  }

  Widget _metric(String k, String v) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: const TextStyle(fontSize: 11, color: AppTheme.textFaint)),
          const SizedBox(height: 3),
          Text(v, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: AppTheme.text)),
        ],
      ),
    );
  }

  Widget _sampleRow(({String label, GeoPoint point, HourlyWeather? weather}) s) {
    final w = s.weather;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(s.label,
                style: const TextStyle(fontSize: 12.5, color: AppTheme.textDim, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text(w?.weatherText ?? '无数据',
                style: const TextStyle(fontSize: 13, color: AppTheme.text)),
          ),
          Text(w?.temperature == null ? '—' : '${w!.temperature!.toStringAsFixed(1)}°',
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppTheme.text)),
          const SizedBox(width: 12),
          SizedBox(
            width: 54,
            child: Text(
              w?.precipitationProbability == null ? '—' : '${w!.precipitationProbability}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: (w?.precipitationProbability ?? 0) >= 50 ? AppTheme.cyan : AppTheme.textDim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
