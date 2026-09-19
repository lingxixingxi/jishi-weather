import 'package:flutter/material.dart';

import '../engine/route_analyzer.dart';
import '../services/amap_service.dart';
import '../services/open_meteo.dart';
import '../theme/app_theme.dart';
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

  DateTime _departAt = DateTime.now().add(const Duration(hours: 1));

  bool _planning = false;
  bool _analyzing = false;
  String? _error;

  GeoPoint? _from;
  GeoPoint? _to;
  List<RouteOption> _options = const [];
  int _selectedIndex = 0;
  RouteAnalysis? _analysis;

  @override
  void dispose() {
    _origin.dispose();
    _dest.dispose();
    _amap.dispose();
    _meteo.dispose();
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
      final forecasts = await _meteo.fetchMany(
        samples
            .map((s) => (
                  lat: s.point.lat,
                  lon: s.point.lon,
                  place: '${s.kmFromStart.toStringAsFixed(0)}km',
                ))
            .toList(),
        forecastDays: 3,
      );

      final weathers = RouteAnalyzer.pickAtArrival(
        samples: samples,
        pointForecasts: forecasts,
        departAt: _departAt,
        totalMinutes: opt.durationMinutes,
        totalKm: opt.distanceKm,
      );

      final segments = RouteAnalyzer.buildSegments(
        samples: samples,
        weathers: weathers,
        departAt: _departAt,
        totalMinutes: opt.durationMinutes,
        totalKm: opt.distanceKm,
        originName: _origin.text.trim(),
        destinationName: _dest.text.trim(),
      );

      setState(() {
        _analyzing = false;
        _analysis = RouteAnalysis(
          segments: segments,
          totalKm: opt.distanceKm,
          totalMinutes: opt.durationMinutes,
          originName: _origin.text.trim(),
          destinationName: _dest.text.trim(),
          overallGrade: RouteAnalyzer.worstGrade(segments.map((s) => s.grade)),
        );
      });
    } catch (e) {
      setState(() {
        _analyzing = false;
        _error = '$e';
      });
    }
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
                ),
              ],
            ),
          ),

        if (_analysis != null) ..._analysisWidgets(_analysis!),
      ],
    );
  }

  Widget _optionTile(RouteOption opt) {
    final sel = opt.index == _selectedIndex;
    return InkWell(
      onTap: () => setState(() => _selectedIndex = opt.index),
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
    return [
      PanelCard(
        heading: '全程总览',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _gradeChip(a.overallGrade),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${a.originName} → ${a.destinationName}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
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
      for (final seg in a.segments) _segmentCard(seg),
    ];
  }

  Widget _segmentCard(RouteSegment seg) {
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.bgInset,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppTheme.borderSoft),
                ),
                child: Text(
                  'SEG ${seg.index.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textDim, letterSpacing: .5),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${seg.fromName} → ${seg.toName}',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppTheme.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _gradeChip(seg.grade),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _metric('温度', seg.temperature == null ? '—' : '${seg.temperature!.toStringAsFixed(1)}°'),
              _metric('降水', seg.precipitationLevel),
              _metric('降水概率', seg.precipitationProbability == null ? '—' : '${seg.precipitationProbability}%'),
              _metric('风速', seg.windSpeed == null ? '—' : seg.windSpeed!.toStringAsFixed(0)),
            ],
          ),
          const Divider(height: 22, color: AppTheme.borderSoft),
          ...seg.basis.map((b) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 66,
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
        ],
      ),
    );
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
