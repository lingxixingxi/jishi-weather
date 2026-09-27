import 'dart:async';

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../engine/radar_verdict.dart';
import '../engine/route_analyzer.dart';
import '../engine/typhoon_verdict.dart';
import '../models/hourly_weather.dart';
import '../services/amap_location_service.dart';
import '../services/amap_service.dart';
import '../services/multi_source_service.dart';
import '../services/nmc_city_repository.dart';
import '../services/nmc_service.dart';
import '../services/open_meteo.dart';
import '../services/radar_service.dart';
import '../theme/app_theme.dart';
import '../widgets/amap_view.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/place_search_field.dart';
import 'home_screen.dart' show ScreenScaffold, PanelCard;

/// 出行路线页
///
/// 流程：起终点 → 高德规划（**返回多条候选路线，由用户选定实际要走的那条**）
///       → 沿选定路线每 10km 采样 → 按到达时刻取天气 → 分段研判。
class RouteScreen extends StatefulWidget {
  const RouteScreen({super.key});

  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

/// 一个雷达校验点的定调结论
///
/// 雷达定调沿途取若干校验点（最多 3 个，且只在**外推可信窗内**选），
/// 每个点各判一次「该点最吻合哪个源」。本类把「哪个采样点 / 什么时刻 /
/// 结论是什么」绑在一起，供分段**就近取源**。
///
/// 老实现只用路线中点一个点，却拿它的结论管全线；长途路线上起点与终点
/// 可能根本不是同一个天气型，中点准不代表全线准（2026-09-27 改）。
class RadarCheckpoint {
  /// 对应的采样点序号（同时是 arriveTimes / multiAtArrival 的下标）
  final int sampleIndex;

  /// 该点里程（km，展示用）
  final double km;

  /// 该点到达时刻
  final DateTime arriveAt;

  /// 该点的定调结论
  final RadarVerdict verdict;

  const RadarCheckpoint({
    required this.sampleIndex,
    required this.km,
    required this.arriveAt,
    required this.verdict,
  });
}

class _RouteScreenState extends State<RouteScreen> {
  @override
  void initState() {
    super.initState();
    // 异步取一次当前位置：仅用于让联想候选按距离排序（失败无影响）
    _warmUpLocation();
  }

  Future<void> _warmUpLocation() async {
    try {
      // timeout 给足 10s —— 与地点页预热一致：高德 SDK 首次调用要初始化，
      // 多个页面共用同一次定位时，短 timeout 会把复用者一起拖失败。
      var p = await AmapLocationService.locate(timeout: const Duration(seconds: 10));
      p ??= await _amap.ipLocation(); // 真实定位失败时用 IP 兜底
      if (!mounted || p == null) return;
      setState(() => _myLocation = p);
      debugPrint('[路线] 当前位置已获取: ${p.lat},${p.lon}（用于联想排序）');
    } catch (_) {
      // 定位失败不影响使用
    }
  }

  final _origin = TextEditingController(text: '上海虹桥站');
  final _dest = TextEditingController(text: '苏州工业园区');

  /// 用当前位置填写起点或终点
  ///
  /// 每次点击都**重新定位**，而不是复用启动时缓存的 `_myLocation` ——
  /// 用户可能已经移动了（这个 App 的使用场景就是出门前/在路上）。
  Future<void> _applyCurrentLocation(
    TextEditingController ctrl,
    void Function(GeoPoint) assign,
    String fieldLabel,
  ) async {
    try {
      final GeoPoint? located =
          await AmapLocationService.locate(timeout: const Duration(seconds: 8));
      final GeoPoint? p = located ?? await _amap.ipLocation(); // 真实定位失败时用 IP 兜底
      if (!mounted) return;
      if (p == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('定位失败，请确认已开启定位权限')),
        );
        return;
      }
      // 反地理编码取一个可读名字；失败则退化为坐标文本
      var name = '当前位置 ${p.lat.toStringAsFixed(3)},${p.lon.toStringAsFixed(3)}';
      try {
        final addr = await _cityRepo.addressAt(p.lat, p.lon);
        if (addr != null && addr.formatted.isNotEmpty) name = addr.formatted;
      } catch (_) {
        // 反查失败不影响填入坐标
      }
      if (!mounted) return;
      setState(() {
        ctrl.text = name;
        assign(p);
        _myLocation = p;
      });
      debugPrint('[路线] $fieldLabel 已填入当前位置「$name」-> ${p.lat},${p.lon}');
    } catch (e) {
      debugPrint('[路线] $fieldLabel 定位失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('定位失败，请稍后重试')),
        );
      }
    }
  }

  /// 交换起点与终点（含已选中的精确坐标）
  void _swapEndpoints() {
    final oName = _origin.text;
    final dName = _dest.text;
    final oPt = _originPoint;
    final dPt = _destPoint;
    setState(() {
      _origin.text = dName;
      _dest.text = oName;
      _originPoint = dPt;
      _destPoint = oPt;
      // 起终点变了，上一次的规划结果不再适用
      _options = const [];
      _analysis = null;
      _from = dPt;
      _to = oPt;
      _error = null;
    });
    debugPrint('[路线] 已交换起终点：「$oName」⇄「$dName」');
  }

  /// 交换按钮（与两个输入框的中线对齐）
  Widget _swapButton() {
    return Semantics(
      label: '交换起点与终点',
      button: true,
      child: GestureDetector(
        onTap: _swapEndpoints,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppTheme.bgInset,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: AppTheme.borderSoft),
          ),
          child: const Icon(Icons.swap_vert, size: 20, color: AppTheme.accent),
        ),
      ),
    );
  }

  /// 联想搜索选中的精确坐标（优先于纯文本地理编码）
  GeoPoint? _originPoint;
  GeoPoint? _destPoint;

  /// 我的当前位置（用于联想排序）
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

  DateTime _departAt = DateTime.now().add(const Duration(hours: 1));

  bool _planning = false;
  bool _analyzing = false;
  String? _error;

  /// 部分采样点没拿到数据时的提示（非致命，但必须让用户看见）
  ///
  /// 与 [_error] 的区别：[_error] 会中断研判，这个只是降级提示 ——
  /// 缺数据的路段按空缺处理，结论偏保守，但整条路线仍可用。
  String? _partialFailNote;

  /// 路线采样点上限
  ///
  /// 沿途每 10km 一个点，长途路线（如 500km）会切出 50+ 个点，
  /// 每个点一次「3 模型 × N 天」的多模型请求 —— 既慢又容易触发限流，
  /// 结果是整批失败、全线显示「未知」（见 `OpenMeteoService.fetchMultiModelMany`）。
  /// 40 个点已足够刻画沿途天气变化（间距约 12~15km）。
  static const int _maxRouteSamples = 40;

  /// 雷达校验点数量上限
  ///
  /// 沿途每个校验点都要「选源 → 取图 → 逐帧分析」，是整条研判链里最重的一步。
  /// 3 个点已能刻画「起点 / 中段 / 外推极限」的源可信度变化；
  /// 再多就主要是等待时间在涨。
  static const int _maxRadarCheckpoints = 3;

  /// 多点雷达定调的**总时间预算**
  ///
  /// `RadarVerdictEngine.judge` 单次 timeout 默认 40 秒，三个点串行最坏
  /// 120 秒 —— 用户等不起。这里给整批封顶，**先近后远**跑，
  /// 超预算就用已回来的结果，剩下的如实标注跳过。
  static const Duration _radarTotalBudget = Duration(seconds: 14);

  /// 单个校验点的超时上限（还要受剩余预算约束）
  static const Duration _radarPerPointCap = Duration(seconds: 10);

  GeoPoint? _from;
  GeoPoint? _to;
  List<RouteOption> _options = const [];
  int _selectedIndex = 0;
  RouteAnalysis? _analysis;

  /// 台风 × 路线重叠研判（计划任务 4-1）
  RouteTyphoonImpact? _typhoonRoute;

  /// 当前展开的分段（横向路线条点击切换）
  int _selectedSegment = 0;

  /// 雷达定调结果（用真实雷达回波裁决模型分歧）
  RadarVerdict? _verdict;

  /// **最近那个校验点**的到达时刻距今分钟数（负数 = 已到达 / 已过去）
  ///
  /// 用来区分雷达该怎么用：≤2h 走外推，>2h 以多源融合为准。
  ///
  /// ⚠️ 基准是该校验点自己的**到达时刻**，不是出发时刻 —— 必须与传给
  /// `RadarVerdictEngine.judge` 的 `models` 对齐（那同样是该点到达时刻的
  /// 数据），否则提前量会少算（2026-09-27 修正）。
  int? _verdictLeadMinutes;

  /// 本次研判的全部雷达校验点（按里程升序）
  ///
  /// 第一个（最近的）作为 [_verdict] 展开详情，其余列进「沿程校验点」。
  List<RadarCheckpoint> _checkpoints = const [];
  bool _verdictLoading = false;

  /// 保存最近一次研判的原始数据，用于雷达定调后按最优源重建分段
  List<({GeoPoint point, double kmFromStart})> _lastSamples = const [];
  List<MultiModelHourly?> _lastMulti = const [];
  List<HourlyWeather?> _lastWeathers = const [];
  RouteOption? _lastOpt;

  /// 选中某条候选路线（地图会因 fitPoints 变化自动缩放到该路线）
  void _selectRoute(int index) {
    setState(() => _selectedIndex = index);
  }

  /// 交给 AmapView 自动框选的点集
  ///
  /// 高德 polyline 偶有孤立异常点，用起终点过滤离群点，避免镜头跑到几百公里外。
  List<LatLng> _fitPointsOf(RouteOption opt) {
    var usable = opt.polyline;
    final a = _from;
    final b = _to;
    if (a != null && b != null) {
      final span = AmapService.distanceKm(a.lat, a.lon, b.lat, b.lon);
      final limit = (span * 1.6).clamp(5.0, 2000.0);
      final filtered = opt.polyline
          .where((p) =>
              AmapService.distanceKm(p.lat, p.lon, a.lat, a.lon) <= limit &&
              AmapService.distanceKm(p.lat, p.lon, b.lat, b.lon) <= limit)
          .toList();
      if (filtered.isNotEmpty) usable = filtered;
    }
    return usable.map((p) => LatLng(p.lat, p.lon)).toList();
  }

  /// 候选路线折线
  ///
  /// · 已研判：**按分段画**，选中的那一段琥珀加粗（点击分段即高亮该段）
  /// · 未研判：画整条候选路线（选中候选琥珀色）
  List<Polyline> _routePolylines() {
    final lines = <Polyline>[];
    final a = _analysis;

    if (a != null && a.segments.isNotEmpty) {
      for (var i = 0; i < a.segments.length; i++) {
        final seg = a.segments[i];
        if (seg.points.isEmpty) continue;
        final selected = i == _selectedSegment;
        lines.add(Polyline(
          points: seg.points.map((p) => LatLng(p.lat, p.lon)).toList(),
          width: selected ? 12 : 7,
          color: selected ? AppTheme.accent : const Color(0x668493A6),
        ));
      }
      return lines;
    }

    if (_options.isNotEmpty) {
      final opt = _options[_selectedIndex];
      lines.add(Polyline(
        points: opt.fullPolyline.map((p) => LatLng(p.lat, p.lon)).toList(),
        width: 10,
        color: AppTheme.accent,
      ));
    }
    return lines;
  }

  /// 地图当前要框住的点：**优先当前选中分段**，其次整条路线
  List<LatLng> _currentFitPoints() {
    final a = _analysis;
    if (a != null && a.segments.isNotEmpty) {
      final idx = _selectedSegment.clamp(0, a.segments.length - 1);
      final seg = a.segments[idx];
      if (seg.points.isNotEmpty) {
        return seg.points.map((p) => LatLng(p.lat, p.lon)).toList();
      }
    }
    if (_options.isNotEmpty) return _fitPointsOf(_options[_selectedIndex]);
    return const [];
  }

  /// 起终点标注
  List<Marker> _routeMarkers() {
    final list = <Marker>[];
    if (_from != null) {
      list.add(Marker(
        position: LatLng(_from!.lat, _from!.lon),
        infoWindow: InfoWindow(title: '起点', snippet: _origin.text),
      ));
    }
    if (_to != null) {
      list.add(Marker(
        position: LatLng(_to!.lat, _to!.lon),
        infoWindow: InfoWindow(title: '终点', snippet: _dest.text),
      ));
    }
    return list;
  }

  @override
  void dispose() {
    _origin.dispose();
    _dest.dispose();
    _amap.dispose();
    _meteo.dispose();
    _nmc.dispose();
    super.dispose();
  }

  /// 第一步：规划路线（拿到多条候选）
  Future<void> _plan() async {
    final o = _origin.text.trim();
    final d = _dest.text.trim();
    if (o.isEmpty || d.isEmpty) {
      setState(() => _error = '请填写起点和终点');
      return;
    }
    setState(() {
      _planning = true;
      _error = null;
      _options = const [];
      _analysis = null;
    });
    try {
      // 优先用联想搜索选中的坐标（连锁店名走文本地理编码会定位错）；
      // 没点选过则走**智能地理编码**（POI 检索优先，再退地址解析）
      final from = (_originPoint != null && _originPoint!.name == o)
          ? _originPoint
          : await _amap.geocodeSmart(o);
      final to = (_destPoint != null && _destPoint!.name == d)
          ? _destPoint
          : await _amap.geocodeSmart(d);
      if (from == null) throw Exception('未找到起点：$o');
      if (to == null) throw Exception('未找到终点：$d');
      final routes = await _amap.drivingRoutes(from, to);
      if (routes.isEmpty) throw Exception('未规划出可用路线');
      setState(() {
        _from = from;
        _to = to;
        _options = routes;
        _selectedIndex = 0;
        _planning = false;
      });
    } catch (e) {
      setState(() {
        _planning = false;
        _error = '$e';
      });
    }
  }

  /// 出发时刻是否就是「现在」（±5 分钟内）
  ///
  /// 只用于按钮高亮 —— 让用户一眼看出当前是按"现在出发"在算。
  bool get _isDepartingNow =>
      _departAt.difference(DateTime.now()).abs() <= const Duration(minutes: 5);

  /// 「现在出发」：把出发时刻设为此刻，**并按当前时间重算研判**
  ///
  /// ⚠️ 只改时间不重算，界面上的时间变了、结论却还是按旧时刻算的 ——
  /// 这种「显示与依据脱节」是本项目反复踩过的坑，所以这里一并重算。
  ///
  /// 尚未研判过（没点过「按此路线生成研判」）时只设时间，不擅自触发研判。
  void _departNow() {
    final now = DateTime.now();
    setState(() => _departAt = now);
    debugPrint('[路线] 出发时间 → 现在 '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}');
    if (_analysis != null && _options.isNotEmpty && !_analyzing) {
      unawaited(_analyze(_options[_selectedIndex]));
    }
  }

  /// 采样点抽稀 —— 等间隔取点，**但必须保住最后一个点**
  ///
  /// 丢尾点会让路线终点那一段没有天气依据（末段只能靠前一个采样点兜底），
  /// 所以抽稀后若末点不是原始末点，就补上。
  static List<({GeoPoint point, double kmFromStart})> _thinSamples(
    List<({GeoPoint point, double kmFromStart})> raw,
    int maxCount,
  ) {
    if (raw.length <= maxCount) return raw;
    final step = (raw.length / maxCount).ceil();
    final out = <({GeoPoint point, double kmFromStart})>[];
    for (var i = 0; i < raw.length; i += step) {
      out.add(raw[i]);
    }
    if (out.last.kmFromStart < raw.last.kmFromStart) out.add(raw.last);
    return out;
  }

  /// 按到达时刻挑出最接近的多源集合
  MultiModelHourly? _nearestMulti(List<MultiModelHourly> list, DateTime target) {
    if (list.isEmpty) return null;
    MultiModelHourly? best;
    var bestDiff = const Duration(days: 999).inMinutes;
    for (final m in list) {
      final d = m.time.difference(target).inMinutes.abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = m;
      }
    }
    return best;
  }

  /// 第二步：对选定路线做天气研判
  Future<void> _analyze(RouteOption opt) async {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return;

    setState(() {
      _analyzing = true;
      _error = null;
      _partialFailNote = null;
      _analysis = null;
    });
    try {
      // 沿途每 10km 采样，再按上限抽稀（长途路线会有上百个点）
      final rawSamples = AmapService.sampleAlong(opt.polyline, intervalKm: 10);
      final samples = _thinSamples(rawSamples, _maxRouteSamples);

      // 预报天数**按实际需要算**：只覆盖「出发 → 到达」，再留 6 小时余量。
      // 原来固定传 3 天，而绝大多数行程在 24 小时内 ——
      // 多出来的天数让每次请求的响应体积凭空涨约 50%，
      // 是「批量请求超时 → 全线未知」的帮凶之一。
      final leadHours =
          _departAt.difference(DateTime.now()).inHours.clamp(0, 24 * 6);
      final tripHours = (opt.durationMinutes / 60).ceil();
      final forecastDays = ((leadHours + tripHours + 6) / 24).ceil().clamp(1, 5);

      debugPrint('[路线研判] 采样 ${rawSamples.length} → ${samples.length} 点，'
          '预报 $forecastDays 天'
          // 行程显示**实际分钟**而不是 tripHours ——
          // tripHours 是 ceil 出来的（61 分钟 → 2h），写进日志会误导排查
          '（出发距今 ${leadHours}h + 行程 ${opt.durationMinutes}min + 余量 6h）');

      // **多源交叉验证**：Open-Meteo 三模型（ECMWF/GFS/ICON）+ 中央气象台
      final multiAll = await _multi.fetchMany(
        samples
            .map((s) => (
                  lat: s.point.lat,
                  lon: s.point.lon,
                  place: '${s.kmFromStart.toStringAsFixed(0)}km',
                ))
            .toList(),
        forecastDays: forecastDays,
      );

      // ⚠️ 必须区分「天气未知」和「请求失败」。
      //
      // 全空时若照常往下走，`RouteAnalyzer.signature()` 对 null 一律返回
      // 「未知」，整条路线就被渲染成一串「未知」—— 正是用户实测反馈的
      // 「经常所有都是未知」。**数据没拿到就该明确报错，不能编一份空结论。**
      final okPoints = multiAll.where((e) => e.isNotEmpty).length;
      if (okPoints == 0) {
        throw Exception(
          '天气数据拉取失败：$forecastDays 天预报 × ${samples.length} 个采样点全部无响应。'
          '请检查网络后重试；若持续失败，多半是数据源限流，等几分钟再试。',
        );
      }
      _partialFailNote = okPoints < multiAll.length
          ? '${multiAll.length - okPoints}/${multiAll.length} 个采样点未取到数据，'
              '这些路段按空缺处理（结论偏保守）'
          : null;

      // 用融合值走原有研判流程
      final forecasts = multiAll
          .map((list) => list.map((m) => m.toHourlyWeather()).toList())
          .toList();

      final weathers = RouteAnalyzer.pickAtArrival(
        samples: samples,
        pointForecasts: forecasts,
        departAt: _departAt,
        totalMinutes: opt.durationMinutes,
        totalKm: opt.distanceKm,
      );

      // 按到达时刻挑出对应的「多源集合」，供研判依据并列展示
      final multiAtArrival = <MultiModelHourly?>[];
      for (var i = 0; i < samples.length; i++) {
        final km = samples[i].kmFromStart;
        final frac = opt.distanceKm <= 0 ? 0.0 : (km / opt.distanceKm).clamp(0.0, 1.0);
        final arriveAt = _departAt.add(Duration(minutes: (opt.durationMinutes * frac).round()));
        final list = i < multiAll.length ? multiAll[i] : const <MultiModelHourly>[];
        multiAtArrival.add(_nearestMulti(list, arriveAt));
      }

      final segments = RouteAnalyzer.buildSegments(
        samples: samples,
        weathers: weathers,
        departAt: _departAt,
        totalMinutes: opt.durationMinutes,
        totalKm: opt.distanceKm,
        originName: _origin.text.trim(),
        destinationName: _dest.text.trim(),
        fullPolyline: opt.fullPolyline, // 用于截取每段的真实路径
        multiModels: multiAtArrival, // 多源比对数据
      );

      // 调试：确认按里程截取的路段点是否正确
      debugPrint('[分段调试] 高德报距离=${opt.distanceKm.toStringAsFixed(1)}km '
          'fullPolyline累计=${RouteAnalyzer.totalKmOf(opt.fullPolyline).toStringAsFixed(1)}km '
          'full点数=${opt.fullPolyline.length}');
      for (final s in segments) {
        final pts = s.points;
        debugPrint('[分段调试] SEG${s.index} ${s.startKm.toStringAsFixed(0)}-'
            '${s.endKm.toStringAsFixed(0)}km 点数=${pts.length} '
            '${pts.isEmpty ? '' : '首(${pts.first.lat.toStringAsFixed(3)},${pts.first.lon.toStringAsFixed(3)}) '
                '尾(${pts.last.lat.toStringAsFixed(3)},${pts.last.lon.toStringAsFixed(3)})'}');
      }

      setState(() {
        _analyzing = false;
        _selectedSegment = 0; // 新研判回到第一段
        _verdict = null;
        _analysis = RouteAnalysis(
          segments: segments,
          totalKm: opt.distanceKm,
          totalMinutes: opt.durationMinutes,
          originName: _origin.text.trim(),
          destinationName: _dest.text.trim(),
          overallGrade: RouteAnalyzer.worstGrade(segments.map((s) => s.grade)),
        );
      });

      // ===== 雷达定调（异步，不阻塞主流程）=====
      //
      // 每个采样点的**到达时刻**都要算出来 —— 雷达校验点按「到达时刻是否
      // 落在外推可信窗内」筛选（见 _runRadarVerdict）。时间基准必须与
      // `multiAtArrival[i]` 对齐：后者正是按这个时刻挑出来的数据。
      final arriveTimes = <DateTime>[
        for (final s in samples)
          _departAt.add(Duration(
            minutes: (opt.durationMinutes *
                    (opt.distanceKm <= 0
                        ? 0.0
                        : (s.kmFromStart / opt.distanceKm).clamp(0.0, 1.0)))
                .round(),
          )),
      ];

      _lastSamples = samples;
      _lastMulti = multiAtArrival;
      _lastWeathers = weathers;
      _lastOpt = opt;
      _runRadarVerdict(samples, multiAtArrival, arriveTimes);

      // ===== 台风 × 路线重叠（异步，不阻塞主流程）=====
      unawaited(_runTyphoonRoute(_analysis));
    } catch (e) {
      setState(() {
        _analyzing = false;
        _error = '$e';
      });
    }
  }

  /// 沿途多点雷达定调：逐点判出「该点最吻合哪个源」
  ///
  /// ## 为什么是「多点」而不是「一个中点」（2026-09-27 改）
  ///
  /// 老实现只在路线中点做一次定调，却拿它的结论管**全线**。上海→苏州这种
  /// 短途无所谓，长途路线上起点与终点可能压根不是同一个天气型 ——
  /// 中点准不代表全线准。现在沿途取最多 [_maxRadarCheckpoints] 个校验点，
  /// 每个采样点用**离它最近**那个校验点的结论。
  ///
  /// ## 三条约束，全部来自「雷达外推只有 2 小时可信」这条硬边界
  ///
  /// 1. **只在可信窗内选点**：到达时刻距今 ≤ [RadarService.forecastMaxMinutes]
  ///    的采样点才有资格当校验点，且按里程均匀撒开（别全挤在起点）。
  ///    窗外的段**不参与定调** —— 20 小时行程里只有前 2 小时对雷达有意义，
  ///    把代表点均匀铺在 2000km 上纯属浪费，本来也定不出东西。
  /// 2. **总时限兜底**：`judge` 单次 timeout 就有 40 秒，多点串行会让用户
  ///    干等。这里给整批一个总预算 [_radarTotalBudget]，**先近后远**跑
  ///    （近端才是雷达真正有价值的地方，先出结果），超预算就用已回来的
  ///    结果，剩下的如实标注跳过。
  /// 3. **窗外一律用融合值**：校验点只做它附近那一小段的主意。哪怕离最近
  ///    校验点很近，只要该采样点自己的到达时刻在窗外，就不采用雷达结论。
  ///
  /// ## 与「超长途雷达外推超时」的关系
  ///
  /// 超长途**不需要额外处理** —— 超窗的段本来就不该用雷达。真正要设计的
  /// 只是上面 1、2 两条：窗内怎么选点、总耗时怎么兜底。
  Future<void> _runRadarVerdict(
    List<({GeoPoint point, double kmFromStart})> samples,
    List<MultiModelHourly?> multiAtArrival,
    List<DateTime> arriveTimes,
  ) async {
    // ⚠️ 这两处早先是**静默 return** —— 一旦命中，雷达卡片连「正在分析」
    // 都不显示，用户完全看不到雷达，也查不到原因。实测反馈正是
    // 「当天的雷达不启动，选到超过两个小时才蹦出来」。
    //
    // 根因：上游多模型请求整批失败时 `multiAtArrival` 全是 null，于是
    // `models == null` 直接 return，**卡片整体不渲染**。而「超过两小时就
    // 出现」是另一条路径 —— 那时若数据恰好取到了，卡片才被渲染出来，
    // 看起来就像雷达跟出发时间有关，其实两者无关（真正的开关是数据有没有到手）。
    //
    // 现在：**照样渲染卡片并写明未运行的原因**，让「没跑」和「跑了」一样可见。
    final path = _multi.lastRadarPath;
    if (path == null || samples.isEmpty) {
      if (!mounted) return;
      setState(() {
        _verdict = RadarVerdict(
          summary: path == null
              ? '本次未取到中央气象台雷达图路径（央台请求未成功），雷达定调未运行。'
              : '路线采样点为空，雷达校验点无法确定，雷达定调未运行。',
        );
        _verdictLoading = false;
      });
      return;
    }

    final now = DateTime.now();
    final windowMin = RadarService.forecastMaxMinutes;

    // ---- 1) 选校验点：只挑到达时刻落在可信窗内的采样点 ----
    final inWindow = <int>[];
    for (var i = 0; i < samples.length; i++) {
      if (arriveTimes[i].difference(now).inMinutes <= windowMin) {
        inWindow.add(i);
      }
    }

    if (inWindow.isEmpty) {
      // 全部落在窗外（例：「3 小时后出发 + 长途」）—— 此刻的雷达回波跟任何
      // 一个采样点的到达时刻都对不上，硬做定调等于伪造依据，不如不做。
      final firstLead =
          arriveTimes.isEmpty ? 0 : arriveTimes.first.difference(now).inMinutes;
      if (!mounted) return;
      setState(() {
        _verdict = RadarVerdict(
          summary: '全部采样点的到达时刻都超出雷达外推可信范围'
              '（最近的一点距今 ${(firstLead / 60).toStringAsFixed(1)} 小时，'
              '上限 ${windowMin ~/ 60} 小时），本次未做雷达定调，以多源融合为准。',
        );
        _checkpoints = const [];
        _verdictLoading = false;
      });
      debugPrint('[雷达定调] 全部点超窗（最近 ${firstLead}min > ${windowMin}min）'
          ' → 未做定调');
      return;
    }

    // 窗内点按里程均匀取最多 N 个（首尾都保），再按「先近后远」排执行顺序
    final picks = _spreadPick(inWindow, _maxRadarCheckpoints)
      ..sort((a, b) => arriveTimes[a].compareTo(arriveTimes[b]));

    setState(() {
      _verdictLoading = true;
      _verdictLeadMinutes = arriveTimes[picks.first].difference(now).inMinutes;
    });
    debugPrint('[雷达定调] 窗内 ${inWindow.length} 点 → 取 ${picks.length} 个校验点'
        '（${picks.map((i) => samples[i].kmFromStart.round()).join("/")} km）');

    // ---- 2) 逐个定调，带总时限 ----
    final done = <RadarCheckpoint>[];
    final sw = Stopwatch()..start();
    for (final idx in picks) {
      final remain = _radarTotalBudget - sw.elapsed;
      if (remain < const Duration(seconds: 4)) {
        debugPrint('[雷达定调] 总预算 ${_radarTotalBudget.inSeconds}s 用尽，'
            '跳过剩余 ${picks.length - done.length} 个校验点');
        break;
      }
      final models = idx < multiAtArrival.length ? multiAtArrival[idx] : null;
      if (models == null) continue;

      final lead = arriveTimes[idx].difference(now).inMinutes;
      try {
        final v = await RadarVerdictEngine.judge(
          lat: samples[idx].point.lat,
          lon: samples[idx].point.lon,
          models: [models],
          radarPath: path,
          // 单点超时不超过剩余预算，避免第一个点就吃光整批
          timeout: remain < _radarPerPointCap ? remain : _radarPerPointCap,
          horizonOverride: lead > 0 ? lead : null,
        );
        done.add(RadarCheckpoint(
          sampleIndex: idx,
          km: samples[idx].kmFromStart,
          arriveAt: arriveTimes[idx],
          verdict: v,
        ));
        final basis = lead <= 0 ? '按当前回波' : '外推 $lead 分钟';
        debugPrint('[雷达定调] ${samples[idx].kmFromStart.round()}km 处'
            '（到达距今 $lead min，$basis）→ ${v.bestModelKey ?? "未定源"}');
      } catch (e) {
        debugPrint('[雷达定调] ${samples[idx].kmFromStart.round()}km 处失败: $e');
      }
    }

    if (done.isEmpty) {
      if (!mounted) return;
      setState(() {
        _verdict = RadarVerdict(
            summary: '雷达定调全部失败（取图或逐帧分析未成功），本次以多源融合为准。');
        _checkpoints = const [];
        _verdictLoading = false;
      });
      return;
    }

    done.sort((a, b) => a.km.compareTo(b.km));
    if (!mounted) return;
    setState(() {
      _checkpoints = done;
      _verdict = done.first.verdict; // 最近那个展开详情
      _verdictLoading = false;
    });

    // ---- 3) 逐点给源：每个采样点用「离它最近的校验点」的结论，
    //         但**仅当它自己的到达时刻也在窗内** ----
    final preferred = List<String?>.filled(samples.length, null);
    for (var i = 0; i < samples.length; i++) {
      if (arriveTimes[i].difference(now).inMinutes > windowMin) continue;
      RadarCheckpoint? best;
      var bestDist = 1 << 30;
      for (final c in done) {
        final d = (c.sampleIndex - i).abs();
        if (d < bestDist) {
          bestDist = d;
          best = c;
        }
      }
      final key = best?.verdict.bestModelKey;
      if (key != null && (best?.verdict.scores.isNotEmpty ?? false)) {
        preferred[i] = key;
      }
    }
    final used = preferred.where((e) => e != null).length;
    debugPrint('[雷达定调] ${done.length} 个校验点 → $used/${samples.length} '
        '个采样点采用雷达定源（其余保持多源融合）');
    if (used > 0) _rebuildWithSource(preferred);
  }

  /// 从下标列表里等间隔取最多 [maxCount] 个（**首尾都保留**）
  ///
  /// 用来把「窗内的采样点」撒成最多 3 个校验点 —— 均匀撒开，而不是全挤在
  /// 起点附近。首尾保留是因为起点（当前实况）和窗内最远点（外推极限）
  /// 恰好是雷达信息价值最高与最低的两个端点，都值得看。
  static List<int> _spreadPick(List<int> idx, int maxCount) {
    if (idx.length <= maxCount) return List<int>.from(idx);
    final out = <int>[];
    for (var k = 0; k < maxCount; k++) {
      out.add(idx[(k * (idx.length - 1) / (maxCount - 1)).round()]);
    }
    return out.toSet().toList()..sort();
  }

  /// 用雷达**逐点判出的源**重建分段详情
  ///
  /// [preferredModels] 与采样点一一对应（元素为 null = 该点保持多源融合）。
  /// 各要素（温度/降水/概率/风速等）改用对应源的值，
  /// 但**多源验证信息（各源数值 + 一致性评分）依然保留**在研判依据里。
  void _rebuildWithSource(List<String?> preferredModels) {
    final opt = _lastOpt;
    if (opt == null || _lastSamples.isEmpty) return;

    final segments = RouteAnalyzer.buildSegments(
      samples: _lastSamples,
      weathers: _lastWeathers,
      departAt: _departAt,
      totalMinutes: opt.durationMinutes,
      totalKm: opt.distanceKm,
      originName: _origin.text.trim(),
      destinationName: _dest.text.trim(),
      fullPolyline: opt.fullPolyline,
      multiModels: _lastMulti,
      preferredModels: preferredModels,
    );

    setState(() {
      _analysis = RouteAnalysis(
        segments: segments,
        totalKm: opt.distanceKm,
        totalMinutes: opt.durationMinutes,
        originName: _origin.text.trim(),
        destinationName: _dest.text.trim(),
        overallGrade: RouteAnalyzer.worstGrade(segments.map((s) => s.grade)),
      );
    });
    debugPrint('[雷达定调] 已按逐点定源重建分段'
        '（${preferredModels.where((e) => e != null).length} 个采样点采用雷达定源）');
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: '出行路线',
      subtitle: '选择实际路线 → 逐段研判沿途天气',
      children: [
        PanelCard(
          heading: '起终点',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        PlaceSearchField(
                          controller: _origin,
                          amap: _amap,
                          icon: Icons.trip_origin,
                          hint: '起点',
                          near: _myLocation,
                          onSelected: (p, tip) {
                            _originPoint = p;
                            debugPrint('[路线] 起点选中「${tip.name}」-> ${p.lat},${p.lon}');
                          },
                          onUseCurrentLocation: () => _applyCurrentLocation(
                            _origin,
                            (p) => _originPoint = p,
                            '起点',
                          ),
                        ),
                        const SizedBox(height: 9),
                        PlaceSearchField(
                          controller: _dest,
                          amap: _amap,
                          icon: Icons.place,
                          hint: '终点',
                          near: _myLocation,
                          onSelected: (p, tip) {
                            _destPoint = p;
                            debugPrint('[路线] 终点选中「${tip.name}」-> ${p.lat},${p.lon}');
                          },
                          onUseCurrentLocation: () => _applyCurrentLocation(
                            _dest,
                            (p) => _destPoint = p,
                            '终点',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 交换起终点（Row 的 center 对齐 = 两个输入框的中线）
                  _swapButton(),
                ],
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        // 日期选择器：套深色主题，否则是系统默认浅色（与 App 风格不符）
                        final d = await showDatePicker(
                          context: context,
                          initialDate: _departAt,
                          firstDate: DateTime.now().subtract(const Duration(days: 1)),
                          lastDate: DateTime.now().add(const Duration(days: 7)),
                          builder: (ctx, child) =>
                              Theme(data: AppTheme.pickerTheme(ctx), child: child!),
                        );
                        if (d == null) return;
                        if (!context.mounted) return;
                        final t = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(_departAt),
                          builder: (ctx, child) =>
                              Theme(data: AppTheme.pickerTheme(ctx), child: child!),
                        );
                        if (t == null) return;
                        setState(() {
                          _departAt = DateTime(d.year, d.month, d.day, t.hour, t.minute);
                        });
                      },
                      icon: const Icon(Icons.schedule, size: 18),
                      label: Text(
                        '出发时间：${_departAt.month}/${_departAt.day} '
                        '${_departAt.hour.toString().padLeft(2, '0')}:${_departAt.minute.toString().padLeft(2, '0')}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.text,
                        side: const BorderSide(color: AppTheme.border),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 「现在出发」——最常用的一档。原先只能进日期 + 时间两个
                  // 选择器里把时刻拨到"现在"，既费事又拨不准（拨完就过了）。
                  OutlinedButton(
                    onPressed: (_analyzing || _isDepartingNow && _analysis != null)
                        ? null
                        : _departNow,
                    style: OutlinedButton.styleFrom(
                      foregroundColor:
                          _isDepartingNow ? AppTheme.accent : AppTheme.text,
                      side: BorderSide(
                        color: _isDepartingNow ? AppTheme.accent : AppTheme.border,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bolt, size: 17),
                        SizedBox(width: 4),
                        Text('现在出发'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _planning ? null : _plan,
                icon: _planning
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF14100A)))
                    : const Icon(Icons.alt_route, size: 19),
                label: Text(_planning ? '规划中…' : '规划路线'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: AppTheme.red, fontSize: 12.5)),
              ],
            ],
          ),
        ),

        // ===== 候选路线：让用户选实际要走的那条 =====
        if (_options.isNotEmpty)
          PanelCard(
            heading: '选择你的实际路线（${_options.length} 条候选）',
            child: Column(
              children: [
                for (final opt in _options) _optionTile(opt),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _analyzing ? null : () => _analyze(_options[_selectedIndex]),
                  icon: _analyzing
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF14100A)))
                      : const Icon(Icons.insights, size: 19),
                  label: Text(_analyzing ? '研判中…' : '按此路线生成研判'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  ),
                ),
              ],
            ),
          ),

        // ===== 未研判时：路线地图（显示候选路线）=====
        if (_options.isNotEmpty && _analysis == null)
          PanelCard(
            heading: '路线地图 · 点候选路线自动缩放',
            padding: const EdgeInsets.all(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 320,
                child: AmapView(
                  lat: _options[_selectedIndex].polyline.first.lat,
                  lon: _options[_selectedIndex].polyline.first.lon,
                  zoom: 10,
                  markers: _routeMarkers(),
                  polylines: _routePolylines(),
                  fitPoints: _currentFitPoints(),
                  interactive: true, // 可缩放拖动
                ),
              ),
            ),
          ),

        // 部分采样点没取到数据时的降级提示（非致命，但必须让用户看见 ——
        // 否则缺数据的路段会被当成"天气未知"而无人察觉）
        if (_partialFailNote != null)
          PanelCard(
            heading: '数据完整性提示',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 16, color: AppTheme.accent),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _partialFailNote!,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textDim, height: 1.5),
                  ),
                ),
              ],
            ),
          ),

        if (_analysis != null) ..._analysisWidgets(_analysis!),

        // ===== 台风 × 路线重叠（沿程逐点比对，异步加载）=====
        if (_typhoonRoute != null)
          FadeSlideIn(delayMs: 150, child: _typhoonRouteCard(_typhoonRoute!)),
      ],
    );
  }

  Widget _optionTile(RouteOption opt) {
    final sel = opt.index == _selectedIndex;
    return InkWell(
      onTap: () => _selectRoute(opt.index),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: sel ? AppTheme.accentDim : AppTheme.bgInset,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: sel ? AppTheme.accent : AppTheme.border),
        ),
        child: Row(
          children: [
            Icon(
              sel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 19,
              color: sel ? AppTheme.accent : AppTheme.textFaint,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    opt.summary,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: sel ? AppTheme.accent : AppTheme.text,
                    ),
                  ),
                  if (opt.detail.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(opt.detail,
                        style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 台风 × 路线（计划任务 4-1）====================

  /// 把分段结果摊平成台风分析用的采样点（带里程与到达时刻）
  List<RouteSample> _routeSamples(RouteAnalysis a) {
    final out = <RouteSample>[];
    for (final seg in a.segments) {
      final pts = seg.points;
      if (pts.isEmpty) continue;
      final spanMs = seg.endTime.difference(seg.startTime).inMilliseconds;
      final spanKm = seg.endKm - seg.startKm;
      for (var i = 0; i < pts.length; i++) {
        final frac = pts.length == 1 ? 0.0 : i / (pts.length - 1);
        out.add(RouteSample(
          km: seg.startKm + spanKm * frac,
          time: seg.startTime.add(Duration(milliseconds: (spanMs * frac).round())),
          lat: pts[i].lat,
          lon: pts[i].lon,
          label: '${seg.fromName} → ${seg.toName}',
        ));
      }
    }
    return out;
  }

  /// 拉当前活跃台风 → 与路线做重叠分析
  Future<void> _runTyphoonRoute(RouteAnalysis? a) async {
    if (a == null) return;
    try {
      final list = await _nmc.typhoonList();
      Typhoon? active;
      for (final t in list) {
        if (t.isActive) {
          active = t;
          break;
        }
      }
      if (active == null) {
        debugPrint('[台风×路线] 当前无活跃台风');
        if (mounted) setState(() => _typhoonRoute = null);
        return;
      }

      final detail = await _nmc.typhoonTrack(active.id);
      final impact = TyphoonVerdictEngine.routeImpact(
        typhoon: detail,
        samples: _routeSamples(a),
      );
      debugPrint('[台风×路线] ${impact.typhoonName} 受影响=${impact.affected} '
          '最近=${impact.nearestKm?.round()}km 路段=${impact.segments.length} '
          '机构分歧=${impact.agencySpreadKm.round()}km');
      if (!mounted) return;
      setState(() => _typhoonRoute = impact);
    } catch (e) {
      debugPrint('[台风×路线] 失败: $e');
    }
  }

  /// 台风 × 路线卡片
  Widget _typhoonRouteCard(RouteTyphoonImpact im) {
    final risk = im.worstRisk;
    final c = !im.affected
        ? AppTheme.green
        : (risk == '高' ? AppTheme.red : AppTheme.orange);

    return PanelCard(
      heading: '台风 × 路线 · ${im.typhoonName}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 结论横幅
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: c.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.withValues(alpha: .45)),
            ),
            child: Row(
              children: [
                Icon(im.affected ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                    size: 17, color: c),
                const SizedBox(width: 9),
                Text(
                  im.affected ? '路线受影响（风险$risk）' : '全程无台风影响',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c),
                ),
                const Spacer(),
                if (im.nearestKm != null)
                  Text('最近 ${im.nearestKm!.round()} km',
                      style: TextStyle(fontSize: 12, color: c.withValues(alpha: .9))),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(im.advice,
              style: const TextStyle(fontSize: 12.5, color: AppTheme.text, height: 1.55)),

          // 最近点
          if (im.nearestKm != null) ...[
            const SizedBox(height: 10),
            _kv('全程最近', '${im.nearestKm!.round()} km'
                '${im.nearestKmMark == null ? '' : '（约 ${im.nearestKmMark!.round()} km 处）'}'),
            if (im.nearestTime != null)
              _kv('对应时刻', _hhmm(im.nearestTime!)),
            if (im.nearestLabel != null) _kv('所在路段', im.nearestLabel!),
          ],

          // 机构分歧
          const SizedBox(height: 4),
          _kv('机构分歧',
              im.agencyCount < 2
                  ? '仅 ${im.agencyCount} 家机构预报，无法比较'
                  : '约 ${im.agencySpreadKm.round()} km（${im.agencyCount} 家机构）'),

          // 受影响路段
          if (im.segments.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('受影响路段',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textFaint,
                    letterSpacing: .6)),
            const SizedBox(height: 6),
            ...im.segments.map((s) {
              final sc = s.risk == '高' ? AppTheme.red : AppTheme.orange;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: sc.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: sc.withValues(alpha: .45)),
                      ),
                      child: Text(s.risk,
                          style: TextStyle(
                              fontSize: 10, fontWeight: FontWeight.w700, color: sc)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 62,
                      child: Text('${s.km.round()} km',
                          style: const TextStyle(fontSize: 12, color: AppTheme.text)),
                    ),
                    Expanded(
                      child: Text(
                        '距中心 ${s.distanceKm.round()} km · ${s.levelText}'
                        '${s.windSpeed == null ? '' : ' · ${s.windSpeed!.round()} m/s'}',
                        style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              '沿路线共比对 ${im.sampleCount} 个采样点，均未进入 7 级风圈。',
              style: const TextStyle(fontSize: 11.5, color: AppTheme.textFaint),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _analysisWidgets(RouteAnalysis a) {
    // 默认展开第 1 段；点击横向路线条可切换
    final segIdx = _selectedSegment.clamp(0, a.segments.length - 1);
    final seg = a.segments[segIdx];

    return [
      // ===== 简报头（对应 demo 的 brief-head）=====
      PanelCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('出行天气简报',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppTheme.text)),
                      const SizedBox(height: 3),
                      Text(
                        '${a.originName} → ${a.destinationName} · 驾车 '
                        '${a.totalKm.toStringAsFixed(0)}km · 预计 ${_dur(a.totalMinutes)}',
                        style: const TextStyle(fontSize: 12.5, color: AppTheme.textDim),
                      ),
                    ],
                  ),
                ),
                _gradeChip(a.overallGrade),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _metric('总里程', '${a.totalKm.toStringAsFixed(0)} km'),
                _metric('预计耗时', _dur(a.totalMinutes)),
                _metric('分段数', '${a.segments.length}'),
              ],
            ),
          ],
        ),
      ),

      // ===== 路线地图：显示当前选中分段的路线（放在分段卡片上方，便于对照）=====
      PanelCard(
        heading: '路线地图 · SEG ${seg.index.toString().padLeft(2, '0')} '
            '（${seg.startKm.toStringAsFixed(0)}-${seg.endKm.toStringAsFixed(0)}km）',
        padding: const EdgeInsets.all(12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 300,
            child: AmapView(
              lat: _mapAnchorLat(seg, a),
              lon: _mapAnchorLon(seg, a),
              zoom: 12,
              markers: _routeMarkers(),
              polylines: _routePolylines(),
              fitPoints: _currentFitPoints(),
              interactive: true,
            ),
          ),
        ),
      ),

      // ===== 横向路线条（站点 — SEG — 站点，点击切换分段）=====
      PanelCard(
        heading: '路线分段 · 点击查看该段路线',
        child: _horizontalRouteLine(a),
      ),

      // ===== 当前选中段的详情（对应 demo 的 seg-detail）=====
      _segmentDetailCard(seg),

      // ===== 雷达定调：模型分歧时用真实雷达回波裁决 =====
      if (_verdictLoading || _verdict != null) _radarVerdictCard(),
    ];
  }

  /// 雷达定调卡片
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
    final lead = _verdictLeadMinutes ?? 0;
    final nowcastWindow = RadarService.forecastMaxMinutes;
    final withinNowcast = lead > 0 && lead <= nowcastWindow;
    return PanelCard(
      // 超出外推范围时雷达**不参与定调**，标题也要跟着变，
      // 否则用户会以为下方内容仍是「雷达裁决出来的结果」。
      // 另外补一种情况：`radar == null` 且无打分 = 雷达根本没跑起来
      // （覆盖范围外 / 取图失败 / 上游数据缺失），标题必须如实说明，
      // 不能让一张只有一行 summary 的卡片顶着「雷达定调」的名头。
      heading: v.radar == null && v.scores.isEmpty
          ? '雷达定调 · 本次未运行'
          : (v.beyondNowcast ? '雷达实况 · 未参与定调' : '雷达定调 · 真实回波校验'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (v.beyondNowcast)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: AppTheme.bgInset,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.borderSoft),
              ),
              child: const Text(
                '目标时刻超出雷达外推有效范围 → 不参与定调，以多源融合为准',
                style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.textDim,
                    fontWeight: FontWeight.w600),
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
              child: const Text(
                '模型分歧较大 → 以雷达实况定调',
                style: TextStyle(fontSize: 11.5, color: AppTheme.accent, fontWeight: FontWeight.w600),
              ),
            ),
          if (r != null) ...[
            // 数据源徽章 —— 让用户看见定调用的是**单站高精度**图还是**拼图兜底**
            Row(
              children: [
                Icon(r.fromStation ? Icons.radar : Icons.public,
                    size: 13,
                    color: r.fromStation ? AppTheme.green : AppTheme.textDim),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '${r.sourceLabel} · ${r.kmPerPixel.toStringAsFixed(2)} km/像素'
                    '${r.fromStation ? "（单站高精度）" : "（拼图兜底）"}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: r.fromStation ? AppTheme.green : AppTheme.textDim,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _metric('雷达回波', r.echoText),
                _metric('全图覆盖', '${r.coverage.toStringAsFixed(1)}%'),
                _metric('区域最强', '${r.maxDbz} dBZ'),
              ],
            ),
            const SizedBox(height: 8),
            if (r.rainNow != null && r.rainNow! >= 0.1)
              _kv('反演降水', '${r.rainNow!.toStringAsFixed(1)} mm/h（Z-R 关系）'),
            if (r.motionSpeedKmh != null && r.motionSpeedKmh! > 1)
              _kv('回波移动',
                  '向${r.motionDirection} ${r.motionSpeedKmh!.toStringAsFixed(0)} km/h（${r.framesUsed} 帧追踪）'),

            // 出发时刻决定雷达的使用方式（与地点页点选未来时刻同一套逻辑）
            // 雷达校验点是沿途多点里**最近的那个**，时距按它自己的到达时刻算
            if (withinNowcast)
              _kv('外推时距', '最近校验点到达距今 $lead 分钟，回波按此时距外推')
            else if (lead > nowcastWindow)
              _kv(
                '时距提示',
                '最近校验点到达距今 ${(lead / 60).toStringAsFixed(1)} 小时，已超出雷达外推'
                '有效范围（${nowcastWindow ~/ 60}h）→ 以多源融合为准',
              )
            else if (lead <= 0)
              _kv('时距提示', '最近校验点已到达，按当前实况研判'),

            if (r.expectedRainAhead && withinNowcast)
              _kv('外推预警', '未来 $lead 分钟该区域可能受影响'),
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
            child: Text(
              v.summary,
              style: const TextStyle(fontSize: 12, color: AppTheme.textDim, height: 1.5),
            ),
          ),
          // 打分依据：未来时刻用的是**外推预测值**而非实测，必须如实标注
          if (v.scoreBasis.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('打分依据：${v.scoreBasis}',
                style: const TextStyle(
                    fontSize: 10.5, color: AppTheme.textFaint, height: 1.4)),
          ],

          // ===== 沿程校验点 =====
          //
          // 雷达外推只有 2 小时可信，所以校验点**只在这一窗内选**；窗外路段
          // 保持多源融合。这里把每个校验点各判出的源列出来，让用户看得见
          // 「雷达管到哪、从哪开始不管」。
          if (_checkpoints.length > 1) ...[
            const Divider(height: 20, color: AppTheme.borderSoft),
            Row(
              children: [
                const Text('沿程校验点',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textFaint,
                        fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_checkpoints.length} 个 · 仅取外推 ${nowcastWindow ~/ 60}h 窗内',
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 列标题：三列分别是 里程 / 到达时刻 / 判出的源
            const Row(
              children: [
                SizedBox(
                    width: 46,
                    child: Text('里程',
                        style: TextStyle(fontSize: 10, color: AppTheme.textFaint))),
                SizedBox(
                    width: 46,
                    child: Text('到达',
                        style: TextStyle(fontSize: 10, color: AppTheme.textFaint))),
                Expanded(
                    child: Text('判出源',
                        style: TextStyle(fontSize: 10, color: AppTheme.textFaint))),
                Text('分',
                    style: TextStyle(fontSize: 10, color: AppTheme.textFaint)),
              ],
            ),
            const SizedBox(height: 2),
            for (final cp in _checkpoints)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 46,
                      child: Text('${cp.km.round()}km',
                          style: const TextStyle(
                              fontSize: 11.5, color: AppTheme.textDim)),
                    ),
                    SizedBox(
                      width: 46,
                      child: Text(
                        '${cp.arriveAt.hour.toString().padLeft(2, '0')}:'
                        '${cp.arriveAt.minute.toString().padLeft(2, '0')}',
                        style: const TextStyle(
                            fontSize: 11.5, color: AppTheme.textFaint),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        cp.verdict.bestModel ?? '未定源',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: cp.verdict.bestModel == null
                              ? AppTheme.textFaint
                              : AppTheme.accent,
                        ),
                      ),
                    ),
                    Text(
                      cp.verdict.scores.isEmpty
                          ? '—'
                          : '${cp.verdict.scores.first.score}',
                      style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            const Text(
              '每个路段采用离它最近那个校验点的源；落在窗外或校验点未覆盖的路段，保持多源融合。',
              style: TextStyle(fontSize: 10.5, color: AppTheme.textFaint, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(k, style: const TextStyle(fontSize: 11.5, color: AppTheme.textFaint)),
            ),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 12, color: AppTheme.textDim))),
          ],
        ),
      );

  /// 地图锚点纬度（分段点为空时退回起终点/整条路线）
  double _mapAnchorLat(RouteSegment seg, RouteAnalysis a) {
    if (seg.points.isNotEmpty) return seg.points.first.lat;
    if (_from != null) return _from!.lat;
    for (final s in a.segments) {
      if (s.points.isNotEmpty) return s.points.first.lat;
    }
    return 31.2;
  }

  double _mapAnchorLon(RouteSegment seg, RouteAnalysis a) {
    if (seg.points.isNotEmpty) return seg.points.first.lon;
    if (_from != null) return _from!.lon;
    for (final s in a.segments) {
      if (s.points.isNotEmpty) return s.points.first.lon;
    }
    return 121.5;
  }

  /// 横向「站点—分段」线路（严格复刻 demo 的 .route-line）
  Widget _horizontalRouteLine(RouteAnalysis a) {
    final segs = a.segments;
    final rows = <Widget>[];

    for (var i = 0; i < segs.length; i++) {
      final seg = segs[i];
      final isFirst = i == 0;
      final isLast = i == segs.length - 1;

      // 站点圆点 + 名称
      rows.add(_stationDot(
        name: isFirst ? _shortName(a.originName) : _shortName(seg.fromName),
        kind: isFirst ? _StationKind.start : _StationKind.mid,
      ));

      // 分段线（可点击，固定宽度避免被挤压换行）
      rows.add(InkWell(
        onTap: () => setState(() => _selectedSegment = i),
        child: SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: i == _selectedSegment ? AppTheme.accent : AppTheme.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'SEG ${seg.index.toString().padLeft(2, '0')}',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: i == _selectedSegment ? AppTheme.accent : AppTheme.textDim,
                  ),
                ),
                Text(
                  '${seg.startKm.toStringAsFixed(0)}-${seg.endKm.toStringAsFixed(0)}km',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: const TextStyle(fontSize: 9.5, color: AppTheme.textFaint),
                ),
              ],
            ),
          ),
        ),
      ));

      if (isLast) {
        rows.add(_stationDot(
          name: _shortName(a.destinationName),
          kind: _StationKind.end,
        ));
      }
    }

    // 横向可滚动：分段多时也不会挤压换行
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  Widget _stationDot({required String name, required _StationKind kind}) {
    final color = switch (kind) {
      _StationKind.start => AppTheme.accent,
      _StationKind.end => AppTheme.green,
      _StationKind.mid => AppTheme.textDim,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(height: 5),
        SizedBox(
          width: 58,
          child: Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.text, height: 1.2),
          ),
        ),
      ],
    );
  }

  /// 站点简称（横向条空间有限）：优先取常见后缀前的地名
  String _shortName(String s) {
    var t = s.trim();
    for (final suffix in ['站', '工业园区', '园区', '机场', '火车站', '高铁站', '国际机场']) {
      if (t.endsWith(suffix) && t.length > suffix.length) {
        t = t.substring(0, t.length - suffix.length);
        break;
      }
    }
    if (t.length <= 4) return t;
    return '${t.substring(0, 4)}…';
  }

  /// 选中段的详情卡（对应 demo 的 seg-detail pane）
  Widget _segmentDetailCard(RouteSegment seg) {
    final w = seg.weatherText ?? '';
    final tempText = seg.temperature == null ? '--' : '${seg.temperature!.toStringAsFixed(0)}℃';
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 段标题行：SEG 番号 · 起终点    温度 · 天气
          Row(
            children: [
              Icon(_weatherIcon(seg), size: 20, color: AppTheme.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'SEG ${seg.index.toString().padLeft(2, '0')} · ${seg.fromName} → ${seg.toName}',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppTheme.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                w.isEmpty ? tempText : '$tempText · $w',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.textDim),
              ),
            ],
          ),
          // 采用源标识（雷达定调判出最吻合源后，各要素取自该源）
          if (seg.adoptedSource != null) ...[
            const SizedBox(height: 7),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.green.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppTheme.green.withValues(alpha: .45)),
                  ),
                  child: Text(
                    '采用 ${seg.adoptedSource}',
                    style: const TextStyle(
                        fontSize: 10.5, color: AppTheme.green, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 6),
                const Text('（雷达定调最吻合源）',
                    style: TextStyle(fontSize: 10.5, color: AppTheme.textFaint)),
              ],
            ),
          ],
          // 分段依据（说明为什么在这里切段）
          if (seg.splitReason != null) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.content_cut, size: 13, color: AppTheme.textFaint),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    seg.splitReason!,
                    style: const TextStyle(fontSize: 11, color: AppTheme.textFaint, height: 1.35),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _metric('降水', seg.precipitationLevel),
              _metric('降水概率',
                  seg.precipitationProbability == null ? '--' : '${seg.precipitationProbability}%'),
              _metric('风速', seg.windSpeed == null ? '--' : seg.windSpeed!.toStringAsFixed(0)),
              _gradeChip(seg.grade),
            ],
          ),
          const Divider(height: 24, color: AppTheme.borderSoft),
          const Text('研判依据',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textDim, letterSpacing: .6)),
          const SizedBox(height: 8),
          ...seg.basis.map((b) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3.5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 70,
                      child: Text(b.label,
                          style: const TextStyle(fontSize: 11.5, color: AppTheme.textFaint)),
                    ),
                    Expanded(
                      child: Text(b.value,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textDim)),
                    ),
                  ],
                ),
              )),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.bgInset,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderSoft),
            ),
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 12.5, color: AppTheme.textDim, height: 1.5),
                children: [
                  const TextSpan(text: '结论：'),
                  TextSpan(
                    text: _conclusion(seg),
                    style: const TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _weatherIcon(RouteSegment seg) {
    final p = seg.precipitation ?? 0;
    if (p >= 8) return Icons.thunderstorm;
    if (p >= 2.5) return Icons.grain;
    if (p >= 0.1) return Icons.water_drop_outlined;
    final t = seg.temperature ?? 20;
    if (t >= 30) return Icons.wb_sunny_outlined;
    return Icons.cloud_outlined;
  }

  String _conclusion(RouteSegment seg) {
    switch (seg.grade) {
      case '红':
        return '天气较差（${seg.precipitationLevel}），建议改期或改道。';
      case '黄':
        return seg.precipitationLevel == '无雨'
            ? '基本可行，注意${seg.weatherText ?? '天气变化'}，谨慎驾驶。'
            : '该段有${seg.precipitationLevel}，建议携带雨具、减速慢行。';
      default:
        return '天气良好（${seg.precipitationLevel}），可正常行驶，无需雨具。';
    }
  }

  Widget _gradeChip(String grade) {
    final c = AppTheme.gradeColor(grade);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withValues(alpha: .45)),
      ),
      child: Text(
        '$grade · ${_gradeText(grade)}',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c),
      ),
    );
  }

  String _gradeText(String g) {
    switch (g) {
      case '红':
        return '建议改期';
      case '黄':
        return '谨慎出行';
      default:
        return '适宜出行';
    }
  }

  Widget _metric(String k, String v) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint)),
          const SizedBox(height: 3),
          Text(v, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.text)),
        ],
      ),
    );
  }

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _dur(int m) {
    if (m < 60) return '$m 分钟';
    return '${m ~/ 60}h${(m % 60).toString().padLeft(2, '0')}m';
  }
}

/// 横向路线条上的站点类型（决定圆点颜色）
enum _StationKind { start, mid, end }
