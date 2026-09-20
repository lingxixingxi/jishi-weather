import 'package:flutter/material.dart';

import '../data/track_circuits.dart';
import '../engine/track_verdict.dart';
import '../services/open_meteo_extra.dart';
import '../theme/app_theme.dart';
import '../widgets/fade_slide_in.dart';
import 'home_screen.dart' show PanelCard, ScreenScaffold;

/// 赛道研判页
///
/// 面向**赛车场**（预置坐标库，非公路路段），核心是路面湿滑研判：
/// 含水 → 分级（干/微湿/湿/积水）→ 干燥时间预测，外加表面温度与风、能见度。
///
/// 数据源：Open-Meteo 扩展变量（免 key）
/// `et0_fao_evapotranspiration` / `shortwave_radiation` / `cloud_cover` /
/// `relative_humidity_2m` / `wind_speed_10m` / `visibility` / `precipitation`。
class TrackScreen extends StatefulWidget {
  const TrackScreen({super.key});

  @override
  State<TrackScreen> createState() => _TrackScreenState();
}

class _TrackScreenState extends State<TrackScreen> {
  final _extra = OpenMeteoExtraService();

  TrackCircuit _track = kTrackCircuits.first;
  ExtraWeather? _wx;
  TrackVerdict? _verdict;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _extra.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final wx = await _extra.fetch(
        lat: _track.lat,
        lon: _track.lon,
        pastDays: 1, // 需要过去 6h 降水
        forecastDays: 2, // 需要未来逐小时 ET0 推算干燥时间
      );
      final v = TrackVerdictEngine.judge(wx, DateTime.now());
      debugPrint('[赛道] ${_track.name} 含水=${v?.waterMm.toStringAsFixed(2)} '
          '分级=${v?.grip.label} 表温=${v?.surfaceTemp?.toStringAsFixed(1)}');
      if (!mounted) return;
      setState(() {
        _wx = wx;
        _verdict = v;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[赛道] 失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '赛道气象数据拉取失败：$e';
        _loading = false;
      });
    }
  }

  void _pick(TrackCircuit t) {
    if (t.name == _track.name) return;
    setState(() => _track = t);
    _load();
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: '赛道研判',
      subtitle: '赛道湿滑 / 表面温度 / 干燥时间 · 路面状态评估',
      children: [
        FadeSlideIn(child: _trackPicker()),
        if (_error != null) FadeSlideIn(delayMs: 20, child: _errorCard()),
        if (_loading) FadeSlideIn(delayMs: 40, child: _loadingCard()),
        if (!_loading && _verdict != null) ...[
          FadeSlideIn(delayMs: 40, child: _gripCard(_verdict!)),
          FadeSlideIn(delayMs: 60, child: _metricsCard(_verdict!)),
          FadeSlideIn(delayMs: 80, child: _dryCard(_verdict!)),
          if (_wx != null) FadeSlideIn(delayMs: 100, child: _rainHistoryCard(_wx!)),
          FadeSlideIn(delayMs: 120, child: _reasonCard(_verdict!)),
        ],
      ],
    );
  }

  Widget _trackPicker() => PanelCard(
        heading: '选择赛道',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: kTrackCircuits.map((t) {
                final on = t.name == _track.name;
                return GestureDetector(
                  onTap: _loading ? null : () => _pick(t),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      color: on ? AppTheme.accent.withValues(alpha: .15) : AppTheme.bgInset,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: on ? AppTheme.accent : AppTheme.border,
                        width: on ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      t.name,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: on ? AppTheme.accent : AppTheme.text,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.flag_outlined, size: 13, color: AppTheme.textFaint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_track.city} · 单圈 ${_track.lengthKm} km',
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim),
                  ),
                ),
              ],
            ),
            if (_track.note.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                _track.note,
                style: const TextStyle(fontSize: 11, color: AppTheme.textFaint, height: 1.4),
              ),
            ],
          ],
        ),
      );

  Widget _errorCard() => PanelCard(
        heading: '出错了',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, size: 16, color: AppTheme.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_error!,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.red)),
            ),
            TextButton(
              onPressed: _load,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                foregroundColor: AppTheme.accent,
              ),
              child: const Text('重试', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      );

  Widget _loadingCard() => const PanelCard(
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent),
            ),
            SizedBox(width: 10),
            Text('正在拉取赛道气象数据…',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
          ],
        ),
      );

  /// 湿滑状态卡（核心）
  Widget _gripCard(TrackVerdict v) {
    final c = _gripColor(v.grip);
    return PanelCard(
      heading: '路面状态',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: c.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: c.withValues(alpha: .45)),
            ),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c,
                    boxShadow: [
                      BoxShadow(color: c.withValues(alpha: .55), blurRadius: 8, spreadRadius: 1),
                    ],
                  ),
                ),
                const SizedBox(width: 11),
                Text(
                  v.grip.label,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: c),
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('含水',
                        style: TextStyle(fontSize: 10.5, color: c.withValues(alpha: .8))),
                    const SizedBox(height: 2),
                    Text(
                      '${v.waterMm.toStringAsFixed(2)} mm',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(v.grip.shortAdvice,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c)),
          const SizedBox(height: 6),
          Text(v.advice,
              style: const TextStyle(fontSize: 12.5, color: AppTheme.text, height: 1.55)),
        ],
      ),
    );
  }

  /// 指标网格
  Widget _metricsCard(TrackVerdict v) {
    final items = <({String k, String val, Color? c})>[
      (
        k: '表面温度',
        val: v.surfaceTemp == null ? '—' : '${v.surfaceTemp!.toStringAsFixed(1)}°C',
        c: _surfaceTempColor(v.surfaceTemp),
      ),
      (
        k: '气温',
        val: v.airTemp == null ? '—' : '${v.airTemp!.toStringAsFixed(1)}°C',
        c: null,
      ),
      (
        k: '风速',
        val: v.windSpeed == null ? '—' : '${v.windSpeed!.round()} km/h',
        c: null,
      ),
      (
        k: '能见度',
        val: v.visibility == null ? '—' : '${v.visibility!.toStringAsFixed(1)} km',
        c: (v.visibility ?? 99) < 5 ? AppTheme.orange : null,
      ),
      (
        k: '降水概率',
        val: v.precipProb == null ? '—' : '${v.precipProb}%',
        c: (v.precipProb ?? 0) >= 50 ? AppTheme.cyan : null,
      ),
      (
        k: '湿度',
        val: v.humidity == null ? '—' : '${v.humidity!.round()}%',
        c: null,
      ),
    ];

    return PanelCard(
      heading: '关键指标',
      child: LayoutBuilder(builder: (ctx, cons) {
        const gap = 8.0;
        final w = (cons.maxWidth - gap * 2) / 3;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: items
              .map((e) => SizedBox(
                    width: w,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.bgInset,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: AppTheme.borderSoft),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.k,
                              style: const TextStyle(
                                  fontSize: 10.5, color: AppTheme.textFaint)),
                          const SizedBox(height: 5),
                          Text(
                            e.val,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: e.c ?? AppTheme.text,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ))
              .toList(),
        );
      }),
    );
  }

  /// 干燥时间卡
  Widget _dryCard(TrackVerdict v) {
    final never = v.dryMinutes == null;
    final c = never
        ? AppTheme.orange
        : (v.dryMinutes! <= 60 ? AppTheme.green : AppTheme.yellow);
    return PanelCard(
      heading: '预计干燥时间',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(never ? Icons.water_drop_outlined : Icons.wb_sunny_outlined,
                  size: 17, color: c),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  v.dryText,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            never
                ? '当前蒸散率仅 ${v.et0Rate?.toStringAsFixed(3) ?? "--"} mm/h，'
                    '路面水分几乎不会自然蒸发，需等待日照转强或人工处理。'
                : '按未来逐小时蒸散率累减含水推算（当前 ${v.et0Rate?.toStringAsFixed(3) ?? "--"} mm/h）。'
                    '若中途再次降雨，该时间将顺延。',
            style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// 过去 6 小时降水史（小时柱状）
  Widget _rainHistoryCard(ExtraWeather wx) {
    final now = DateTime.now();
    final hour = DateTime(now.year, now.month, now.day, now.hour);
    final past = wx.between(hour.subtract(const Duration(hours: 6)), hour);
    if (past.isEmpty) return const SizedBox.shrink();

    final maxRain = past
        .map((e) => e.precipitation ?? 0)
        .fold(0.0, (a, b) => a > b ? a : b);

    return PanelCard(
      heading: '过去 6 小时降水',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 62,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: past.map((e) {
                final r = e.precipitation ?? 0;
                final ratio = maxRain <= 0 ? 0.0 : (r / maxRain).clamp(0.0, 1.0);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          r <= 0 ? '' : r.toStringAsFixed(1),
                          style: const TextStyle(fontSize: 9, color: AppTheme.cyan),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          height: 4 + ratio * 28,
                          decoration: BoxDecoration(
                            color: r <= 0
                                ? AppTheme.borderSoft
                                : AppTheme.cyan.withValues(alpha: .55 + ratio * .45),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: past
                .map((e) => Expanded(
                      child: Text(
                        '${e.time.hour}时',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 9.5, color: AppTheme.textFaint),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 6),
          Text(
            '累计 ${past.fold(0.0, (a, e) => a + (e.precipitation ?? 0)).toStringAsFixed(1)} mm'
            '（含此刻前 6 个整点，不含当前小时）',
            style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint),
          ),
        ],
      ),
    );
  }

  /// 研判依据卡
  Widget _reasonCard(TrackVerdict v) => PanelCard(
        heading: '研判依据',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...v.reasons.map((r) => Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                            color: AppTheme.accent, borderRadius: BorderRadius.circular(1)),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(r,
                            style: const TextStyle(
                                fontSize: 12, color: AppTheme.textDim, height: 1.5)),
                      ),
                    ],
                  ),
                )),
            Text(
              '数据源 Open-Meteo（ET0 / 短波辐射 / 分层云量 / 能见度），'
              '基准时刻 ${v.at.month}/${v.at.day} ${v.at.hour}时。',
              style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint, height: 1.5),
            ),
          ],
        ),
      );

  // ==================== 颜色 ====================

  Color _gripColor(TrackGrip g) {
    switch (g) {
      case TrackGrip.dry:
        return AppTheme.green;
      case TrackGrip.damp:
        return AppTheme.cyan;
      case TrackGrip.wet:
        return AppTheme.yellow;
      case TrackGrip.flooded:
        return AppTheme.red;
    }
  }

  /// 表面温度配色：过低/过高都提示
  Color? _surfaceTempColor(double? t) {
    if (t == null) return null;
    if (t >= 50) return AppTheme.red;
    if (t >= 40) return AppTheme.orange;
    if (t <= 5) return AppTheme.cyan;
    return null;
  }
}
