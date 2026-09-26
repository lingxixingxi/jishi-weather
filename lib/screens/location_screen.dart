import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../data/radar_stations.dart';
import '../engine/radar_cross_check.dart';
import '../engine/radar_verdict.dart';
import '../models/hourly_weather.dart';
import '../models/weather_warning.dart';
import '../services/amap_location_service.dart';
import '../services/amap_service.dart';
import '../services/multi_source_service.dart';
import '../services/nmc_city_repository.dart';
import '../services/qweather_service.dart';
import '../services/nmc_service.dart';
import '../services/open_meteo.dart';
import '../services/radar_service.dart';
import '../services/radar_source.dart';
import '../services/rainviewer_service.dart';
import '../services/satellite_service.dart';
import '../services/warning_service.dart';
import '../theme/app_theme.dart';
import '../widgets/amap_view.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/place_search_field.dart';
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

  /// 中心点所在**行政区划码**（6 位，高德逆地理编码所得）
  /// 气象预警按它做前缀匹配过滤
  final String? adcode;

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
    this.adcode,
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
        adcode: adcode,
      );
}

/// 多源聚合出的**逐日**预报（由 5 源逐小时数据本地合成）
///
/// 相比 Open-Meteo 的 `daily` 接口（只给 best_match 单模型），
/// 这里的数据天然带多源交叉验证，且天气现象用共识判定。
class _DailySummary {
  final DateTime date;
  final double? tempMax;
  final double? tempMin;
  final double precipitationSum; // mm
  final int? precipProbMax; // %
  final String? weatherText; // 共识判定或降水文字
  final double? cloudMedian; // 各源云量中位数
  final int sourceCount; // 参与比对的源数
  final int hours; // 该日覆盖的小时数（首日/末日可能不足 24）

  const _DailySummary({
    required this.date,
    this.tempMax,
    this.tempMin,
    this.precipitationSum = 0,
    this.precipProbMax,
    this.weatherText,
    this.cloudMedian,
    this.sourceCount = 0,
    this.hours = 0,
  });

  /// 星期几
  String get weekday {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${names[date.weekday - 1]}';
  }

  bool get isToday {
    final n = DateTime.now();
    return date.year == n.year && date.month == n.month && date.day == n.day;
  }
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

/// 单站雷达的一次实测结果
///
/// 区域拼图（华东全境、2.6 km/像素）回答「这片区域有没有雨」，
/// 单站雷达（覆盖 256 km、0.68 km/像素）回答「我脚下这一格有没有雨」。
class StationRadarReading {
  /// 命中的雷达站
  final RadarStation station;

  /// 目标点到该站的距离（km）
  final double distanceKm;

  /// 实测回波强度（dBZ）；null 表示该像素无回波
  final int? dbz;

  /// 实际读数的观测时刻（已换算为本地时间）
  ///
  /// 若 [fromStation] 为 false，这是**区域拼图**的观测时刻。
  final DateTime time;

  /// 读数是否来自单站雷达
  ///
  /// false 表示「单站当前小时没有更新」，已退回区域拼图兜底
  /// （精度从 0.68 km/像素降到 2.6 km/像素，但至少不会没数据）。
  final bool fromStation;

  /// 单站雷达**最近一次**有帧的时间（即使它不属于当前小时）
  ///
  /// 兜底时用它告诉用户「单站上次更新是几点」。
  final DateTime? stationLastTime;

  /// 与和风的交叉验证结果
  final RadarCrossCheck? check;

  const StationRadarReading({
    required this.station,
    required this.distanceKm,
    required this.dbz,
    required this.time,
    this.fromStation = true,
    this.stationLastTime,
    this.check,
  });
}

/// 地点查询页 —— 方圆 10km 区域天气
class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  @override
  void initState() {
    super.initState();
    _warmUpLocation();
  }

  /// 预热定位 —— 只为让 POI 联想候选**按距离排序**（用户附近的排前面）
  ///
  /// 策略：真实定位（5s 超时）→ 失败则 IP 定位兜底（1~2 秒）。
  /// 完全失败也不影响使用，只是候选不限地域。
  Future<void> _warmUpLocation() async {
    try {
      var p = await AmapLocationService.locate(timeout: const Duration(seconds: 5));
      p ??= await _amap.ipLocation();
      if (!mounted || p == null) return;
      setState(() => _myLocation = p);
      debugPrint('[地点] 预热定位成功: ${p.lat},${p.lon}（联想将按距离排序）');
    } catch (_) {
      // 定位失败不影响使用
    }
  }

  final _input = TextEditingController(text: '上海虹桥站');

  /// 联想搜索选中的精确坐标（优先于纯文本地理编码）
  GeoPoint? _selectedPoint;
  String? _selectedText;

  /// 我的当前位置（用于联想排序与定位）
  GeoPoint? _myLocation;
  final _amap = AmapService();
  final _meteo = OpenMeteoService();
  final _nmc = NmcService();
  late final NmcCityRepository _cityRepo = NmcCityRepository(_nmc, _amap);
  late final MultiSourceService _multi = MultiSourceService(
    meteo: _meteo,
    nmc: _nmc,
    cityRepo: _cityRepo,
  );

  /// 和风服务（单站雷达的交叉验证用）
  final _qweather = QWeatherService();

  /// 中心点的多源集合（5 源比对 + 雷达定调用）
  MultiModelHourly? _centerMulti;

  /// 雷达定调结果
  RadarVerdict? _verdict;
  bool _verdictLoading = false;

  /// 单站雷达实测（高精度：约 0.68 km/像素、覆盖半径 256 km）
  ///
  /// 区域拼图回答「这片区域有没有雨」，单站雷达回答「我脚下这一格有没有雨」。
  StationRadarReading? _stationRadar;

  /// 未来逐小时预测（取中心点，5 源）
  List<MultiModelHourly> _hourlyForecast = const [];

  /// **概览当前选中的时刻**（null = 跟随当前时间）
  ///
  /// 点选「未来 12 小时」中的某一格即可切换，此时：
  /// · 区域概览 → 显示该时刻的中心数值
  /// · 采样点明细 → 中心与 4 方位都取该时刻
  /// · 多源研判 → 换到该时刻的 5 源集合
  DateTime? _selectedTime;

  /// 4 个方位点的逐小时预报（与中心同长度，供采样明细按时刻取值）
  List<List<HourlyWeather>> _altHourly = const [];

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

  /// 气象预警（中央气象台 findAlarm，按 adcode 过滤）
  final _warnings = WarningService();
  List<WeatherWarning> _warningList = const [];
  bool _warningLoading = false;
  String? _warningAdcode;

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

  /// **从多源逐小时数据本地聚合出逐日预报**
  ///
  /// ⚠️ 为什么不用 Open-Meteo 的 `daily` 接口：
  /// 那个接口只返回 **best_match 单模型**的日值，**没有多源交叉验证**。
  /// 而我们已经有 5 源（ECMWF/GFS/ICON/和风/中央气象台）的逐小时数据，
  /// 本地聚合即可得到**多源融合**的日最高/最低温、降水总量、降水概率，
  /// 并能用 `consensusWeatherText`（各源云量中位数）判定天气现象。
  List<_DailySummary> _dailySummaries() {
    if (_hourlyForecast.isEmpty) return const [];

    // 按「年-月-日」分组
    final byDay = <String, List<MultiModelHourly>>{};
    for (final h in _hourlyForecast) {
      final k = '${h.time.year}-${h.time.month}-${h.time.day}';
      byDay.putIfAbsent(k, () => []).add(h);
    }

    final out = <_DailySummary>[];
    final keys = byDay.keys.toList()..sort();
    for (final k in keys) {
      final list = byDay[k]!..sort((a, b) => a.time.compareTo(b.time));

      // 各源在每个时刻的数值 → 先取该时刻的融合值，再对当天求极值/累计
      final temps = <double>[];
      final probs = <int>[];
      var precipSum = 0.0;
      final clouds = <double>[];

      for (final m in list) {
        final t = m.temperature;
        if (t != null) temps.add(t);
        final p = m.precipitationProbability;
        if (p != null) probs.add(p);
        // ⚠️ 防御性过滤：单小时降水 > 50mm 视为异常数据。
        // 气象上 50mm/h 已属极端强降水；某些源给的是**日累计值**，
        // 若被当成小时值累加会出现「日降水上千毫米」的离谱结果
        // （实测曾遇到中央气象台日累计被逐小时复制，累计达 1185mm）。
        final rain = m.precipitation ?? 0;
        if (rain >= 0 && rain <= 50) precipSum += rain;
        final c = m.cloudCover;
        if (c != null) clouds.add(c);
      }

      // 天气现象：优先看当天是否有降水，否则按云量中位数判定
      final day = list.first.time;
      final midday = list.firstWhere(
        (m) => m.time.hour >= 12 && m.time.hour <= 15,
        orElse: () => list[list.length ~/ 2],
      );
      final String? text;
      final hasRain = precipSum >= 0.5; // 当天累计 >= 0.5mm 视为有降水
      if (hasRain) {
        text = midday.toHourlyWeather().weatherText ?? '有雨';
      } else {
        text = midday.consensusWeatherText;
      }

      out.add(_DailySummary(
        date: day,
        tempMax: temps.isEmpty ? null : temps.reduce((a, b) => a > b ? a : b),
        tempMin: temps.isEmpty ? null : temps.reduce((a, b) => a < b ? a : b),
        precipitationSum: precipSum,
        precipProbMax: probs.isEmpty ? null : probs.reduce((a, b) => a > b ? a : b),
        weatherText: text,
        cloudMedian: midday.consensusCloudCover,
        sourceCount: midday.sources.length,
        hours: list.length,
      ));
      debugPrint('[逐日聚合] $k 覆盖 ${list.length}h '
          '降水 ${precipSum.toStringAsFixed(1)}mm '
          '温度 ${out.last.tempMin?.toStringAsFixed(0)}~${out.last.tempMax?.toStringAsFixed(0)}°');
    }
    return out;
  }

  /// 当前生效的**中心多源集合**（选中时刻优先，未选则当前时刻）
  ///
  /// 用户在「未来 12 小时」里点选某格后，概览 / 明细 / 多源研判
  /// 三处都会切到这个时刻，保证数值口径一致。
  MultiModelHourly? get _activeMulti {
    final t = _selectedTime;
    if (t == null || _hourlyForecast.isEmpty) return _centerMulti;
    MultiModelHourly? best;
    var bestDiff = const Duration(days: 999).inMinutes;
    for (final m in _hourlyForecast) {
      final d = m.time.difference(t).inMinutes.abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = m;
      }
    }
    return best ?? _centerMulti;
  }

  /// 取某方位点在给定时刻的预报（无选中时刻则用当前时间）
  HourlyWeather? _altAt(int index, DateTime t) {
    if (index < 0 || index >= _altHourly.length) return null;
    return _nearest(_altHourly[index], t);
  }

  /// 区域概览的「中心天气」块
  ///
  /// · 未选未来时刻 → 显示雷达定调最优源的值，并注明数据性质
  /// · 已选未来时刻 → 显示该时刻的 5 源融合值（与多源研判面板口径一致）
  Widget? _centerBlock(_AreaResult r) {
    final sel = _selectedTime;
    final mm = _activeMulti;

    final HourlyWeather? cw;
    final String sourceNote;
    if (sel == null) {
      cw = r.effectiveCenter;
      sourceNote = r.adoptedSource == null
          ? '多源融合'
          : '数值取自${r.adoptedSource}（雷达定调最优源）；天气现象由各源云量共识判定';
    } else {
      cw = mm?.toHourlyWeather(source: '5 源融合');
      sourceNote = '未来 ${sel.hour.toString().padLeft(2, '0')}:00 · '
          '${mm?.sources.length ?? 0} 源融合（与多源研判同步）';
    }
    if (cw == null) return null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(sel == null ? Icons.place : Icons.schedule,
                size: 15, color: sel == null ? AppTheme.cyan : AppTheme.accent),
            const SizedBox(width: 6),
            Text(
              '${sel == null ? '中心' : '${sel.hour.toString().padLeft(2, '0')}时'} '
              '${cw.weatherText ?? '—'} '
              '${cw.temperature?.toStringAsFixed(1) ?? '--'}°',
              style: TextStyle(
                  fontSize: 13,
                  color: sel == null ? AppTheme.text : AppTheme.accent,
                  fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              '降水 ${cw.precipitationProbability ?? '--'}%'
              '${cw.visibility == null ? '' : ' · 能见度 ${cw.visibility!.toStringAsFixed(1)}km'}',
              style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 5, left: 21),
          child: Text(sourceNote,
              style: const TextStyle(fontSize: 10, color: AppTheme.textFaint)),
        ),
      ],
    );
  }

  /// 选中未来时刻后，把**雷达定调**同步到该时刻
  ///
  /// 不论该时刻距今多久，都把**真实分钟数**交给 [RadarVerdictEngine]，
  /// 由它判断是否超出外推可信范围（[RadarService.forecastMaxMinutes] = 2 小时）：
  /// · 在时限内 → 用该时长做回波外推，给出那一刻的预测
  /// · 超出时限 → 引擎返回 `beyondNowcast`，**不打分、不给最优源**，
  ///   界面明确标注「未参与定调，以多源融合为准」
  ///
  /// ⚠️ 早先的实现是「超出时限就什么都不做」，界面会一直停在上一次（当前时刻）
  /// 的结论上，看起来就像**「选了很远的时间，雷达却没有降级」**（实测 bug）。
  Future<void> _syncRadarToSelected(DateTime? t) async {
    final center = _result?.center;
    if (center == null || _hourlyForecast.isEmpty) return;

    if (t == null) {
      // 回到「当前」→ 恢复默认外推时长
      await _runLocationVerdict(center, _hourlyForecast);
      return;
    }
    final lead = t.difference(DateTime.now()).inMinutes;
    // ⚠️ 只要目标在未来就把**真实分钟数**传下去，不要在这里因超范围而跳过：
    // 那样界面会一直停留在上一次（当前时刻）的结论上，看起来就像「没降级」。
    // 交给 `RadarVerdictEngine` 判断，并给出「超出雷达外推范围，以多源融合为准」
    // 的明确结论。
    await _runLocationVerdict(
      center,
      _hourlyForecast,
      horizonOverride: lead > 0 ? lead : null,
    );
  }

  /// 加载风云四号卫星云图（看云系，与雷达互补）
  Future<void> _loadSatellite() async {
    debugPrint('[卫星云图] 开始加载…（loading=$_satelliteLoading）');
    setState(() => _satelliteLoading = true);
    try {
      final r = await _satellite.fetchLatest();
      debugPrint('[卫星云图] fetchLatest -> ${r == null ? 'null' : '${r.bytes.length} 字节 @ ${r.time}'}');
      if (!mounted) return;
      if (r == null) {
        setState(() {
          _satelliteLoading = false;
          _satelliteInfo = '卫星云图拉取失败';
        });
        return;
      }
      // 只保留云（陆地/海洋透明化），否则整图叠加会让地图发暗发脏
      final png = await SatelliteService.cloudOnly(r.bytes);
      debugPrint('[卫星云图] cloudOnly -> ${png?.length ?? 0} 字节');
      if (!mounted) return;
      if (png == null) {
        setState(() {
          _satelliteLoading = false;
          _satelliteInfo = '云图处理失败';
        });
        return;
      }
      setState(() {
        _satellitePng = png;
        _satelliteInfo = '${r.time.month}/${r.time.day} '
            '${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')} · FY-4B 真彩色';
        _satelliteLoading = false;
      });
      debugPrint('[卫星云图] 已设置叠加层 ${png.length} 字节');
    } catch (e) {
      debugPrint('[卫星云图] 异常: $e');
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
  /// → 拉最新一帧 → 裁掉底部色标 → 用 [EastChinaProjection] 标定范围叠加。
  ///
  /// ⚠️ 必须 `forceMosaic: true`：央台接口**按城市返回不同产品**
  /// （上海给区域拼图 `AECN`、南京给单站 `AZ9250`），而叠加层固定使用拼图的
  /// 投影与经纬度范围；若拿到单站图，叠加位置会完全错位。
  /// 用于「定调 / 实测取值」的选源请走 [RadarSourcePicker]（单站优先）。
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
      final frames = await RadarService.fetchRecentFrames(
        radarPath: path,
        count: 1,
        forceMosaic: true,
      );
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
    _warnings.dispose();
    _qweather.dispose();
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
        setState(() => _myLocation = point); // 记录，供联想按距离排序
        await _analyze(point);
        return;
      }

      // 最后兜底：IP 定位
      final ipPoint = await _amap.ipLocation();
      if (ipPoint != null) {
        setState(() => _myLocation = ipPoint);
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
  ///
  /// **优先使用联想搜索选中的坐标**：同名的连锁店（海底捞火锅等）
  /// 直接走文本地理编码会定位到错误的门店，必须用用户点选的坐标。
  /// 仅当文字被改过（选中记录失效）时才退回文本地理编码。
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
      GeoPoint? p;
      final sel = _selectedPoint;
      // ① 用户从候选列表点选过，且文字没再改 → 用精确坐标
      if (sel != null && _selectedText == q) {
        p = sel;
        debugPrint('[地点] 使用联想选中的坐标: ${sel.lat},${sel.lon}');
      } else {
        // ② 否则走**智能地理编码**：先 POI 检索（找地点），再退地址解析。
        //    ⚠️ 不能直接用 `geocode` —— 它是**地址解析**，对 POI 名极易误匹配
        //    （实测「鄂尔多斯国际赛车场」被解析到珠海、「金港国际赛车场」
        //    被解析到同名住宅小区）。
        p = await _amap.geocodeSmart(q);
      }
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

    // 行政区划码（气象预警按 6 位 adcode 前缀匹配）——与下面的多源请求**并行**，
    // 走城市仓库的逆地理缓存，不会多花一次请求
    final addrFuture = _cityRepo.addressAt(center.lat, center.lon);

    // 中心点走**多源融合**（5 源交叉验证 + 雷达定调），保留完整多源集合
    List<MultiModelHourly> centerMulti = const [];
    try {
      centerMulti = await _multi.fetch(
        lat: center.lat,
        lon: center.lon,
        place: center.name.isEmpty ? '中心' : center.name,
        forecastDays: 7, // 7 天多源逐小时 → 本地聚合出多源逐日预报
      );
      debugPrint('[多源] 中心点 ${centerMulti.length} 个时刻，'
          '${centerMulti.isEmpty ? 0 : centerMulti.first.sources.length} 源');
    } catch (e) {
      debugPrint('[多源] 中心点失败: $e');
    }

    // 四方位点用单模型（省流量，只做方位差异对比）
    // 注意：也要拉 7 天，这样采样明细能跟随「未来小时」的选择切到同一时刻
    final others = points.where((p) => p.label != '中心').toList();
    var otherForecasts = <List<HourlyWeather>>[];
    try {
      otherForecasts = await _meteo.fetchMany(
        others.map((p) => (lat: p.point.lat, lon: p.point.lon, place: p.label)).toList(),
        forecastDays: 7,
      );
    } catch (e) {
      debugPrint('[单模型] 方位点失败: $e');
    }

    // 注：逐日预报不再调 Open-Meteo 的单源 daily 接口，
    // 改为从上面的 5 源逐小时数据本地聚合（见 _dailySummaries()），
    // 这样 7 日预报天然带多源交叉验证。

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
      // 网格跨度跟着地图缩放走（见 [_spanKmForZoom]）：视野大时覆盖更大范围，
      // 缩小时才看得到周边云量 / 雨量分布。
      // 实际网格 = 视野档 × 2（多出的一倍作为平移缓冲，见 [_gridSpanKm]）
      _viewSpanKm = _spanKmForZoom(_currentZoom);
      _fitSpanKm = _viewSpanKm; // 换地点：适配视野也跟着新网格走
      _gridCenter = LatLng(center.lat, center.lon);
      final tGrid = DateTime.now();
      grid = await _meteo.fetchGrid(
        centerLat: center.lat,
        centerLon: center.lon,
        spanKm: _gridSpanKm,
        n: _gridN,
      );
      debugPrint('[网格] 首次加载 ${grid.length} 点 × '
          '${grid.isEmpty ? 0 : grid.first.times.length} 时刻，'
          '耗时 ${DateTime.now().difference(tGrid).inMilliseconds}ms');
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

    String? adcode;
    try {
      adcode = (await addrFuture)?.adcode;
      debugPrint('[预警] adcode=${adcode ?? "未知"}');
    } catch (e) {
      debugPrint('[预警] 取 adcode 失败: $e');
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
      _altHourly = otherForecasts;
      _selectedTime = null; // 换地点后回到「当前时刻」
      _verdict = null;
      _result = _AreaResult(
        placeName: center.name.isEmpty ? '所选位置' : center.name,
        center: center,
        samples: samples,
        markers: markers,
        minTemp: temps.isEmpty ? null : temps.reduce((a, b) => a < b ? a : b),
        maxTemp: temps.isEmpty ? null : temps.reduce((a, b) => a > b ? a : b),
        maxPop: maxPop,
        adcode: adcode,
      );
    });

    // 气象预警（异步，不阻塞主流程）
    unawaited(_loadWarnings(adcode));

    // 雷达定调（异步，不阻塞）
    _runLocationVerdict(center, centerMulti);

    // 单站雷达实测（异步，不阻塞）—— 高精度版本，回答「这一格有没有雨」
    unawaited(_runStationRadar(center.lat, center.lon));

    // 生成叠加位图（异步，不阻塞 UI）
    if (_layerMode != _LayerMode.none && grid.isNotEmpty) {
      _regenerateOverlay();
    }
  }

  /// 拉取与当前地点相关的气象预警（本区县 + 本市）
  ///
  /// 数据源是**全国全量**（约 209 条），本地按 adcode 前缀过滤，
  /// 服务侧有 10 分钟缓存，所以同一地点反复查询不会重复拉取。
  Future<void> _loadWarnings(String? adcode) async {
    setState(() {
      _warningLoading = true;
      _warningAdcode = adcode;
      _warningList = const [];
    });
    try {
      final list = await _warnings.forAdcode(adcode);
      if (!mounted) return;
      setState(() {
        _warningList = list;
        _warningLoading = false;
      });
      debugPrint('[预警] 相关 ${list.length} 条（adcode=${adcode ?? "无"}）');
    } catch (e) {
      debugPrint('[预警] 拉取失败: $e');
      if (!mounted) return;
      setState(() => _warningLoading = false);
    }
  }

  /// 预警等级 → 颜色
  Color _warnColor(WarningSeverity? s) {
    switch (s) {
      case WarningSeverity.red:
        return AppTheme.red;
      case WarningSeverity.orange:
        return AppTheme.orange;
      case WarningSeverity.yellow:
        return AppTheme.yellow;
      case WarningSeverity.blue:
        return AppTheme.cyan;
      case null:
        return AppTheme.textDim;
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
  /// 跑雷达定调
  ///
  /// [horizonOverride] 指定外推提前量（分钟）。用户在「未来 12 小时」里
  /// 点选某格时会传入「该时刻距今的分钟数」：
  /// · ≤ [RadarService.forecastMaxMinutes]（120）→ 用该时长做回波外推
  /// · > 120 → 雷达外推已不可靠，界面会标注「超出雷达外推范围」
  Future<void> _runLocationVerdict(
    GeoPoint center,
    List<MultiModelHourly> multi, {
    int? horizonOverride,
  }) async {
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
        horizonOverride: horizonOverride,
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
          // 天气现象的取值口径（2026-09-26 修正）：
          // 数值取最优源；**天气现象由 [MultiModelHourly.effectiveWeatherText] 统一决策** ——
          // 有降水时用该源原文（央台实测已带上 real.weather.info，如「大雨」），
          // 原文缺失则按降水强度分级；只有**无降水**时才用云量共识。
          // 旧实现有降水时也会往共识上落，而共识没有降水档 ——
          // 大雨天云量必然 ≥85%，于是把央台实测的「大雨」显示成了「阴」。
          final effText = nowMulti.effectiveWeatherText(
            sourceText: src.weatherText,
            sourcePrecipitation: src.precipitation,
          );

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
            cloudCover: nowMulti.consensusCloudCover ?? src.cloudCover,
            weatherCode: src.weatherCode,
            weatherText: effText,
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
              PlaceSearchField(
                controller: _input,
                amap: _amap,
                icon: Icons.search,
                hint: '搜索地点（如：海底捞火锅、静安寺）',
                subtitle: '输入后从候选列表点选 —— 避免同名地点定位错误',
                near: _myLocation,
                onSelected: (p, tip) {
                  _selectedPoint = p;
                  _selectedText = _input.text.trim();
                  debugPrint('[地点] 选中候选「${tip.name}」-> ${p.lat},${p.lon}');
                },
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
        // ===== 气象预警（置顶：最需要立刻知道的信息）=====
        // 注：拿不到 adcode 时 _warningCard() 自行返回空块，不会误报「无预警」
        if (_result != null) FadeSlideIn(delayMs: 0, child: _warningCard()),

        // 结果面板按 35ms 递增错峰淡入（区域概览 → 采样明细 → 地图）
        if (_result != null)
          ..._resultWidgets(_result!).asMap().entries.map(
                (e) => FadeSlideIn(delayMs: e.key * 35, child: e.value),
              ),

        // ===== 未来 7 天预报（独立卡片，紧跟地图，便于对着地图看趋势）=====
        if (_hourlyForecast.isNotEmpty)
          FadeSlideIn(delayMs: 40, child: _dailyCard()),

        // ===== 多源交叉验证 + 雷达定调（与出行路线页同款逻辑）=====
        // 注：逐小时预报已并入「区域概览」（可点选切换时刻），
        //     采样点明细与多源研判会跟随该时刻同步切换
        if (_centerMulti != null) FadeSlideIn(delayMs: 80, child: _multiSourceCard()),
        if (_verdictLoading || _verdict != null)
          FadeSlideIn(delayMs: 120, child: _radarVerdictCard()),
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
            // 中心点天气
            // · 未选时刻 → 用雷达定调后的最优源值（r.effectiveCenter）
            // · 已选未来时刻 → 用该时刻的 5 源融合值（多源研判同步切换）
            if (_centerBlock(r) != null) ...[
              const SizedBox(height: 12),
              _centerBlock(r)!,
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                _metric('最高温', r.maxTemp == null ? '—' : '${r.maxTemp!.toStringAsFixed(1)}°'),
                _metric('最低温', r.minTemp == null ? '—' : '${r.minTemp!.toStringAsFixed(1)}°'),
                _metric('降水概率', r.maxPop == null ? '—' : '${r.maxPop}%'),
              ],
            ),
            // ===== 未来 12 小时逐小时（多源融合）=====
            ..._hourlyStrip(),
          ],
        ),
      ),
      PanelCard(
        heading: '采样点明细（中心 + 4 方位）',
        child: Column(
          children: [
            // 选中的未来时刻提示（明细数据会跟随切换）
            if (_selectedTime != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    const Icon(Icons.schedule, size: 13, color: AppTheme.accent),
                    const SizedBox(width: 5),
                    Text(
                      '已同步到 ${_selectedTime!.month}/${_selectedTime!.day} '
                      '${_selectedTime!.hour.toString().padLeft(2, '0')}:00',
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.accent, fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => setState(() => _selectedTime = null),
                      child: const Text('回到当前',
                          style: TextStyle(fontSize: 10.5, color: AppTheme.textDim)),
                    ),
                  ],
                ),
              ),
            // 索引 0 = 中心；1..4 = 北/南/东/西，对应 _altHourly 的下标
            ...r.samples.asMap().entries.map((e) {
              final s = e.value;
              final altIndex = s.label == '中心' ? -1 : e.key - 1;
              return _sampleRow(s, altIndex: altIndex);
            }),
          ],
        ),
      ),
      // 7 天预报独立成卡片（放在地图下方，见 build 里的 _dailyCard）
      PanelCard(
        heading: '地图 · 天气叠加',
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ===== 图层切换 =====
            // ===== 图层切换 =====
            //
            // 注意：这里**不能**用横向 ListView —— 它嵌在页面的垂直滚动里会产生
            // 手势冲突：按钮行既滚不动，点击也会被外层滚动吞掉（实测点不动）。
            // 5 个按钮总宽约 317px，远小于卡片宽度；时间标签已拆到独立行，
            // 因此用 Row 既不会溢出、点击也正常。
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
              ],
            ),
            // 信息标签（雷达/卫星的时刻）单独一行，右对齐
            if ((_layerMode == _LayerMode.radar ||
                    _layerMode == _LayerMode.radarTile ||
                    _layerMode == _LayerMode.satellite) &&
                (_radarInfo != null || _satelliteInfo != null)) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  _layerMode == _LayerMode.satellite
                      ? (_satelliteInfo ?? '')
                      : (_radarInfo ?? ''),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10.5, color: AppTheme.accent, fontWeight: FontWeight.w600),
                ),
              ),
            ] else if (_layerMode != _LayerMode.none && _timeCount > 0) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  // ⚠️ 数据源诚实标注：云量 / 雨量叠加图是 **Open-Meteo 数值模式预报**，
                  // 不是实况观测。不标出来，用户拿它跟「雷达图」（实况）比对时
                  // 会以为雨量图算错了 —— 实测反馈「雷达中到大雨、雨量图却几乎无色」，
                  // 差的其实是「实况 vs 模式」这个性质，不是数据出错。
                  if (_layerMode == _LayerMode.cloud ||
                      _layerMode == _LayerMode.rain)
                    const Flexible(
                      child: Text(
                        '数据源 Open-Meteo 模式预报（非实况）',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: AppTheme.textFaint),
                      ),
                    ),
                  const Spacer(),
                  Text(_timeLabel,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppTheme.accent, fontWeight: FontWeight.w600)),
                ],
              ),
            ],
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
                      // 雷达回波已在像素层透明化（只留回波），
                      // 这里只需很小的透明度让底图路网透出来即可
                      overlayTransparency: _layerMode == _LayerMode.radar ? 0.15 : 0.0,
                      // 瓦片式雷达（RainViewer）：仅 zoom ≤ 7 有效
                      tileOverlayUrl:
                          _layerMode == _LayerMode.radarTile && _tileUsable
                              ? _rainTile?.urlTemplate
                              : null,
                      tileTransparency: 0.25,
                      // 切到雷达/卫星图层时自动把镜头缩放到中心点周边合适范围
                      // （贴近定位所在地，而不是拉到图层的整个覆盖范围）
                      fitPoints: _mapFitPoints(LatLng(r.center.lat, r.center.lon)),
                      onCameraMoveEnd: (target, zoom) {
                        final zoomChanged = (zoom - _currentZoom).abs() > 0.01;
                        if (zoomChanged) setState(() => _currentZoom = zoom);
                        // 缩放跨档 **或** 平移出当前网格范围 → 重采网格。
                        // ⚠️ 平移同样必须重采：否则把地图挪到别的区域后，看到的
                        // 还是原来那块云量（用户反馈的第二个问题）。
                        _onMapSettled(target);
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
                    // 卫星云图覆盖整个东亚（约 95°×58°，11km/像素），
                    // 在 5km 视野下只能看到极小一块，需提示缩小
                    if (_layerMode == _LayerMode.satellite && _currentZoom > 8)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 46,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: const Color(0xE6141A24),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.cyan.withValues(alpha: 0.7)),
                          ),
                          child: const Text(
                            '卫星云图覆盖整个东亚（约 11km/像素），建议缩小到 200km 以上才能看出云系',
                            style: TextStyle(fontSize: 11, color: AppTheme.cyan, height: 1.35),
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
  ///
  /// 数据源为 [_activeMulti] —— 会跟随「未来 12 小时」里选中的时刻切换，
  /// 保证概览 / 明细 / 研判三处口径一致。
  /// 气象预警卡片（置顶）
  ///
  /// · 未拿到 adcode（定位/逆地理失败）→ 整块不渲染，避免误报「无预警」
  /// · 有预警 → 按危险度倒序列出，红色/橙色用醒目底色
  /// · 无预警 → 一句绿色确认
  Widget _warningCard() {
    if (_warningAdcode == null || _warningAdcode!.length < 6) {
      return const SizedBox.shrink();
    }

    if (_warningLoading) {
      return PanelCard(
        heading: '气象预警',
        child: Row(
          children: [
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent),
            ),
            const SizedBox(width: 10),
            const Text('正在核对该地区预警…',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
          ],
        ),
      );
    }

    final list = _warningList;
    if (list.isEmpty) {
      return const PanelCard(
        heading: '气象预警',
        child: Row(
          children: [
            Icon(Icons.verified_outlined, size: 15, color: AppTheme.green),
            SizedBox(width: 8),
            Text('当前无生效的气象预警',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
          ],
        ),
      );
    }

    return PanelCard(
      heading: '气象预警 · ${list.length} 条',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _warningRow(list[i]),
          ],
        ],
      ),
    );
  }

  /// 单条预警行
  Widget _warningRow(WeatherWarning w) {
    final c = _warnColor(w.severity);
    final scope = w.scopeFor(_warningAdcode);
    final t = w.issueTime;
    final timeText = t == null
        ? ''
        : '${t.month}/${t.day} '
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} 发布';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: c.withValues(alpha: .40)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 1),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4)),
            child: Text(
              w.severity?.label ?? '预警',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Color(0xFF10151F),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        w.type.isEmpty ? '气象预警' : w.type,
                        style: TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700, color: c),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (scope != null) ...[
                      const SizedBox(width: 6),
                      Text('· ${scope.label}',
                          style: const TextStyle(fontSize: 11, color: AppTheme.textFaint)),
                    ],
                  ],
                ),
                if (w.region.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(w.region,
                      style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim),
                      overflow: TextOverflow.ellipsis),
                ],
                if (timeText.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(timeText,
                      style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _multiSourceCard() {
    final mm = _activeMulti;
    if (mm == null) return const SizedBox.shrink();
    final isFuture = _selectedTime != null;
    return PanelCard(
      heading: isFuture
          ? '多源研判 · ${mm.time.month}/${mm.time.day} '
              '${mm.time.hour.toString().padLeft(2, '0')}:00（${mm.sources.length} 源）'
          : '多源研判 · ${mm.sources.length} 源交叉验证',
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

  /// 加载雷达实测：定位 → **统一选源** → 按像素取 dBZ
  ///
  /// **选源规则与「雷达定调」「出行路线」「赛道研判」完全一致**
  /// （统一由 [RadarSourcePicker] 决定，不再各写一套）：
  /// · 最近雷达站覆盖内（256 km）且**当前小时内有更新**（≤60 分钟）
  ///   → 用**单站雷达**，约 0.68 km/像素，是拼图（2.6 km/像素）的约 4 倍精度；
  /// · 单站**查过但过期**（或 4 小时窗口内一帧都没有）→ 回退**区域拼图**，
  ///   并如实标注单站上次更新时间，让用户能判断兜底数据的可信度。
  ///
  /// 目标点完全不在覆盖范围（境外 / 中国西部）时**不显示**这张卡 ——
  /// 否则「无回波」会被误读成「没有降水」，这是数据源边界而非天气结论。
  Future<void> _runStationRadar(double lat, double lon) async {
    try {
      final source = await RadarSourcePicker.pick(lat: lat, lon: lon, count: 1);
      if (source.isEmpty) {
        if (mounted) setState(() => _stationRadar = null);
        return;
      }

      final st = source.station;
      if (st == null || !source.projection.covers(lat, lon)) {
        debugPrint('[雷达实测] 目标点不在 ${source.label} 覆盖范围内，不显示实测卡');
        if (mounted) setState(() => _stationRadar = null);
        return;
      }

      final f = source.frames.last;
      final frame = await RadarService.analyze(f.bytes, f.time,
          projection: source.projection);
      final dbz = frame == null ? null : RadarService.sampleAt(frame, lat, lon);

      final stationRain = RadarCrossCheck.rainFromDbz(dbz);

      // 和风降水（用于交叉验证；未配置 Key 或失败则为 null）
      double? qwRain;
      var qwAvailable = false;
      try {
        if (_qweather.isConfigured) {
          final list = await _qweather.hourly(lat, lon, hours: 3);
          final h = QWeatherService.nearest(list, DateTime.now());
          if (h != null) {
            qwRain = h.precipitation;
            qwAvailable = true;
          }
        }
      } catch (e) {
        debugPrint('[雷达实测] 和风降水获取失败（不影响雷达读数）: $e');
      }

      final check = RadarCrossCheck(
        stationDbz: dbz,
        stationRainMmh: stationRain,
        qweatherRainMmh: qwRain,
        stationName: st.name,
        qweatherAvailable: qwAvailable,
      );

      if (!mounted) return;
      setState(() {
        _stationRadar = StationRadarReading(
          station: st,
          distanceKm: source.stationDistanceKm ?? 0,
          dbz: dbz,
          time: f.time,
          fromStation: source.fromStation,
          stationLastTime: source.stationLastTime,
          check: check,
        );
      });
      debugPrint('[雷达实测] ${st.name}(${st.code}) '
          '${source.fromStation ? "单站" : "拼图兜底"}'
          ' → ${dbz == null ? "无回波" : "$dbz dBZ"}；${check.conclusion}');
    } catch (e) {
      debugPrint('[雷达实测] 失败: $e');
    }
  }

  /// 单站雷达的数据时效提示
  ///
  /// 实测该源**更新极不规律**（各站只在自己有观测时出图），最新可用帧
  /// 可能滞后 1~3 小时。所以取到旧帧时必须如实标注，不能让用户误以为
  /// 这是"此刻"的回波。
  static String _stationRadarAgeText(DateTime t) {
    final m = DateTime.now().difference(t).inMinutes;
    if (m <= 30) return '';
    if (m < 120) return '（$m 分钟前）';
    return '（约 ${(m / 60).toStringAsFixed(1)} 小时前）';
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
    // 目标时刻是否超出雷达外推能力 —— 直接采信引擎给出的结论 `beyondNowcast`，
    // 而不是用 UI 状态另算一遍：两处判断一旦不一致，就会出现
    // 「提示说没定调、实际却按雷达结果切换了中心点」这类矛盾。
    final radarOutOfRange = v.beyondNowcast;

    return PanelCard(
      heading: _selectedTime == null
          ? '雷达定调 · 真实回波校验'
          : '雷达定调 · ${_selectedTime!.hour.toString().padLeft(2, '0')}:00 外推',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 选中时刻超出雷达外推能力时的说明
          if (radarOutOfRange)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.bgInset,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.textFaint),
              ),
              child: const Text(
                '该时刻距今超过 2 小时，超出雷达回波外推范围（外推在 30~60 分钟最可靠）。'
                '此时以数值模式的 5 源研判为准。',
                style: TextStyle(fontSize: 11, color: AppTheme.textDim, height: 1.4),
              ),
            ),
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
            // 外推预测：把回波场沿运动矢量整体平移后查目标点
            // （数值模式对 0~2h 的短临预报很弱，雷达外推恰好擅长这个尺度）
            if (r.dbzForecast != null)
              _kvRow(
                '${r.leadMinutes}分钟后',
                '${r.forecastText}'
                '${r.rainForecast != null && r.rainForecast! >= 0.1 ? ' · 约 ${r.rainForecast!.toStringAsFixed(1)} mm/h' : ''}'
                '（回波外推）',
              ),
            const Divider(height: 20, color: AppTheme.borderSoft),
          ],
          // ===== 雷达实测 =====
          // 区域拼图看全貌，单站雷达（0.68 km/像素、覆盖 256 km）看脚下这一格。
          // 单站当前小时没更新时退回拼图（见 _runStationRadar）。
          if (_stationRadar != null) ...[
            const Divider(height: 20, color: AppTheme.borderSoft),
            Row(
              children: [
                Icon(
                  _stationRadar!.fromStation ? Icons.radar : Icons.public,
                  size: 13,
                  color: _stationRadar!.fromStation
                      ? AppTheme.cyan
                      : AppTheme.orange,
                ),
                const SizedBox(width: 5),
                Text(
                  _stationRadar!.fromStation ? '单站雷达实测' : '雷达实测（拼图兜底）',
                  style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textFaint,
                      fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  _stationRadar!.fromStation ? '约 0.68 km/像素' : '约 2.6 km/像素',
                  style: const TextStyle(
                      fontSize: 10, color: AppTheme.textFaint),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _kvRow(
              '站点',
              '${_stationRadar!.station.name}站'
              '（${_stationRadar!.station.code}）· '
              '距 ${_stationRadar!.distanceKm.toStringAsFixed(0)} km',
            ),
            _kvRow(
              '实测回波',
              _stationRadar!.dbz == null
                  ? '无回波（这一格没有雨）'
                  : '${_stationRadar!.dbz} dBZ · '
                      '${RadarPalette.dbzLevel(_stationRadar!.dbz!)}',
            ),
            _kvRow(
              '观测时刻',
              '${_stationRadar!.time.hour.toString().padLeft(2, '0')}:'
                  '${_stationRadar!.time.minute.toString().padLeft(2, '0')}'
                  '${_stationRadarAgeText(_stationRadar!.time)}',
            ),
            // 兜底说明：单站当前小时无更新，改用拼图，并列出单站上次更新时间
            if (!_stationRadar!.fromStation)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppTheme.orange.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(7),
                    border:
                        Border.all(color: AppTheme.orange.withValues(alpha: .40)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline,
                          size: 13, color: AppTheme.orange),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '单站雷达当前小时无更新'
                          '${_stationRadar!.stationLastTime == null ? "（暂无记录）" : '，上次更新 '
                              '${_stationRadar!.stationLastTime!.hour.toString().padLeft(2, '0')}:'
                              '${_stationRadar!.stationLastTime!.minute.toString().padLeft(2, '0')}'
                              '${_stationRadarAgeText(_stationRadar!.stationLastTime!)}'}'
                          '；已改用区域拼图（精度约 2.6 km/像素）',
                          style: const TextStyle(
                              fontSize: 11,
                              height: 1.4,
                              color: AppTheme.orange),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // 与和风的交叉验证（分歧时以雷达为准）
            if (_stationRadar!.check != null)
              Padding(
                // 上下留等量间距：之前只有 top，导致下方与「各源与雷达吻合度」
                // 标题贴在一起（用户反馈）
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                  decoration: BoxDecoration(
                    color: (_stationRadar!.check!.diverged
                            ? AppTheme.orange
                            : AppTheme.green)
                        .withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: (_stationRadar!.check!.diverged
                              ? AppTheme.orange
                              : AppTheme.green)
                          .withValues(alpha: .40),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _stationRadar!.check!.diverged
                            ? Icons.compare_arrows
                            : Icons.check_circle_outline,
                        size: 13,
                        color: _stationRadar!.check!.diverged
                            ? AppTheme.orange
                            : AppTheme.green,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _stationRadar!.check!.conclusion,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.4,
                            color: _stationRadar!.check!.diverged
                                ? AppTheme.orange
                                : AppTheme.green,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
  /// 未来 12 小时逐小时条（放进「区域概览」）
  ///
  /// 数据来自 5 源多源集合（`_hourlyForecast`）。
  /// **每格可点选**：选中后区域概览、采样点明细、多源研判都会切到该时刻；
  /// 再次点选同一格可取消（回到「当前」）。
  List<Widget> _hourlyStrip() {
    final now = DateTime.now();
    final hours = _hourlyForecast
        .where((h) => h.time.isAfter(now.subtract(const Duration(minutes: 30))))
        .take(12)
        .toList();
    if (hours.isEmpty) return const [];

    return [
      const SizedBox(height: 14),
      Row(
        children: [
          const Text('未来 12 小时',
              style: TextStyle(fontSize: 11, color: AppTheme.textFaint, fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          Text('${hours.first.sources.length} 源融合',
              style: const TextStyle(fontSize: 9.5, color: AppTheme.textFaint)),
          const Spacer(),
          Text(
            _selectedTime == null ? '点选可切换时刻' : '已选 ${_selectedTime!.hour.toString().padLeft(2, '0')}:00 · 再点取消',
            style: TextStyle(
                fontSize: 9.5,
                color: _selectedTime == null ? AppTheme.textFaint : AppTheme.accent,
                fontWeight: _selectedTime == null ? FontWeight.w400 : FontWeight.w600),
          ),
        ],
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: hours.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final h = hours[i];
            final t = h.temperature;
            final pop = h.precipitationProbability;
            final rain = h.precipitation ?? 0;
            final isNow = i == 0;
            // 选中判定：按小时匹配（选中时刻可能带分钟）
            final selected = _selectedTime != null &&
                _selectedTime!.year == h.time.year &&
                _selectedTime!.month == h.time.month &&
                _selectedTime!.day == h.time.day &&
                _selectedTime!.hour == h.time.hour;
            final hl = selected || (isNow && _selectedTime == null);

            return GestureDetector(
              onTap: () {
                final next = selected ? null : h.time;
                setState(() => _selectedTime = next);
                _syncRadarToSelected(next);
              },
              child: Container(
                width: 56,
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
                decoration: BoxDecoration(
                  color: hl ? AppTheme.accentDim : AppTheme.bgInset,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected
                        ? AppTheme.accent
                        : (isNow && _selectedTime == null ? AppTheme.accent : AppTheme.borderSoft),
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${h.time.hour.toString().padLeft(2, '0')}时',
                        style: TextStyle(
                            fontSize: 10,
                            color: hl ? AppTheme.accent : AppTheme.textFaint,
                            fontWeight: FontWeight.w600)),
                    Icon(
                      rain >= 8
                          ? Icons.thunderstorm
                          : (rain >= 2.5
                              ? Icons.grain
                              : (rain >= 0.1 ? Icons.water_drop_outlined : Icons.cloud_outlined)),
                      size: 15,
                      color: rain >= 0.1 ? AppTheme.cyan : AppTheme.textDim,
                    ),
                    Text(t == null ? '--' : '${t.round()}°',
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.text, fontWeight: FontWeight.w700)),
                    Text(pop == null ? '--' : '$pop%',
                        style: TextStyle(
                            fontSize: 9.5,
                            color: (pop ?? 0) >= 50 ? AppTheme.cyan : AppTheme.textFaint)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ];
  }

  /// 未来 7 天逐日（**独立卡片**，放在地图下方）
  ///
  /// ⚠️ 数据由 [_dailySummaries] **从 5 源逐小时本地聚合**，
  /// 而非单源的 Open-Meteo `daily` 接口，因此天然带多源交叉验证。
  Widget _dailyCard() {
    final days = _dailySummaries();
    if (days.isEmpty) return const SizedBox.shrink();

    return PanelCard(
      heading: '未来 7 天预报',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${days.first.sourceCount} 源聚合',
                  style: const TextStyle(fontSize: 10, color: AppTheme.textFaint)),
              const SizedBox(width: 8),
              const Text('天气现象由各源云量共识判定',
                  style: TextStyle(fontSize: 10, color: AppTheme.textFaint)),
            ],
          ),
          const SizedBox(height: 6),
          for (final d in days) _dailyStripRow(d),
        ],
      ),
    );
  }

  Widget _dailyStripRow(_DailySummary d) {
    final pop = d.precipProbMax;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Row(
              children: [
                Text(d.isToday ? '今天' : d.weekday,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: d.isToday ? FontWeight.w700 : FontWeight.w500,
                        color: d.isToday ? AppTheme.accent : AppTheme.text)),
                const SizedBox(width: 4),
                Text('${d.date.month}/${d.date.day}',
                    style: const TextStyle(fontSize: 10, color: AppTheme.textFaint)),
              ],
            ),
          ),
          Expanded(
            child: Text(d.weatherText ?? '—',
                style: const TextStyle(fontSize: 12, color: AppTheme.textDim),
                overflow: TextOverflow.ellipsis),
          ),
          // 日降水总量（有雨才显示）
          SizedBox(
            width: 44,
            child: Text(
              d.precipitationSum >= 0.1 ? '${d.precipitationSum.toStringAsFixed(1)}mm' : '',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 10, color: AppTheme.cyan),
            ),
          ),
          SizedBox(
            width: 38,
            child: Text(pop == null ? '' : '$pop%',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 11,
                    color: (pop ?? 0) >= 50 ? AppTheme.cyan : AppTheme.textFaint,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 76,
            child: Text(
              '${d.tempMin?.round() ?? '--'}° ~ ${d.tempMax?.round() ?? '--'}°',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, color: AppTheme.text, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

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
          // 切到云量 / 雨量：把「适配视野」的跨度快照更新为当前视野档，
          // 这样从雷达 / 卫星的大范围切回来时会**缩放到网格范围**
          // （用户反馈「从雷达图切回云量不会放大到最近尺寸」）。
          _fitSpanKm = _viewSpanKm;
          _regenerateOverlay();
        }
      },
      borderRadius: BorderRadius.circular(8),
      // 动效决策（频率：偶尔 / 目的：状态指示）
      // · 120ms easeOut（按钮反馈类，100~160ms 区间）
      // · 只过渡颜色与边框色（不涉及尺寸/位移）
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
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

    // 卫星云图模式：图例必须与 cloudOnly() 的实际配色一致（灰蓝系），
    // 否则会出现「图例是白色、实际云是蓝灰」的错配。
    // 取值按 cloudOnly 的映射反算（等效云量 c = 0.38 / 0.70 / 1.0）：
    //   r = 176-102c, g = 190-98c, b = 210-90c，alpha = 0.30+0.52c
    if (_layerMode == _LayerMode.satellite) {
      return Padding(
        padding: const EdgeInsets.only(top: 2, left: 4),
        child: Row(
          children: [
            for (final it in [
              (const Color(0x808999B0), '薄云'), // c≈0.38 RGB(137,153,176)
              (const Color(0xA8697993), '中云'), // c≈0.70 (105,121,147)
              (const Color(0xD24A5C78), '厚云'), // c=1.00 (74,92,120)
            ]) ...[
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
            const Spacer(),
            const Text('仅叠加云 · 越蓝越厚', style: TextStyle(fontSize: 9.5, color: AppTheme.textFaint)),
          ],
        ),
      );
    }

    // 雷达瓦片 / 无图层时不显示图例
    if (_layerMode == _LayerMode.radarTile) {
      return const SizedBox(height: 14);
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
        // 边缘淡出：网格之外本就没有数据，硬截断会让叠加图看起来像「贴了一块
        // 方色块」（用户反馈「边缘还是会卡」）。外圈 12% 线性降到全透明。
        final ddx = ((px / (size - 1)) - 0.5).abs() * 2; // 0=中心 1=边缘
        final ddy = ((py / (size - 1)) - 0.5).abs() * 2;
        final dd = ddx > ddy ? ddx : ddy;
        final fade =
            dd <= 0.88 ? 1.0 : (1.0 - (dd - 0.88) / 0.12).clamp(0.0, 1.0);
        // Color 分量在新版 Flutter 里为浮点（0~1）
        pixels[i] = (color.r * 255).round().clamp(0, 255);
        pixels[i + 1] = (color.g * 255).round().clamp(0, 255);
        pixels[i + 2] = (color.b * 255).round().clamp(0, 255);
        pixels[i + 3] = (color.a * 255 * fade).round().clamp(0, 255);
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

  /// 当前**视野档位**跨度（km）—— 由地图缩放级别决定（见 [_spanKmForZoom]）
  ///
  /// 实际网格跨度是它的 **2 倍**（见 [_gridSpanKm]），多出的部分作为**平移缓冲**。
  double _viewSpanKm = 24;

  /// 网格实际覆盖跨度（km）= 视野 × 2
  ///
  /// ⚠️ 取 2 倍是为了**平移缓冲**：用户把地图挪半个屏，视野里依然全是有效数据，
  /// 不必等新网格回来。这是「移动到别的区域也能立刻看到那里的图」的关键 ——
  /// 早先网格只有 1 倍视野，一平移边缘就露白。
  double get _gridSpanKm => _viewSpanKm * 2;

  /// 当前网格的中心（用于判断地图是否已移出有效范围）
  LatLng? _gridCenter;

  /// 地图当前中心（由 `onCameraMoveEnd` 上报）
  LatLng? _mapCenter;

  /// 网格重采的防抖计时器
  ///
  /// 拖动地图会连续触发 `onCameraMoveEnd`，若每次都发请求会又慢又浪费
  /// （还容易撞上 Open-Meteo 限流）。停手 350ms 后才真正重采。
  Timer? _gridDebounce;

  /// 网格重采是否进行中（防止连续操作触发并发请求）
  bool _gridResampling = false;

  /// 按地图缩放级别给出合适的**视野**跨度（km）
  ///
  /// 高德（Web Mercator）下 `米/像素 = 156543 × cos(lat) / 2^zoom`。
  /// ⚠️ 地图卡片是 `SizedBox(height: 300)`，即 **300 逻辑像素**高，所以
  /// 视野跨度 ≈ 300 × 156543 × cos(32°) / 2^zoom / 1000 ≈ **39.8 / 2^zoom 公里**
  ///   · zoom 11 → 约 19 km     · zoom 10 → 约 39 km
  ///   · zoom 9  → 约 78 km     · zoom 8  → 约 156 km
  ///
  /// ⚠️ 必须**用离散档位而不是连续跟随**：连续计算会让每一次捏合都触发重新
  /// 采样（抖动且浪费），而网格本来就是固定的 9×9 个点，按档位整体换一档即可。
  ///
  /// ⚠️ 早先这里误用了 745px 作为地图高度，算出偏大一倍的跨度，配合
  /// 「程序移动也重采」曾形成正反馈（zoom 从 11.5 一路发散到 7.7）。
  double _spanKmForZoom(double z) {
    if (z >= 12.0) return 12; // 视野 ≤ 10 km
    if (z >= 11.0) return 24; // 默认档（初始 zoom 11.5 落这里）
    if (z >= 10.0) return 48;
    if (z >= 9.0) return 96;
    if (z >= 8.0) return 192;
    return 384; // 省域级
  }

  /// 地图静止后决定是否重采网格（缩放跨档 **或** 平移出有效范围）
  void _onMapSettled(LatLng center) {
    _mapCenter = center;
    // 只有云量 / 雨量需要按视野重采；雷达、卫星是固定覆盖的整图
    if (_layerMode != _LayerMode.cloud && _layerMode != _LayerMode.rain) return;

    final spanChanged = _spanKmForZoom(_currentZoom) != _viewSpanKm;
    if (!spanChanged && !_gridCenterMoved(center)) return;

    _gridDebounce?.cancel();
    _gridDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_resampleGridForZoom());
    });
  }

  /// 地图中心是否已移出当前网格的**主要覆盖区**
  ///
  /// 网格半径是 `_viewSpanKm`（跨度 2 倍视野），中心偏离超过一个视野跨度
  /// 就重采 —— 留一半重叠可以保证重采期间画面里始终有数据，不会出现空白。
  bool _gridCenterMoved(LatLng center) {
    final ref = _gridCenter;
    if (ref == null) return true;
    final dLatKm = (center.latitude - ref.latitude).abs() * 110.57;
    final cosLat =
        math.cos(ref.latitude * math.pi / 180).abs().clamp(0.2, 1.0);
    final dLonKm = (center.longitude - ref.longitude).abs() * 111.32 * cosLat;
    final dKm = math.sqrt(dLatKm * dLatKm + dLonKm * dLonKm);
    return dKm > _viewSpanKm;
  }

  /// 按当前**地图中心**与缩放档位重新采样云量 / 雨量网格
  ///
  /// 这是「缩放到哪、移到哪，就看到哪的云量」的实现。
  ///
  /// ⚡ 请求本身已被 `OpenMeteoService.fetchGrid` 优化过（拆成单日窗口并发 +
  /// 只取 2 个变量），实测由 8.65 s 降到约 1 s —— 否则再怎么防抖也还是慢。
  ///
  /// ⚠️ **不要清空 `_overlayPng`**：那会让叠加层在网络请求期间先「闪一下消失」
  /// 再出现。`_regenerateOverlay()` 会在新位图渲染好后一次性替换，旧图一直保留
  /// 到那一刻，视觉才是连续的。
  Future<void> _resampleGridForZoom() async {
    final fallback = _result?.center;
    // ⚠️ 用**地图当前中心**而不是查询时的中心点 —— 用户平移到别的区域时，
    // 网格必须跟着走，否则那片区域永远没有云量。
    final lat = _mapCenter?.latitude ?? fallback?.lat;
    final lon = _mapCenter?.longitude ?? fallback?.lon;
    if (lat == null || lon == null || _gridResampling) return;

    final view = _spanKmForZoom(_currentZoom);
    if (view == _viewSpanKm && !_gridCenterMoved(LatLng(lat, lon))) return;

    _gridResampling = true;
    try {
      final t0 = DateTime.now();
      final grid = await _meteo.fetchGrid(
        centerLat: lat,
        centerLon: lon,
        spanKm: view * 2, // 2 倍视野做平移缓冲
        n: _gridN,
      );
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (!mounted) return;
      debugPrint('[网格] 重采 视野档=$view km 网格=${view * 2} km '
          'zoom=${_currentZoom.toStringAsFixed(2)} '
          '中心=${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}'
          '（${grid.length} 点，耗时 ${ms}ms）');
      setState(() {
        _grid = grid;
        _viewSpanKm = view;
        _gridCenter = LatLng(lat, lon);
      });
      await _regenerateOverlay();
    } catch (e) {
      debugPrint('[网格] 重采失败: $e');
    } finally {
      _gridResampling = false;
    }
  }

  /// 云量 / 雨量图层的「适配视野」跨度快照（km）
  ///
  /// ⚠️ **刻意与 [_gridSpanKm] 分开**：网格会随用户缩放重新采样，若 fitPoints
  /// 也跟着变，就会在每次重采后强行把镜头拉回网格范围 —— 等于**和用户抢缩放**
  /// （用户缩到 z10，程序又 fit 回 z9.4，永远缩不到位）。
  /// 这里只在**图层切换 / 换地点时**取一次快照，保证「切回云量时缩放到当前
  /// 网格范围」只发生一次，之后用户的缩放完全自主。
  double _fitSpanKm = 24;

  /// 当前图层对应的「自动适配视野」点集
  ///
  /// [AmapView] 检测到 fitPoints 变化会把镜头缩放到恰好框住这些点的范围。
  ///
  /// ⚠️ 这里**不套用图层的完整覆盖范围**（用户反馈「雷达图缩放的好大，
  /// 1000km，能不能贴近定位所在地」）：华东雷达拼图跨 20°×20°（约 2000km），
  /// 拉到全图时定位点只剩一个像素。改为以中心点为基准给一个**合理半径**：
  ///   · 雷达   → ±150km，本地回波看得清，又不会偏出雷达图覆盖
  ///   · 卫星   → ±800km，卫星云图约 11km/像素，范围太小看不出云系
  ///   · 云量 / 雨量 → 框住切换那一刻的网格范围（略留边）
  ///
  /// ⚠️ 云量 / 雨量**必须返回非空**：早先这里返回空数组，理由写的是
  /// 「网格本就在视野内，不需要动镜头」—— 但那只在「视野本来就小」时成立。
  /// 从雷达（±150km）或卫星（±800km）切回来时视野仍是大范围，网格叠加图
  /// 会缩成中间一小块（用户反馈「切回云量不会放大到最近尺寸」）。
  List<LatLng> _mapFitPoints(LatLng center) {
    switch (_layerMode) {
      case _LayerMode.radar:
      case _LayerMode.radarTile:
        return _boxAround(center, 150);
      case _LayerMode.satellite:
        return _boxAround(center, 800);
      case _LayerMode.cloud:
      case _LayerMode.rain:
        // ⚠️ 半径取 **0.7 × 网格半跨**（而不是放大留边）：
        // `moveCamera(newLatLngBounds)` 会把给定范围尽量框满（还有 56px padding），
        // 若半径接近网格半跨，框出来的视野就**大于网格**，云量块的方形边缘会露在
        // 屏幕里 —— 这正是用户看到的「边缘还是会卡」。
        // 取 0.7 让视野明显小于网格（约 0.7~0.8 倍），连边缘淡出带一起推到屏幕外。
        return _boxAround(center, _fitSpanKm / 2 * 0.7);
      case _LayerMode.none:
        return const [];
    }
  }

  /// 以 [c] 为中心、半径 [halfKm] 公里的方框（返回西南、东北两角）
  static List<LatLng> _boxAround(LatLng c, double halfKm) {
    final dLat = halfKm / 110.57;
    final cosLat = math.cos(c.latitude * math.pi / 180).abs().clamp(0.2, 1.0);
    final dLon = halfKm / (111.32 * cosLat);
    return [
      LatLng(c.latitude - dLat, c.longitude - dLon),
      LatLng(c.latitude + dLat, c.longitude + dLon),
    ];
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

  Widget _sampleRow(
    ({String label, GeoPoint point, HourlyWeather? weather}) s, {
    int altIndex = -1,
  }) {
    final isCenter = s.label == '中心';
    final sel = _selectedTime;
    final adopted = _result?.adoptedSource;
    // 只有「当前时刻」才用雷达定调的最优源；选了未来时刻则改用该时刻的融合值
    final useAdopted =
        sel == null && isCenter && adopted != null && _result?.effectiveCenter != null;

    final HourlyWeather? w;
    if (sel != null) {
      // 已选未来时刻：中心取 5 源融合，4 个方位取各自单模型同时刻
      w = isCenter ? _activeMulti?.toHourlyWeather(source: '5 源融合') : _altAt(altIndex, sel);
    } else {
      w = useAdopted ? _result!.effectiveCenter : s.weather;
    }

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
                      child: Text(_shortSource(adopted),
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
