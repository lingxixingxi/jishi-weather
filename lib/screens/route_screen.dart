import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../engine/radar_verdict.dart';
import '../engine/route_analyzer.dart';
import '../models/hourly_weather.dart';
import '../services/amap_service.dart';
import '../services/multi_source_service.dart';
import '../services/nmc_city_repository.dart';
import '../services/nmc_service.dart';
import '../services/open_meteo.dart';
import '../theme/app_theme.dart';
import '../widgets/amap_view.dart';
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

class _RouteScreenState extends State<RouteScreen> {
  final _origin = TextEditingController(text: '上海虹桥站');
  final _dest = TextEditingController(text: '苏州工业园区');

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

  GeoPoint? _from;
  GeoPoint? _to;
  List<RouteOption> _options = const [];
  int _selectedIndex = 0;
  RouteAnalysis? _analysis;

  /// 当前展开的分段（横向路线条点击切换）
  int _selectedSegment = 0;

  /// 雷达定调结果（用真实雷达回波裁决模型分歧）
  RadarVerdict? _verdict;
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
      final from = await _amap.geocode(o);
      final to = await _amap.geocode(d);
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
      _analysis = null;
    });
    try {
      // 沿途每 10km 采样
      final samples = AmapService.sampleAlong(opt.polyline, intervalKm: 10);

      // **多源交叉验证**：Open-Meteo 三模型（ECMWF/GFS/ICON）+ 中央气象台
      final multiAll = await _multi.fetchMany(
        samples
            .map((s) => (
                  lat: s.point.lat,
                  lon: s.point.lon,
                  place: '${s.kmFromStart.toStringAsFixed(0)}km',
                ))
            .toList(),
        forecastDays: 3,
      );

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
      _lastSamples = samples;
      _lastMulti = multiAtArrival;
      _lastWeathers = weathers;
      _lastOpt = opt;
      _runRadarVerdict(samples, multiAtArrival);
    } catch (e) {
      setState(() {
        _analyzing = false;
        _error = '$e';
      });
    }
  }

  /// 异步跑雷达定调：用真实雷达回波裁决各模型分歧
  ///
  /// 取路线中点做代表点（雷达图覆盖范围内最可能被关注的区域）。
  Future<void> _runRadarVerdict(
    List<({GeoPoint point, double kmFromStart})> samples,
    List<MultiModelHourly?> multiAtArrival,
  ) async {
    final path = _multi.lastRadarPath;
    if (path == null || samples.isEmpty) return;

    final mid = samples.length ~/ 2;
    final models = mid < multiAtArrival.length ? multiAtArrival[mid] : null;
    if (models == null) return;

    setState(() => _verdictLoading = true);
    try {
      final v = await RadarVerdictEngine.judge(
        lat: samples[mid].point.lat,
        lon: samples[mid].point.lon,
        models: [models],
        radarPath: path,
      );
      if (!mounted) return;
      setState(() {
        _verdict = v;
        _verdictLoading = false;
      });

      // 雷达定调判出了最吻合的源 → 用它重建分段详情
      // （各要素取自该源；「多源验证」信息依然保留）
      if (v.bestModelKey != null && v.scores.isNotEmpty) {
        _rebuildWithSource(v.bestModelKey!);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _verdictLoading = false);
    }
  }

  /// 用雷达定调判出的**最吻合源**重建分段详情
  ///
  /// 各要素（温度/降水/概率/风速等）改用该源的值，
  /// 但**多源验证信息（各源数值 + 一致性评分）依然保留**在研判依据里。
  void _rebuildWithSource(String modelKey) {
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
      preferredModel: modelKey,
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
    debugPrint('[雷达定调] 已按最优源重建分段: $modelKey');
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
              TextField(
                controller: _origin,
                style: const TextStyle(color: AppTheme.text, fontSize: 14.5),
                decoration: const InputDecoration(
                  hintText: '起点',
                  prefixIcon: Icon(Icons.trip_origin, size: 18, color: AppTheme.accent),
                ),
              ),
              const SizedBox(height: 9),
              TextField(
                controller: _dest,
                style: const TextStyle(color: AppTheme.text, fontSize: 14.5),
                decoration: const InputDecoration(
                  hintText: '终点',
                  prefixIcon: Icon(Icons.place, size: 18, color: AppTheme.green),
                ),
              ),
              const SizedBox(height: 9),
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _departAt,
                    firstDate: DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 7)),
                  );
                  if (d == null) return;
                  if (!context.mounted) return;
                  final t = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(_departAt),
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
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.text,
                  side: const BorderSide(color: AppTheme.border),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                ),
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

        if (_analysis != null) ..._analysisWidgets(_analysis!),
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
              child: const Text(
                '模型分歧较大 → 以雷达实况定调',
                style: TextStyle(fontSize: 11.5, color: AppTheme.accent, fontWeight: FontWeight.w600),
              ),
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
              _kv('反演降水', '${r.rainNow!.toStringAsFixed(1)} mm/h（Z-R 关系）'),
            if (r.motionSpeedKmh != null && r.motionSpeedKmh! > 1)
              _kv('回波移动',
                  '向${r.motionDirection} ${r.motionSpeedKmh!.toStringAsFixed(0)} km/h（${r.framesUsed} 帧追踪）'),
            if (r.expectedRainAhead)
              _kv('外推预警', '未来 ${RadarVerdictEngine.horizonMinutes} 分钟该区域可能受影响'),
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

  String _dur(int m) {
    if (m < 60) return '$m 分钟';
    return '${m ~/ 60}h${(m % 60).toString().padLeft(2, '0')}m';
  }
}

/// 横向路线条上的站点类型（决定圆点颜色）
enum _StationKind { start, mid, end }
