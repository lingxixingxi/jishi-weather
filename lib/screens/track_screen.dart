import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/track_circuits.dart';
import '../engine/radar_verdict.dart';
import '../engine/track_verdict.dart';
import '../models/hourly_weather.dart';
import '../services/amap_service.dart';
import '../services/multi_source_service.dart';
import '../services/nmc_city_repository.dart';
import '../services/nmc_service.dart';
import '../services/open_meteo.dart';
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
///
/// 另含计划（阶段 11）要求的两项：
/// - **目标时刻**：当前时刻 / 指定时刻 二选一
/// - **ECMWF 参考** + **Ventusky 坐标核对链接**
class TrackScreen extends StatefulWidget {
  const TrackScreen({super.key});

  @override
  State<TrackScreen> createState() => _TrackScreenState();
}

class _TrackScreenState extends State<TrackScreen> {
  final _extra = OpenMeteoExtraService();
  final _meteo = OpenMeteoService();
  final _nmc = NmcService();
  final _amap = AmapService();
  late final NmcCityRepository _cityRepo = NmcCityRepository(_nmc, _amap);

  /// 多源融合 —— **复用地点查询 / 出行路线页的同一套服务**，
  /// 不再自己逐个拉模型（那样会漏掉中央气象台与和风的融合逻辑）
  late final MultiSourceService _multi =
      MultiSourceService(meteo: _meteo, nmc: _nmc, cityRepo: _cityRepo);

  TrackCircuit _track = kTrackCircuits.first;
  ExtraWeather? _wx;
  TrackVerdict? _verdict;

  /// 目标时刻的多源集合（与地点页同一口径：ECMWF/GFS/ICON + 和风 + 中央气象台）
  MultiModelHourly? _multiAt;

  /// 雷达定调结果（复用 [RadarVerdictEngine]）
  RadarVerdict? _radarVerdict;
  bool _radarLoading = false;

  /// 研判目标时刻；null = 当前时刻
  DateTime? _targetTime;

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
    _meteo.dispose();
    _nmc.dispose();
    _amap.dispose();
    super.dispose();
  }

  /// 多源融合 + 雷达定调 —— **直接复用地点查询 / 出行路线页的同一套服务**
  ///
  /// 这两套都是纯坐标输入、与场景无关：
  /// - `MultiSourceService.fetch()`：ECMWF / GFS / ICON + 和风 + 中央气象台
  /// - `RadarVerdictEngine.judge()`：用真实雷达回波裁决哪个源最吻合
  ///
  /// 对赛道来说雷达尤其有价值：**回波实况是"路面此刻有没有水"最硬的证据**，
  /// 可以直接校验湿滑研判（模型说干、雷达有回波 → 该怀疑模型）。
  Future<void> _runMultiAndRadar(DateTime at) async {
    setState(() => _radarLoading = true);
    try {
      final list = await _multi.fetch(
        lat: _track.lat,
        lon: _track.lon,
        place: _track.name,
        forecastDays: 3,
      );
      final m = _nearestMulti(list, at);
      if (!mounted) return;
      setState(() => _multiAt = m);
      if (m == null) {
        setState(() => _radarLoading = false);
        return;
      }

      final v = await RadarVerdictEngine.judge(
        lat: _track.lat,
        lon: _track.lon,
        models: [m],
        radarPath: _multi.lastRadarPath,
      );
      debugPrint('[赛道] 多源 ${m.sources.length} 源 · 雷达：${v.summary}'
          '（最优=${v.bestModel ?? "—"}）');
      if (!mounted) return;
      setState(() {
        _radarVerdict = v;
        _radarLoading = false;
      });
    } catch (e) {
      debugPrint('[赛道] 多源/雷达定调失败: $e');
      if (mounted) setState(() => _radarLoading = false);
    }
  }

  /// 取最接近目标时刻的多源集合
  static MultiModelHourly? _nearestMulti(List<MultiModelHourly> list, DateTime t) {
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
        forecastDays: 3, // 需要未来逐小时 ET0 推算干燥时间
      );
      final v = TrackVerdictEngine.judge(wx, _targetTime);

      debugPrint('[赛道] ${_track.name} 含水=${v?.waterMm.toStringAsFixed(2)} '
          '分级=${v?.grip.label} 表温=${v?.surfaceTemp?.toStringAsFixed(1)}');
      if (!mounted) return;
      setState(() {
        _wx = wx;
        _verdict = v;
        _loading = false;
      });

      // ===== 多源融合 + 雷达定调（复用地点/路线页同一套，异步不阻塞）=====
      unawaited(_runMultiAndRadar(_targetTime ?? DateTime.now()));
    } catch (e) {
      debugPrint('[赛道] 失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '赛道气象数据拉取失败：$e';
        _loading = false;
      });
    }
  }

  /// 选择目标时刻（日期 + 时间，深色主题）
  Future<void> _pickTargetTime() async {
    final now = DateTime.now();
    final base = _targetTime ?? now;

    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 3)),
      helpText: '选择研判日期',
      builder: (ctx, child) => Theme(data: AppTheme.pickerTheme(ctx), child: child!),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
      helpText: '选择研判时刻',
      builder: (ctx, child) => Theme(data: AppTheme.pickerTheme(ctx), child: child!),
    );
    if (time == null || !mounted) return;

    setState(() {
      _targetTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
    await _load();
  }

  void _useNow() {
    if (_targetTime == null) return;
    setState(() => _targetTime = null);
    _load();
  }

  String _fmtTime(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

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
        FadeSlideIn(delayMs: 20, child: _timeCard()),
        if (_error != null) FadeSlideIn(delayMs: 30, child: _errorCard()),
        if (_loading) FadeSlideIn(delayMs: 40, child: _loadingCard()),
        if (!_loading && _verdict != null) ...[
          FadeSlideIn(delayMs: 40, child: _gripCard(_verdict!)),
          FadeSlideIn(delayMs: 60, child: _metricsCard(_verdict!)),
          FadeSlideIn(delayMs: 80, child: _dryCard(_verdict!)),
          if (_wx != null) FadeSlideIn(delayMs: 100, child: _rainHistoryCard(_wx!)),
          FadeSlideIn(delayMs: 110, child: _radarCard()),
          FadeSlideIn(delayMs: 120, child: _reasonCard(_verdict!)),
        ],
      ],
    );
  }

  /// 弹出赛道选择面板
  ///
  /// ⚠️ **为什么不用 `DropdownButton`**（实测结论）：
  /// 它的菜单项被 Material 强制 `minHeight: kMinInteractiveDimension`（48dp，
  /// 见 Flutter 源码 `_DropdownMenuItemContainer`），无论怎么设 `itemHeight`
  /// 还是压缩 padding 都压不下去。19 条赛道 + 5 个分组共 24 项 ≈ 1160dp，
  /// 展开后直接吃掉整屏、每行还很空。
  /// 底部面板的行高完全自己控制，且手机上拇指更好点。
  Future<void> _pickTrack() async {
    if (_loading) return;
    final picked = await showModalBottomSheet<TrackCircuit>(
      context: context,
      backgroundColor: AppTheme.bgInset,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _TrackPickerSheet(current: _track),
    );
    if (picked != null) _pick(picked);
  }

  Widget _trackPicker() => PanelCard(
        heading: '选择赛道',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 19 条赛道（国内 11 + 海外 8）：平铺标签会挤成好几行且难找，
            // 而下拉菜单又被 Material 的 48dp 下限撑爆 → 用底部弹出面板。
            InkWell(
              onTap: _pickTrack,
              borderRadius: BorderRadius.circular(9),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: AppTheme.bgInset,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _track.name,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.text,
                        ),
                      ),
                    ),
                    const Icon(Icons.unfold_more,
                        size: 17, color: AppTheme.textDim),
                  ],
                ),
              ),
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
  /// 研判时刻选择（计划阶段 11：当前时刻 / 指定时刻 二选一）
  Widget _timeCard() {
    final t = _targetTime;
    final isNow = t == null;
    return PanelCard(
      heading: '研判时刻',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isNow ? Icons.schedule : Icons.event_available,
                  size: 15, color: AppTheme.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isNow ? '当前时刻' : _fmtTime(t),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.text),
                ),
              ),
              if (!isNow)
                TextButton(
                  onPressed: _loading ? null : _useNow,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    foregroundColor: AppTheme.accent,
                  ),
                  child: const Text('回到当前', style: TextStyle(fontSize: 12.5)),
                ),
              OutlinedButton(
                onPressed: _loading ? null : _pickTargetTime,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accent,
                  side: const BorderSide(color: AppTheme.border),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(0, 34),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(isNow ? '选择时刻' : '改时刻',
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            isNow ? '按此刻的气象条件研判路面状态。' : '按所选时刻的气象条件研判（未来 3 天内）。',
            style: const TextStyle(fontSize: 11, color: AppTheme.textFaint),
          ),
        ],
      ),
    );
  }

  /// 多源参考（各模式并列对照）+ Ventusky 坐标核对
  ///
  /// 多源研判 + 雷达定调 —— **复用地点查询 / 出行路线页的同一套服务**
  ///
  /// 雷达回波对赛道的特殊价值：**"路面此刻有没有水"最硬的证据就是回波实况**，
  /// 可以直接校验湿滑研判（模型说干、雷达有回波 → 该怀疑模型）。
  Widget _radarCard() {
    final v = _radarVerdict;
    final m = _multiAt;

    if (v == null && m == null) {
      if (!_radarLoading) return const SizedBox.shrink();
      return const PanelCard(
        heading: '多源研判 · 雷达定调',
        child: Row(
          children: [
            SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent)),
            SizedBox(width: 10),
            Text('正在拉取多源与雷达…',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
          ],
        ),
      );
    }

    final r = v?.radar;
    return PanelCard(
      heading: '多源研判 · 雷达定调${m == null ? "" : " · ${m.sources.length} 源"}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ===== 境外赛道的如实说明 =====
          // 中央气象台与雷达只覆盖中国，境外赛道上这两条链路根本没有数据。
          // 必须说明白，否则「无雷达数据」会被误读成「没有降水」。
          if (_track.isOverseas) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.public, size: 14, color: AppTheme.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '境外赛道：中央气象台实况与雷达（均仅覆盖中国）不可用，'
                    '研判以 Open-Meteo（ECMWF / GFS / ICON）与和风天气的多源融合为准。',
                    style: const TextStyle(
                        fontSize: 11.5, color: AppTheme.textDim, height: 1.45),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],

          // ===== 雷达数据源徽章（单站高精度 / 拼图兜底）=====
          //
          // 这是本轮重构最需要让用户看见的一点：定调到底用的是哪张图、
          // 空间精度多少。单站雷达 0.68 km/像素 是拼图（2.6 km/像素）的约 4 倍。
          if (!_track.isOverseas && r != null) ...[
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
          ],

          // ===== 雷达实况 =====
          if (!_track.isOverseas && r != null) ...[
            Row(
              children: [
                Expanded(
                  child: _radarMetric('雷达回波',
                      r.hasEchoNow ? '${r.dbzNow} dBZ' : '无回波',
                      color: r.hasEchoNow ? AppTheme.cyan : AppTheme.textDim),
                ),
                Expanded(child: _radarMetric('全图覆盖', '${r.coverage.toStringAsFixed(1)}%')),
                Expanded(
                    child:
                        _radarMetric('区域最强', r.maxDbz > 0 ? '${r.maxDbz} dBZ' : '—')),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              '回波移动　${r.motionSpeedKmh == null ? "—" : "${r.motionDirection ?? ""} ${r.motionSpeedKmh!.round()} km/h（${r.framesUsed} 帧追踪）"}',
              style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim),
            ),
            const SizedBox(height: 10),
          ] else if (_radarLoading) ...[
            Row(
              children: const [
                SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.accent)),
                SizedBox(width: 8),
                Text('正在分析雷达回波…',
                    style: TextStyle(fontSize: 11.5, color: AppTheme.textDim)),
              ],
            ),
            const SizedBox(height: 10),
          ],

          // ===== 赛道交叉验证（本页最有用的一条结论）=====
          _crossCheckBanner(),

          // ===== 各源与雷达吻合度 =====
          if (!_track.isOverseas && v != null && v.scores.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('各源与雷达吻合度',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textFaint,
                    letterSpacing: .6)),
            const SizedBox(height: 6),
            ...v.scores.map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 62,
                        child: Text(s.modelName,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: s.modelKey == v.bestModelKey
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: s.modelKey == v.bestModelKey
                                  ? AppTheme.green
                                  : AppTheme.textDim,
                            )),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: s.score / 100,
                            minHeight: 6,
                            backgroundColor: AppTheme.borderSoft,
                            valueColor: AlwaysStoppedAnimation(
                                s.modelKey == v.bestModelKey
                                    ? AppTheme.green
                                    : AppTheme.textFaint),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 26,
                        child: Text('${s.score}',
                            textAlign: TextAlign.right,
                            style:
                                const TextStyle(fontSize: 11.5, color: AppTheme.textDim)),
                      ),
                    ],
                  ),
                )),
            const SizedBox(height: 4),
            Text(v.summary,
                style: const TextStyle(fontSize: 11, color: AppTheme.textFaint, height: 1.4)),
            if (v.scoreBasis.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text('打分依据：${v.scoreBasis}',
                  style: const TextStyle(
                      fontSize: 10.5, color: AppTheme.textFaint, height: 1.4)),
            ],
          ],

          // ===== 该时刻各源数值 =====
          if (m != null) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppTheme.borderSoft),
            const SizedBox(height: 8),
            const Text('该时刻各源数值',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textFaint,
                    letterSpacing: .6)),
            const SizedBox(height: 6),
            ...m.sources.map((s) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 74,
                        child: Text(_shortSource(s.displayName),
                            style: const TextStyle(fontSize: 12, color: AppTheme.text)),
                      ),
                      SizedBox(
                        width: 54,
                        child: Text(
                            s.temperature == null
                                ? '—'
                                : '${s.temperature!.toStringAsFixed(1)}°',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12, color: AppTheme.textDim)),
                      ),
                      SizedBox(
                        width: 64,
                        child: Text(
                            s.precipitation == null
                                ? '—'
                                : '${s.precipitation!.toStringAsFixed(1)}mm',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: (s.precipitation ?? 0) >= 0.1
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: (s.precipitation ?? 0) >= 0.1
                                  ? AppTheme.cyan
                                  : AppTheme.textDim,
                            )),
                      ),
                      Expanded(
                        child: Text(
                            s.precipitationProbability == null
                                ? '—'
                                : '${s.precipitationProbability}%',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12, color: AppTheme.textDim)),
                      ),
                    ],
                  ),
                )),
            const SizedBox(height: 4),
            Text(
              '温度 / 降水 / 降水概率　·　${_fmtTime(m.time)}　'
              '与地点查询页为同一套多源融合',
              style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint, height: 1.4),
            ),
          ],
          const SizedBox(height: 10),
          GestureDetector(
            onTap: _openVentusky,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: AppTheme.bgInset,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppTheme.borderSoft),
              ),
              child: Row(
                children: [
                  const Icon(Icons.open_in_new, size: 14, color: AppTheme.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('在 Ventusky 核对',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.accent)),
                        const SizedBox(height: 2),
                        Text(
                          '${_track.lat.toStringAsFixed(3)}, ${_track.lon.toStringAsFixed(3)}',
                          style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 16, color: AppTheme.textFaint),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openVentusky() async {
    final url = Uri.parse('https://www.ventusky.com/?lat='
        '${_track.lat.toStringAsFixed(3)}&lon=${_track.lon.toStringAsFixed(3)}');
    try {
      final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!ok && mounted) _snack('无法打开浏览器');
    } catch (e) {
      debugPrint('[赛道] 打开 Ventusky 失败: $e');
      if (mounted) _snack('无法打开浏览器');
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  /// 雷达三格指标
  Widget _radarMetric(String label, String value, {Color? color}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint)),
          const SizedBox(height: 3),
          Text(value,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: color ?? AppTheme.text)),
        ],
      );

  /// **雷达实况 × 湿滑研判 的交叉验证**
  ///
  /// 这是把雷达接进赛道页真正的价值：模型的降水预报可能失真，
  /// 但雷达回波是**实况** —— 两者矛盾时必须提醒用户，而不是只报模型结论。
  Widget _crossCheckBanner() {
    final verdict = _verdict;
    final r = _radarVerdict?.radar;
    if (verdict == null || r == null) return const SizedBox.shrink();

    final echo = r.hasEchoNow;
    final dry = verdict.grip == TrackGrip.dry;

    final Color c;
    final IconData icon;
    final String text;

    if (echo && dry) {
      c = AppTheme.orange;
      icon = Icons.warning_amber_rounded;
      text = '雷达显示赛道上方有回波，但含水研判为「干」—— 模型可能低估了降水。'
          '建议以雷达实况为准，先按「微湿」准备。';
    } else if (!echo && !dry) {
      c = AppTheme.yellow;
      icon = Icons.info_outline;
      text = '雷达当前无回波，但含水研判为「${verdict.grip.label}」—— '
          '水分可能来自刚停的雨，也可能依据的是模式预报降水。';
    } else if (echo && !dry) {
      c = AppTheme.red;
      icon = Icons.warning_amber_rounded;
      text = '雷达有回波、含水研判为「${verdict.grip.label}」，两者一致 —— 路面湿滑风险确认。';
    } else {
      c = AppTheme.green;
      icon = Icons.check_circle_outline;
      text = '雷达无回波、含水研判为「干」，两者一致 —— 路面干燥可信。';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: .40)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 8),
          Expanded(
            child:
                Text(text, style: TextStyle(fontSize: 11.5, color: c, height: 1.4)),
          ),
        ],
      ),
    );
  }

  /// 源名简写（表格列宽有限）
  static String _shortSource(String name) {
    const map = {'中央气象台': '央台', '和风天气': '和风'};
    return map[name] ?? name;
  }

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

/// 赛道选择面板（底部弹出）
///
/// ⚠️ **为什么不用 `DropdownButton`**：它的菜单项被 Material 强制
/// `minHeight: kMinInteractiveDimension`（48dp，见 Flutter 源码
/// `_DropdownMenuItemContainer`），`itemHeight` 与 padding 都压不下去；
/// 19 条 + 5 个分组共 24 项展开会直接吃掉整屏，每行还很空（实测）。
///
/// 本面板行高 40dp，分组标题 10.5 号小字，并**在打开时自动滚到当前赛道**。
class _TrackPickerSheet extends StatefulWidget {
  const _TrackPickerSheet({required this.current});

  final TrackCircuit current;

  @override
  State<_TrackPickerSheet> createState() => _TrackPickerSheetState();
}

class _TrackPickerSheetState extends State<_TrackPickerSheet> {
  /// 行高（比 Material 下拉菜单的 48dp 下限紧凑）
  static const double _itemHeight = 40;

  /// 分组标题占位高度（padding 9+3 + 文字行高约 11）
  static const double _headerHeight = 23;

  /// 分组顺序（与 `TrackCircuit.region` 对应）
  static const List<String> _regionOrder = ['华东', '华南', '华北', '西南', '海外'];

  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        ScrollController(initialScrollOffset: _offsetOfCurrent());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 当前赛道在列表中的纵向偏移
  ///
  /// 没有它会很难用：选了「印第安纳波利斯」之后，每次打开面板都从华东
  /// 顶部开始，得手动滑很久才找得到自己选的那条。
  double _offsetOfCurrent() {
    var offset = 0.0;
    for (final region in _regionOrder) {
      final group = kTrackCircuits.where((t) => t.region == region).toList();
      if (group.isEmpty) continue;
      offset += _headerHeight;
      for (final t in group) {
        if (t.name == widget.current.name) {
          // 让当前项上方留出一行上下文，视觉上更自然
          return (offset - _itemHeight).clamp(0.0, double.infinity);
        }
        offset += _itemHeight;
      }
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.58,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部把手
            Container(
              margin: const EdgeInsets.only(top: 9),
              width: 34,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 11, 20, 4),
              child: Row(
                children: [
                  Icon(Icons.sports_motorsports_outlined,
                      size: 16, color: AppTheme.accent),
                  SizedBox(width: 7),
                  Text(
                    '选择赛道',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.text,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                controller: _controller,
                padding: const EdgeInsets.only(bottom: 10),
                children: [
                  for (final region in _regionOrder)
                    ..._regionSection(context, region),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _regionSection(BuildContext context, String region) {
    final group = kTrackCircuits.where((t) => t.region == region).toList();
    if (group.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 9, 20, 3),
        child: Text(
          '— $region —',
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: AppTheme.textFaint,
            letterSpacing: .6,
            height: 1.1,
          ),
        ),
      ),
      for (final t in group)
        InkWell(
          onTap: () => Navigator.of(context).pop(t),
          child: SizedBox(
            height: _itemHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: t.name == widget.current.name
                            ? FontWeight.w700
                            : FontWeight.w400,
                        color: t.name == widget.current.name
                            ? AppTheme.accent
                            : AppTheme.text,
                      ),
                    ),
                  ),
                  if (t.name == widget.current.name)
                    const Icon(Icons.check, size: 16, color: AppTheme.accent),
                ],
              ),
            ),
          ),
        ),
    ];
  }
}
