import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../models/hourly_weather.dart';
import '../services/amap_service.dart';
import '../services/open_meteo.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart' show ScreenScaffold, PanelCard;

/// 地点查询结果：方圆区域天气
class _AreaResult {
  final String placeName;
  final GeoPoint center;
  final List<({String label, GeoPoint point, HourlyWeather? weather})> samples;
  final double? minTemp;
  final double? maxTemp;
  final int? maxPop; // 最高降水概率

  const _AreaResult({
    required this.placeName,
    required this.center,
    required this.samples,
    this.minTemp,
    this.maxTemp,
    this.maxPop,
  });
}

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

  @override
  void dispose() {
    _input.dispose();
    _amap.dispose();
    _meteo.dispose();
    super.dispose();
  }

  /// 用当前位置
  Future<void> _useCurrent() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw Exception('未授予定位权限，请在系统设置中开启');
      }

      // 定位策略（天气查询只需公里级精度，不强求 GPS）：
      // 1) 低精度系统定位（WiFi/基站网络定位）
      // 2) 退回「最后已知位置」
      // 3) 仍失败 → **IP 定位兜底**（免 GPS、免权限，只要有网就能拿城市级位置）
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low, // 网络定位，不强制 GPS
            timeLimit: Duration(seconds: 10),
          ),
        );
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
      }

      if (pos != null) {
        await _analyze(GeoPoint(lat: pos.latitude, lon: pos.longitude, name: '当前位置'));
        return;
      }

      // 系统定位全失败 → IP 定位兜底
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
    // 4 个方位点，距中心约 5km（纬度 1° ≈ 111km，经度按纬度修正）
    const d = 5.0 / 111.0;
    final dLon = d / (1000 * (center.lat.abs() / 90 * 0.7 + 0.3));
    final points = <({String label, GeoPoint point})>[
      (label: '中心', point: center),
      (label: '北 5km', point: GeoPoint(lat: center.lat + d, lon: center.lon)),
      (label: '南 5km', point: GeoPoint(lat: center.lat - d, lon: center.lon)),
      (label: '东 5km', point: GeoPoint(lat: center.lat, lon: center.lon + dLon)),
      (label: '西 5km', point: GeoPoint(lat: center.lat, lon: center.lon - dLon)),
    ];

    final forecasts = await _meteo.fetchMany(
      points.map((p) => (lat: p.point.lat, lon: p.point.lon, place: p.label)).toList(),
      forecastDays: 2,
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

    setState(() {
      _loading = false;
      _result = _AreaResult(
        placeName: center.name.isEmpty ? '所选位置' : center.name,
        center: center,
        samples: samples,
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
      const PanelCard(
        heading: '地图',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text('高德地图接入中…',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textFaint)),
          ),
        ),
      ),
    ];
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
