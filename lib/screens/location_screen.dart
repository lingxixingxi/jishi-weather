import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../models/hourly_weather.dart';
import '../services/amap_location_service.dart';
import '../engine/radar_verdict.dart';
import '../models/hourly_weather.dart';
import '../services/amap_service.dart';
import '../services/multi_source_service.dart';
import '../services/nmc_city_repository.dart';
import '../services/nmc_service.dart';
import '../services/open_meteo.dart';
import '../services/radar_service.dart';
import '../services/rainviewer_service.dart';
import '../services/satellite_service.dart';
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

  /// 雷达定调判出的**最优源**展示名（中心点采用该源的值）
  final String? adoptedSource;

  /// 中心点最终采用的天气（最优源的值；null 表示用多源融合值）
  final HourlyWeather? centerWeather;

  const _AreaResult({
    required this.placeName,
    required this.center,
    required this.samples,
    required this.markers,
    this.minTemp,
    this.maxTemp,
    this.maxPop,
    this.adoptedSource,
    this.centerWeather,
  });

  /// 中心点生效的天气（优先最优源，否则取 samples 里的中心）
  HourlyWeather? get effectiveCenter {
    if (centerWeather != null) return centerWeather;
    for (final s in samples) {
      if (s.label == '中心') return s.weather;
    }
    return null;
  }

  /// 复制并覆盖采用源与中心天气
  _AreaResult copyWithSource(String? source, HourlyWeather? weather) => _AreaResult(
        placeName: placeName,
        center: center,
        samples: samples,
        markers: markers,
        minTemp: minTemp,
        maxTemp: maxTemp,
        maxPop: maxPop,
        adoptedSource: source,
        centerWeather: weather,
      );
}

/// 地图叠加图层模式
enum _LayerMode {
  none,

  /// 云量（Open-Meteo 网格插值）
  cloud,

  /// 雨量（Open-Meteo 网格插值）
  rain,

  /// 中央气象台官方雷达拼图（单图，缩小看全貌）
  radar,

  /// RainViewer 雷达瓦片（瓦片式，任意缩放都清晰）
  radarTile,

  /// 风云四号**卫星云图**（看云系，与雷达互补；分辨率粗，适合小比例尺）
  satellite,
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
  final _nmc = NmcService();
  late final NmcCityRepository _cityRepo = NmcCityRepository(_nmc, _amap);
  late final MultiSourceService _multi = MultiSourceService(
    meteo: _meteo,
    nmc: _nmc,
    cityRepo: _cityRepo,
  );

  /// 中心点的多源集合（5 源比对 + 雷达定调用）
  MultiModelHourly? _centerMulti;

  /// 雷达定调结果
  RadarVerdict? _verdict;
  bool _verdictLoading = false;

  /// 未来逐小时预测（取中心点）
  List<MultiModelHourly> _hourlyForecast = const [];

  /// 未来逐日预测
  List<DailyWeather> _dailyForecast = const [];

  bool _loading = false;
  String? _error;
  _AreaResult? _result;

  // ===== 叠加图层：网格数据 + 模式 + 时间轴 =====
  List<GridPoint> _grid = const [];
  final int _gridN = 9; // 9×9 网格（64 个热力格），比 5×5 细腻得多
  _LayerMode _layerMode = _LayerMode.cloud;
  int _timeIndex = 0;
  bool _playing = false;
  Timer? _animTimer;

  /// 已渲染好的叠加位图（PNG）—— 交给 GroundOverlay 贴图，仅 1 个图层
  Uint8List? _overlayPng;

  /// 雷达图层：真实雷达拼图（裁剪后的地图区 PNG）+ 其覆盖范围
  Uint8List? _radarPng;
  LatLng? _radarSw;
  LatLng? _radarNe;
  bool _radarLoading = false;
  String? _radarInfo;

  /// RainViewer 雷达瓦片（瓦片式，任意缩放清晰）
  final _rainViewer = RainViewerService();
  RainTileInfo? _rainTile;
  bool _tileLoading = false;

  /// 风云四号卫星云图（看云系）
  final _satellite = SatelliteService();
  Uint8List? _satellitePng;
  String? _satelliteInfo;
  bool _satelliteLoading = false;

  /// 当前地图缩放级别（由地图回调更新）
  ///
  /// RainViewer 免费版**最大只到 zoom 7**（z≥8 返回「Zoom Level Not
  /// Supported」占位图），所以瓦片层只在 zoom ≤ 7 时挂载。
  static const double _tileMaxZoom = 7;
  double _currentZoom = 11.5;

  bool get _tileUsable => _currentZoom <= _tileMaxZoom;

  /// 地图缩放级别
  ///
  /// 雷达拼图源分辨率有限（774px 覆盖约 2000km，1px≈2.6km），
  /// 放大地图时会变模糊 —— 这是数据源本身的限制，
  /// 因此**不自动修改用户的缩放**，只在界面上给出说明。
  double _mapZoom = 11.5;

  /// 重新渲染叠加位图（网格数据 → 平滑 PNG）
  Future<void> _regenerateOverlay() async {
    try {
      final png = await _renderOverlayPng();
      if (!mounted) return;
      setState(() => _overlayPng = png);
    } catch (e) {
      debugPrint('[叠加] 渲染失败: $e');
    }
  }

  /// 加载风云四号卫星云图（看云系，与雷达互补）
  Future<void> _loadSatellite() async {
    if (_satelliteLoading) return;
    setState(() => _satelliteLoading = true);
    try {
      final r = await _satellite.fetchLatest();
      if (!mounted) return;
      if (r == null) {
        setState(() {
          _satelliteLoading = false;
          _satelliteInfo = '卫星云图拉取失败';
        });
        return;
      }
      final png = await SatelliteService.normalize(r.bytes);
      if (!mounted) return;
      setState(() {
        _satellitePng = png;
        _satelliteInfo = '${r.time.month}/${r.time.day} '
            '${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')} · FY-4B 真彩色';
        _satelliteLoading = false;
      });
      debugPrint('[卫星云图] 已加载 ${png?.length ?? 0} 字节');
    } catch (e) {
      debugPrint('[卫星云图] 失败: $e');
      if (mounted) setState(() => _satelliteLoading = false);
    }
  }

  /// 加载 RainViewer 雷达瓦片（瓦片式，任意缩放清晰）
  Future<void> _loadRadarTile() async {
    if (_tileLoading) return;
    setState(() => _tileLoading = true);
    try {
      final info = await _rainViewer.latestRadar();
      if (!mounted) return;
      setState(() {
        _rainTile = info;
        _tileLoading = false;
        if (info != null) {
          final t = info.time.toLocal();
          _radarInfo = '${t.month}/${t.day} '
              '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} · RainViewer';
        }
      });
      debugPrint('[雷达瓦片] ${info?.urlTemplate ?? '失败'}');
    } catch (e) {
      debugPrint('[雷达瓦片] 失败: $e');
      if (mounted) setState(() => _tileLoading = false);
    }
  }

  /// 加载真实雷达拼图（中央气象台华东拼图）
  ///
  /// 流程：高德逆地理编码定位城市 → 取该市天气里的雷达图路径
  /// → 拉最新一帧 → 裁掉底部色标 → 用 RadarGeo 标定范围叠加。
  Future<void> _loadRadar(double lat, double lon) async {
    if (_radarLoading) return;
    setState(() => _radarLoading = true);
    try {
      final city = await _cityRepo.locate(lat, lon);
      if (city == null) {
        if (mounted) setState(() => _radarLoading = false);
        return;
      }
      final wx = await _nmc.weather(city.code, cityName: city.city);
      final path = wx.radarImagePath;
      if (path == null) {
        if (mounted) setState(() => _radarLoading = false);
        return;
      }
      final frames = await RadarService.fetchRecentFrames(radarPath: path, count: 1);
      if (frames.isEmpty) {
        if (mounted) setState(() => _radarLoading = false);
        return;
      }
      final cropped = await RadarService.cropToMapArea(frames.last.bytes);
      final b = RadarService.overlayBounds();
      if (!mounted) return;
      setState(() {
        _radarPng = cropped;
        _radarSw = LatLng(b.swLat, b.swLon);
        _radarNe = LatLng(b.neLat, b.neLon);
        final t = frames.last.time;
        _radarInfo = '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')} · ${wx.radarTitle ?? ''}';
        _radarLoading = false;
      });
      debugPrint('[雷达] 已加载 ${cropped?.length ?? 0} 字节');
    } catch (e) {
      debugPrint('[雷达] 加载失败: $e');
      if (mounted) setState(() => _radarLoading = false);
    }
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    _input.dispose();
    _amap.dispose();
    _meteo.dispose();
    _nmc.dispose();
    _rainViewer.dispose();
    _satellite.dispose();
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

    // 中心点走**多源融合**（5 源交叉验证 + 雷达定调），保留完整多源集合
    List<MultiModelHourly> centerMulti = const [];
    try {
      centerMulti = await _multi.fetch(
        lat: center.lat,
        lon: center.lon,
        place: center.name.isEmpty ? '中心' : center.name,
        forecastDays: 3, // 未来预测需要更多天数
      );
      debugPrint('[多源] 中心点 ${centerMulti.length} 个时刻，'
          '${centerMulti.isEmpty ? 0 : centerMulti.first.sources.length} 源');
    } catch (e) {
      debugPrint('[多源] 中心点失败: $e');
    }

    // 四方位点用单模型（省流量，只做方位差异对比）
    final others = points.where((p) => p.label != '中心').toList();
    var otherForecasts = <List<HourlyWeather>>[];
    try {
      otherForecasts = await _meteo.fetchMany(
        others.map((p) => (lat: p.point.lat, lon: p.point.lon, place: p.label)).toList(),
        forecastDays: 1,
      );
    } catch (e) {
      debugPrint('[单模型] 方位点失败: $e');
    }

    // 未来逐日预测（7 天）
    var daily = <DailyWeather>[];
    try {
      daily = await _meteo.fetchDaily(
        lat: center.lat,
        lon: center.lon,
        forecastDays: 7,
      );
    } catch (e) {
      debugPrint('[逐日] 失败: $e');
    }

    final now = DateTime.now();
    final samples = <({String label, GeoPoint point, HourlyWeather? weather})>[];
    final temps = <double>[];
    int? maxPop;

    // 中心点：用多源融合值
    final centerW = centerMulti.isEmpty
        ? _nearest(const [], now)
        : _nearest(
            centerMulti.map((m) => m.toHourlyWeather()).toList(),
            now,
          );
    samples.add((label: '中心', point: center, weather: centerW));
    if (centerW?.temperature != null) temps.add(centerW!.temperature!);
    if (centerW?.precipitationProbability != null) {
      maxPop = centerW!.precipitationProbability;
    }

    // 方位点：用单模型值
    for (var i = 0; i < others.length; i++) {
      final list = i < otherForecasts.length ? otherForecasts[i] : const <HourlyWeather>[];
      final w = _nearest(list, now);
      samples.add((label: others[i].label, point: others[i].point, weather: w));
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
          // 中心点常规字号；东西南北 4 个方位点放大一倍（原 17 -> 34）
          fontSize: isCenter ? 17 : 34,
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
      _overlayPng = null; // 换地点先清掉旧叠加
      // 多源与未来预测
      _centerMulti = centerMulti.isEmpty ? null : _nearestMulti(centerMulti, now);
      _hourlyForecast = centerMulti;
      _dailyForecast = daily;
      _verdict = null;
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

    // 雷达定调（异步，不阻塞）
    _runLocationVerdict(center, centerMulti);

    // 生成叠加位图（异步，不阻塞 UI）
    if (_layerMode != _LayerMode.none && grid.isNotEmpty) {
      _regenerateOverlay();
    }
  }

  /// 取最接近当前时刻的多源集合
  MultiModelHourly? _nearestMulti(List<MultiModelHourly> list, DateTime t) {
    if (list.isEmpty) return null;
    MultiModelHourly? best;
    var bestDiff = const Duration(days: 999).inMinutes;
    for (final m in list) {
      final d = m.time.difference(t).inMinutes.abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = m;
      }
    }
    return best;
  }

  /// 跑雷达定调（用中心点的实况与各源预测比对）
  Future<void> _runLocationVerdict(GeoPoint center, List<MultiModelHourly> multi) async {
    final path = _multi.lastRadarPath;
    final nowMulti = _nearestMulti(multi, DateTime.now());
    if (path == null || nowMulti == null) return;

    setState(() => _verdictLoading = true);
    try {
      final v = await RadarVerdictEngine.judge(
        lat: center.lat,
        lon: center.lon,
        models: [nowMulti],
        radarPath: path,
      );
      if (!mounted) return;
      setState(() {
        _verdict = v;
        _verdictLoading = false;
      });

      // 用雷达定调判出的**最优源**更新中心点显示（区域概览随之切换）
      if (v.bestModelKey != null && _result != null) {
        ModelForecast? src;
        for (final s in nowMulti.sources) {
          if (s.model == v.bestModelKey) {
            src = s;
            break;
          }
        }
        if (src != null) {
          final r = _result!;
          final eff = HourlyWeather(
            place: r.placeName,
            lat: center.lat,
            lon: center.lon,
            time: nowMulti.time,
            source: src.displayName,
            temperature: src.temperature,
            precipitationProbability: src.precipitationProbability,
            precipitation: src.precipitation,
            windSpeed: src.windSpeed,
            windDirection: src.windDirection,
            windGust: src.windGust,
            visibility: src.visibility,
            cloudCover: src.cloudCover,
            weatherCode: src.weatherCode,
            weatherText: src.weatherText,
          );
          setState(() {
            _result = r.copyWithSource(src!.displayName, eff);
          });
          debugPrint('[地点] 中心点改用最优源: ${src.displayName}');
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _verdictLoading = false);
    }
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

        // ===== 未来预测（紧跟地图，便于对着地图看趋势）=====
        if (_hourlyForecast.isNotEmpty || _dailyForecast.isNotEmpty) _forecastCard(),

        // ===== 多源交叉验证 + 雷达定调（与出行路线页同款逻辑）=====
        if (_centerMulti != null) _multiSourceCard(),
        if (_verdictLoading || _verdict != null) _radarVerdictCard(),
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
            Row(
              children: [
                Expanded(
                  child: Text(r.placeName,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.text)),
                ),
                if (r.adoptedSource != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.green.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppTheme.green.withValues(alpha: .45)),
                    ),
                    child: Text('采用 ${r.adoptedSource}',
                        style: const TextStyle(
                            fontSize: 10.5, color: AppTheme.green, fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text('${r.center.lat.toStringAsFixed(4)}, ${r.center.lon.toStringAsFixed(4)}',
                style: const TextStyle(fontSize: 11.5, color: AppTheme.textFaint)),
            // 中心点实况（雷达定调后改用最优源）
            if (r.effectiveCenter != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.place, size: 15, color: AppTheme.cyan),
                  const SizedBox(width: 6),
                  Text(
                    '中心 ${r.effectiveCenter!.weatherText ?? '—'} '
                    '${r.effectiveCenter!.temperature?.toStringAsFixed(1) ?? '--'}°',
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.text, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    '降水 ${r.effectiveCenter!.precipitationProbability ?? '--'}%'
                    '${r.effectiveCenter!.visibility == null ? '' : ' · 能见度 ${r.effectiveCenter!.visibility!.toStringAsFixed(1)}km'}',
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim),
                  ),
                ],
              ),
            ],
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
                const SizedBox(width: 6),
                _layerChip('雷达图', _LayerMode.radar),
                const SizedBox(width: 6),
                _layerChip('卫星云图', _LayerMode.satellite),
                const Spacer(),
                if ((_layerMode == _LayerMode.radar ||
                        _layerMode == _LayerMode.radarTile ||
                        _layerMode == _LayerMode.satellite) &&
                    (_radarInfo != null || _satelliteInfo != null))
                  Flexible(
                    child: Text(
                      _layerMode == _LayerMode.satellite
                          ? (_satelliteInfo ?? '')
                          : (_radarInfo ?? ''),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10.5, color: AppTheme.accent, fontWeight: FontWeight.w600),
                    ),
                  )
                else if (_layerMode != _LayerMode.none && _timeCount > 0)
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
                child: Stack(
                  children: [
                    AmapView(
                      lat: r.center.lat,
                      lon: r.center.lon,
                      zoom: _mapZoom,
                      markers: r.markers, // 带文字标注
                      // 叠加层：卫星模式用风云四号云图；雷达模式用拼图；其余用网格反演位图
                      overlayImage: _layerMode == _LayerMode.satellite
                          ? _satellitePng
                          : (_layerMode == _LayerMode.radar ? _radarPng : _overlayPng),
                      overlaySouthwest: _layerMode == _LayerMode.satellite
                          ? const LatLng(SatelliteGeo.latMin, SatelliteGeo.lonMin)
                          : (_layerMode == _LayerMode.radar ? _radarSw : _overlayBounds()?.sw),
                      overlayNortheast: _layerMode == _LayerMode.satellite
                          ? const LatLng(SatelliteGeo.latMax, SatelliteGeo.lonMax)
                          : (_layerMode == _LayerMode.radar ? _radarNe : _overlayBounds()?.ne),
                      // 雷达拼图半透明；卫星云图更淡（避免盖住底图）
                      overlayTransparency: _layerMode == _LayerMode.radar
                          ? 0.45
                          : (_layerMode == _LayerMode.satellite ? 0.35 : 0.0),
                      // 瓦片式雷达（RainViewer）：仅 zoom ≤ 7 有效
                      tileOverlayUrl:
                          _layerMode == _LayerMode.radarTile && _tileUsable
                              ? _rainTile?.urlTemplate
                              : null,
                      tileTransparency: 0.25,
                      onCameraMoveEnd: (target, zoom) {
                        if ((zoom - _currentZoom).abs() > 0.01) {
                          setState(() => _currentZoom = zoom);
                        }
                      },
                      interactive: true,
                    ),
                    // zoom 过大时雷达拼图会被拉得很糊（源图 1px≈2.6km）
                    if (_layerMode == _LayerMode.radar && _currentZoom > 9.5)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 46,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: const Color(0xE6141A24),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.accent.withValues(alpha: 0.7)),
                          ),
                          child: const Text(
                            '雷达拼图为区域全貌（约 2.6km/像素），建议缩小到 20km 以上查看更清晰',
                            style: TextStyle(fontSize: 11, color: AppTheme.accent, height: 1.35),
                          ),
                        ),
                      ),
                    if (_layerMode == _LayerMode.radar && _radarLoading)
                      const Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: ColoredBox(
                          color: Color(0x99101820),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: AppTheme.accent),
                                ),
                                SizedBox(height: 8),
                                Text('正在加载雷达拼图…',
                                    style: TextStyle(fontSize: 11.5, color: AppTheme.textDim)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // ===== 时间轴（看云/雨往哪飘；雷达模式不需要）=====
            if (_layerMode != _LayerMode.none &&
                _layerMode != _LayerMode.radar &&
                _timeCount > 0) ...[
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
                          _regenerateOverlay();
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

  /// 多源交叉验证面板（5 源并列 + 一致性评分）
  Widget _multiSourceCard() {
    final mm = _centerMulti!;
    return PanelCard(
      heading: '多源研判 · ${mm.sources.length} 源交叉验证',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _metric('一致性', '${mm.agreementScore} 分'),
              _metric('结论', mm.agreementText),
              _metric('时刻', '${mm.time.hour.toString().padLeft(2, '0')}:00'),
            ],
          ),
          const Divider(height: 22, color: AppTheme.borderSoft),
          _kvRow('温度', mm.spreadText((s) => s.temperature, digits: 1, unit: '℃')),
          _kvRow('降水概率',
              mm.spreadText((s) => s.precipitationProbability?.toDouble(), digits: 0, unit: '%')),
          _kvRow('降水', mm.spreadText((s) => s.precipitation, digits: 1, unit: ' mm/h')),
          _kvRow('阵风', mm.spreadText((s) => s.windGust, digits: 0, unit: '')),
          _kvRow('能见度', mm.spreadText((s) => s.visibility, digits: 1, unit: 'km')),
          _kvRow('云量', mm.spreadText((s) => s.cloudCover, digits: 0, unit: '%')),
          // 天气现象对比（诊断「晴天/阴天」不一致）
          _kvRow('天气现象', mm.weatherTextSpread),
          _kvRow('天气码', mm.weatherCodeSpread),
          if (mm.consensusWeatherText != null)
            _kvRow(
              '共识判定',
              '${mm.consensusWeatherText}（各源云量中位数 '
              '${mm.consensusCloudCover?.toStringAsFixed(0) ?? '--'}%）',
            ),
        ],
      ),
    );
  }

  /// 雷达定调面板（用真实回波裁决各模型分歧）
  Widget _radarVerdictCard() {
    if (_verdictLoading && _verdict == null) {
      return const PanelCard(
        heading: '雷达定调 · 真实回波校验',
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent),
            ),
            SizedBox(width: 10),
            Text('正在分析雷达回波…', style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
          ],
        ),
      );
    }
    final v = _verdict!;
    final r = v.radar;
    return PanelCard(
      heading: '雷达定调 · 真实回波校验',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (v.arbitrationUsed)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: AppTheme.accentDim,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.accent),
              ),
              child: const Text('模型分歧较大 → 以雷达实况定调',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.accent, fontWeight: FontWeight.w600)),
            ),
          if (r != null) ...[
            Row(
              children: [
                _metric('雷达回波', r.echoText),
                _metric('全图覆盖', '${r.coverage.toStringAsFixed(1)}%'),
                _metric('区域最强', '${r.maxDbz} dBZ'),
              ],
            ),
            const SizedBox(height: 8),
            if (r.rainNow != null && r.rainNow! >= 0.1)
              _kvRow('反演降水', '${r.rainNow!.toStringAsFixed(1)} mm/h（Z-R 关系）'),
            if (r.motionSpeedKmh != null && r.motionSpeedKmh! > 1)
              _kvRow('回波移动',
                  '向${r.motionDirection} ${r.motionSpeedKmh!.toStringAsFixed(0)} km/h（${r.framesUsed} 帧追踪）'),
            const Divider(height: 20, color: AppTheme.borderSoft),
          ],
          if (v.scores.isNotEmpty) ...[
            const Text('各源与雷达吻合度',
                style: TextStyle(fontSize: 11, color: AppTheme.textFaint, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final s in v.scores)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 62,
                      child: Text(
                        s.modelName,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: s.modelName == v.bestModel ? FontWeight.w700 : FontWeight.w500,
                          color: s.modelName == v.bestModel ? AppTheme.accent : AppTheme.textDim,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: s.score / 100,
                          minHeight: 6,
                          backgroundColor: AppTheme.bgInset,
                          valueColor: AlwaysStoppedAnimation(
                            s.score >= 70 ? AppTheme.green : (s.score >= 45 ? AppTheme.accent : AppTheme.red),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 30,
                      child: Text('${s.score}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
          ],
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.bgInset,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderSoft),
            ),
            child: Text(v.summary,
                style: const TextStyle(fontSize: 12, color: AppTheme.textDim, height: 1.5)),
          ),
        ],
      ),
    );
  }

  /// 未来预测面板（逐小时 24h + 逐日 7 天）
  Widget _forecastCard() {
    final now = DateTime.now();
    // 只取当前时刻之后的逐小时
    final hours = _hourlyForecast.where((h) => h.time.isAfter(now.subtract(const Duration(hours: 1)))).toList();
    final next24 = hours.take(24).toList();

    return PanelCard(
      heading: '未来预测 · 逐小时 24h / 逐日 7 天',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ===== 逐小时（横向滚动）=====
          if (next24.isNotEmpty) ...[
            const Text('逐小时',
                style: TextStyle(fontSize: 11, color: AppTheme.textFaint, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SizedBox(
              height: 108,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: next24.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final h = next24[i];
                  final t = h.temperature;
                  final pop = h.precipitationProbability;
                  final rain = h.precipitation ?? 0;
                  final isNow = i == 0;
                  return Container(
                    width: 58,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    decoration: BoxDecoration(
                      color: isNow ? AppTheme.accentDim : AppTheme.bgInset,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isNow ? AppTheme.accent : AppTheme.borderSoft),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${h.time.hour.toString().padLeft(2, '0')}时',
                            style: TextStyle(
                                fontSize: 10.5,
                                color: isNow ? AppTheme.accent : AppTheme.textFaint,
                                fontWeight: FontWeight.w600)),
                        Icon(
                          rain >= 8
                              ? Icons.thunderstorm
                              : (rain >= 2.5
                                  ? Icons.grain
                                  : (rain >= 0.1 ? Icons.water_drop_outlined : Icons.cloud_outlined)),
                          size: 16,
                          color: rain >= 0.1 ? AppTheme.cyan : AppTheme.textDim,
                        ),
                        Text(t == null ? '--' : '${t.round()}°',
                            style: const TextStyle(
                                fontSize: 13, color: AppTheme.text, fontWeight: FontWeight.w700)),
                        Text(pop == null ? '--' : '$pop%',
                            style: TextStyle(
                                fontSize: 10,
                                color: (pop ?? 0) >= 50 ? AppTheme.cyan : AppTheme.textFaint)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],

          // ===== 逐日 =====
          if (_dailyForecast.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('逐日',
                style: TextStyle(fontSize: 11, color: AppTheme.textFaint, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (var i = 0; i < _dailyForecast.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AppTheme.borderSoft),
              _dailyRow(_dailyForecast[i], isToday: i == 0),
            ],
          ],
        ],
      ),
    );
  }

  Widget _dailyRow(DailyWeather d, {bool isToday = false}) {
    final dateText = '${d.date.month}/${d.date.day}';
    final range = '${d.tempMin?.round() ?? '--'}° ~ ${d.tempMax?.round() ?? '--'}°';
    final pop = d.precipProbabilityMax;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 66,
            child: Row(
              children: [
                Text(isToday ? '今天' : d.weekday,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                        color: isToday ? AppTheme.accent : AppTheme.text)),
                const SizedBox(width: 4),
                Text(dateText, style: const TextStyle(fontSize: 10, color: AppTheme.textFaint)),
              ],
            ),
          ),
          Expanded(
            child: Text(d.weatherText ?? '—',
                style: const TextStyle(fontSize: 12, color: AppTheme.textDim),
                overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: 40,
            child: Text(pop == null ? '--' : '$pop%',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 11.5,
                    color: (pop ?? 0) >= 50 ? AppTheme.cyan : AppTheme.textFaint,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 78,
            child: Text(range,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, color: AppTheme.text, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// 键值行（多源比对用）
  Widget _kvRow(String k, String v) {
    if (v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(k, style: const TextStyle(fontSize: 11.5, color: AppTheme.textFaint)),
          ),
          Expanded(
            child: Text(v, style: const TextStyle(fontSize: 12, color: AppTheme.textDim, height: 1.4)),
          ),
        ],
      ),
    );
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
        if (mode == _LayerMode.radar) {
          // 中央气象台官方拼图（单图，缩小看全貌）
          final c = _result?.center;
          if (c != null) _loadRadar(c.lat, c.lon);
        } else if (mode == _LayerMode.radarTile) {
          // RainViewer 瓦片（任意缩放清晰）
          _loadRadarTile();
        } else if (mode == _LayerMode.satellite) {
          // 风云四号卫星云图（看云系）
          _loadSatellite();
        } else {
          _regenerateOverlay();
        }
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
    // 雷达模式：显示 dBZ 色阶
    if (_layerMode == _LayerMode.radar) {
      final items = <({Color c, String t})>[];
      for (final dbz in [10, 20, 30, 40, 50, 60]) {
        final rgb = RadarPalette.dbzToRgb(dbz);
        if (rgb == null) continue;
        items.add((
          c: Color.fromRGBO(rgb.r, rgb.g, rgb.b, 0.85),
          t: '$dbz',
        ));
      }
      return Padding(
        padding: const EdgeInsets.only(top: 2, left: 4),
        child: Row(
          children: [
            const Text('dBZ ', style: TextStyle(fontSize: 10, color: AppTheme.textFaint)),
            for (final it in items) ...[
              Container(
                width: 18,
                height: 9,
                decoration: BoxDecoration(
                  color: it.c,
                  border: Border.all(color: AppTheme.borderSoft),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 3),
              Text(it.t, style: const TextStyle(fontSize: 9.5, color: AppTheme.textFaint)),
              const SizedBox(width: 6),
            ],
            const Spacer(),
            const Text('弱 → 强', style: TextStyle(fontSize: 9.5, color: AppTheme.textFaint)),
          ],
        ),
      );
    }

    final items = _layerMode == _LayerMode.cloud
        ? [
            (_cloudColor(10), '少云'),
            (_cloudColor(50), '多云'),
            (_cloudColor(95), '阴'),
          ]
        : [
            (_rainColor(0.5), '小雨'),
            (_rainColor(3), '中雨'),
            (_rainColor(9), '大雨'),
            (_rainColor(20), '暴雨'),
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

  /// 生成天气叠加位图（PNG 字节）
  ///
  /// 直接构造 RGBA 像素数组并编码成 PNG —— 逐像素双线性插值，
  /// 得到真正连续平滑的云图/雨量图（而非马赛克格子）。
  /// 用 GroundOverlay 贴到地图上，**只占 1 个图层**，性能极好。
  Future<Uint8List?> _renderOverlayPng({int size = 160}) async {
    if (_grid.isEmpty || _layerMode == _LayerMode.none) return null;
    final n = _gridN;
    final t = _timeIndex.clamp(0, math.max(0, _timeCount - 1)).toInt();

    double? valueAt(int r, int c) {
      if (r < 0 || c < 0 || r >= n || c >= n) return null;
      final p = _grid[r * n + c];
      return _layerMode == _LayerMode.cloud ? p.cloudAt(t) : p.rainAt(t);
    }

    // 双线性插值（网格坐标 → 值）
    double? sample(double gr, double gc) {
      final r0 = gr.floor().clamp(0, n - 1);
      final c0 = gc.floor().clamp(0, n - 1);
      final r1 = (r0 + 1).clamp(0, n - 1);
      final c1 = (c0 + 1).clamp(0, n - 1);
      final fr = gr - r0;
      final fc = gc - c0;
      final v00 = valueAt(r0, c0), v01 = valueAt(r0, c1);
      final v10 = valueAt(r1, c0), v11 = valueAt(r1, c1);
      if (v00 == null && v01 == null && v10 == null && v11 == null) return null;
      final a = v00 ?? v01 ?? v10 ?? v11!;
      final b = v01 ?? a, c = v10 ?? a, d = v11 ?? b;
      final top = a + (b - a) * fc;
      final bottom = c + (d - c) * fc;
      return top + (bottom - top) * fr;
    }

    final pixels = Uint8List(size * size * 4);
    for (var py = 0; py < size; py++) {
      // 注意：图像 y 向下，而纬度向上 → 这里把 y 翻转
      final gr = (size - 1 - py) * (n - 1) / (size - 1);
      for (var px = 0; px < size; px++) {
        final gc = px * (n - 1) / (size - 1);
        final v = sample(gr, gc);
        final i = (py * size + px) * 4;
        if (v == null) {
          pixels[i + 3] = 0; // 透明
          continue;
        }
        final color = _layerMode == _LayerMode.cloud ? _cloudColor(v) : _rainColor(v);
        // Color 分量在新版 Flutter 里为浮点（0~1）
        pixels[i] = (color.r * 255).round().clamp(0, 255);
        pixels[i + 1] = (color.g * 255).round().clamp(0, 255);
        pixels[i + 2] = (color.b * 255).round().clamp(0, 255);
        pixels[i + 3] = (color.a * 255).round().clamp(0, 255);
      }
    }

    // decodeImageFromPixels 为回调式 API，这里包成 Future
    var opaque = 0;
    var maxAlpha = 0;
    for (var i = 3; i < pixels.length; i += 4) {
      if (pixels[i] > 0) opaque++;
      if (pixels[i] > maxAlpha) maxAlpha = pixels[i];
    }
    debugPrint('[叠加] 像素统计 总=${size * size} 不透明=$opaque 最大alpha=$maxAlpha '
        '模式=$_layerMode 时刻=$t/$_timeCount');

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final img = await completer.future;
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  /// 叠加层覆盖范围（西南 / 东北角）
  ({LatLng sw, LatLng ne})? _overlayBounds() {
    if (_grid.isEmpty) return null;
    final n = _gridN;
    final sw = _grid[0]; // row0,col0 = 最南最西
    final ne = _grid[(n - 1) * n + (n - 1)]; // 最北最东
    return (
      sw: LatLng(sw.lat, sw.lon),
      ne: LatLng(ne.lat, ne.lon),
    );
  }

  /// 云量(0-100) → 颜色：灰蓝渐变（少云淡、厚云深灰蓝），在浅色地图上对比明显
  Color _cloudColor(double cloud) {
    final t = (cloud / 100.0).clamp(0.0, 1.0);
    // 浅灰蓝 (176,190,210) → 深灰蓝 (74,92,120)
    final r = (176 - 102 * t).round();
    final g = (190 - 98 * t).round();
    final b = (210 - 90 * t).round();
    final a = (0.10 + t * 0.58).clamp(0.0, 0.72);
    return Color.fromRGBO(r, g, b, a);
  }

  /// 雨量(mm/h) → 颜色：**连续渐变**（浅蓝→蓝→深蓝→紫），与云量的平滑渲染一致
  ///
  /// 0.1mm/h 起色，20mm/h 达到最浓，中间平滑过渡（而非阶梯色）
  Color _rainColor(double rain) {
    if (rain < 0.08) return const Color(0x00000000);
    final t = ((rain - 0.08) / 18.0).clamp(0.0, 1.0);
    // 三段线性插值：浅蓝 → 亮蓝 → 深紫
    late final int r, g, b;
    final a = (0.35 + t * 0.5).clamp(0.0, 0.85);
    if (t < 0.5) {
      final k = t / 0.5;
      r = (110 - 71 * k).round(); // 110 → 39
      g = (200 - 129 * k).round(); // 200 → 71
      b = (250 - 9 * k).round(); // 250 → 241
    } else {
      final k = (t - 0.5) / 0.5;
      r = (39 + 85 * k).round(); // 39 → 124
      g = (71 + 6 * k).round(); // 71 → 77
      b = (241 + 14 * k).round(); // 241 → 255
    }
    return Color.fromRGBO(r, g, b, a);
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
      _regenerateOverlay();
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

  /// 源名简称（徽章空间有限，避免布局溢出）
  String _shortSource(String name) {
    switch (name) {
      case '中央气象台':
        return '央台';
      case '和风天气':
        return '和风';
      default:
        return name.length <= 5 ? name : name.substring(0, 5);
    }
  }

  Widget _sampleRow(({String label, GeoPoint point, HourlyWeather? weather}) s) {
    // 中心行：雷达定调判出最优源后，改用该源的值（与区域概览一致）
    final isCenter = s.label == '中心';
    final adopted = _result?.adoptedSource;
    final useAdopted = isCenter && adopted != null && _result?.effectiveCenter != null;
    final w = useAdopted ? _result!.effectiveCenter : s.weather;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Row(
              children: [
                Text(s.label,
                    style: const TextStyle(
                        fontSize: 12.5, color: AppTheme.textDim, fontWeight: FontWeight.w600)),
                if (useAdopted) ...[
                  const SizedBox(width: 3),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppTheme.green.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(_shortSource(adopted!),
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          softWrap: false,
                          style: const TextStyle(
                              fontSize: 8, color: AppTheme.green, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: Text(w?.weatherText ?? '无数据',
                style: TextStyle(
                    fontSize: 13,
                    color: useAdopted ? AppTheme.green : AppTheme.text,
                    fontWeight: useAdopted ? FontWeight.w600 : FontWeight.w400)),
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
