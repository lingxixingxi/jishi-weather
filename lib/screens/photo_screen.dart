import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/bortle_scale.dart';
import '../engine/photo_index.dart';
import '../engine/solar_calculator.dart';
import '../services/amap_location_service.dart';
import '../services/amap_service.dart' show GeoPoint;
import '../services/open_meteo_extra.dart';
import '../theme/app_theme.dart';
import '../widgets/fade_slide_in.dart';
import 'home_screen.dart' show PanelCard, ScreenScaffold;

/// 摄影指数页
///
/// 两个指数都基于 Open-Meteo（免 key）：
/// - **火烧云**：日落/日出，中高云「适中度」是决定因素
/// - **星空**：云量（要「万里无云」）+ **月光**（月明星稀）+ **光污染 Bortle**
///
/// 月相与月亮位置、黄金时刻、蓝调时刻全部由 App 自行天文计算（[PhotoIndexEngine.dayTimes]），
/// 光污染等级由用户在页面设定并本地记住（计划任务 9-3 的方案）。
class PhotoScreen extends StatefulWidget {
  const PhotoScreen({super.key});

  @override
  State<PhotoScreen> createState() => _PhotoScreenState();
}

class _PhotoScreenState extends State<PhotoScreen> {
  static const String _bortleKey = 'photo_bortle_level';

  /// 展示天数（计划：摄影报告页给出 7 天逐日指数）
  static const int _days = 7;

  final _extra = OpenMeteoExtraService();

  GeoPoint? _ref;
  bool _locating = true;
  bool _loading = true;
  String? _error;

  ExtraWeather? _wx;
  List<PhotoScore> _sunsets = const [];
  List<PhotoScore> _starry = const [];
  PhotoScore? _selected;

  /// 光污染等级（本地记忆，默认取 [BortleScale.defaultLevel]）
  int _bortle = BortleScale.defaultLevel;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _extra.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadBortle();

    GeoPoint? ref;
    try {
      ref = await AmapLocationService.locate(timeout: const Duration(seconds: 10));
    } catch (_) {}
    ref ??= GeoPoint(lat: 31.2304, lon: 121.4737, name: '上海（默认）');
    if (!mounted) return;
    setState(() {
      _ref = ref;
      _locating = false;
    });
    await _load();
  }

  Future<void> _loadBortle() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getInt(_bortleKey);
      if (v != null && mounted) setState(() => _bortle = v.clamp(1, 9));
    } catch (_) {
      // 读不到就用默认值
    }
  }

  Future<void> _load() async {
    final ref = _ref;
    if (ref == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final wx = await _extra.fetch(
        lat: ref.lat,
        lon: ref.lon,
        pastDays: 0,
        forecastDays: _days,
      );
      if (!mounted) return;
      setState(() {
        _wx = wx;
        _loading = false;
      });
      _recompute();
    } catch (e) {
      debugPrint('[摄影] 失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '摄影指数数据拉取失败：$e';
        _loading = false;
      });
    }
  }

  /// 只重算评分（不重新拉数据）—— 改光污染等级时走这条路
  void _recompute() {
    final wx = _wx;
    if (wx == null) return;

    // ⚠️ 列表保持**日期顺序**（今日 → 明日 → 9/22 → …），不要按分数重排：
    // 按分数排会让"9/26"跑到"今日"前面，日期读起来完全是乱的。
    // 「最佳机会」那张卡单独取分数最高的一条即可。
    final sunsets = PhotoIndexEngine.bestSunsets(wx, days: _days);
    final starry = PhotoIndexEngine.bestStarry(wx, days: _days, bortle: _bortle);
    final best = PhotoIndexEngine.best([...sunsets, ...starry]);

    debugPrint('[摄影] 日落 ${sunsets.length} 项 / 星空 ${starry.length} 项 / '
        'Bortle $_bortle / 最佳 ${best?.label} ${best?.score}');

    if (!mounted) return;
    setState(() {
      _sunsets = sunsets;
      _starry = starry;
      _selected = best;
    });
  }

  void _setBortle(int b) {
    if (b == _bortle) return;
    setState(() => _bortle = b);
    _recompute();
    // 本地记住（失败不影响使用）
    SharedPreferences.getInstance().then((p) async {
      try {
        await p.setInt(_bortleKey, b);
      } catch (e) {
        debugPrint('[摄影] Bortle 保存失败: $e');
      }
    });
  }

  Future<void> _relocate() async {
    setState(() => _locating = true);
    GeoPoint? ref;
    try {
      ref = await AmapLocationService.locate(timeout: const Duration(seconds: 12));
    } catch (_) {}
    if (!mounted) return;
    if (ref == null) {
      setState(() => _locating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('定位失败，仍使用当前基准点')),
      );
      return;
    }
    setState(() {
      _ref = ref;
      _locating = false;
    });
    await _load();
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final times = _wx == null ? null : PhotoIndexEngine.dayTimes(_wx!, DateTime.now());

    return ScreenScaffold(
      title: '摄影指数',
      subtitle: '火烧云 / 星空机会评估 · 含月相与光污染',
      children: [
        FadeSlideIn(child: _refCard()),
        FadeSlideIn(delayMs: 20, child: _bortleCard()),
        if (_error != null) FadeSlideIn(delayMs: 30, child: _errorCard()),
        if (_loading) FadeSlideIn(delayMs: 40, child: _loadingCard()),
        if (!_loading && _selected != null) ...[
          FadeSlideIn(delayMs: 40, child: _bestCard(_selected!)),
          if (times != null) FadeSlideIn(delayMs: 50, child: _lightCard(times)),
          FadeSlideIn(delayMs: 60, child: _listCard('火烧云 · 日落机会', _sunsets)),
          FadeSlideIn(delayMs: 80, child: _listCard('星空机会', _starry)),
          FadeSlideIn(delayMs: 100, child: _weekChart()),
          FadeSlideIn(delayMs: 120, child: _factorCard(_selected!)),
          FadeSlideIn(delayMs: 140, child: _limitCard()),
        ],
        if (!_loading && _selected == null && _error == null)
          FadeSlideIn(delayMs: 40, child: _emptyCard()),
      ],
    );
  }

  Widget _refCard() => PanelCard(
        heading: '基准点',
        child: Row(
          children: [
            const Icon(Icons.place_outlined, size: 15, color: AppTheme.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _locating ? '正在定位…' : (_ref?.name.isEmpty ?? true ? '未知位置' : _ref!.name),
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600, color: AppTheme.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _ref == null
                        ? '—'
                        : '${_ref!.lat.toStringAsFixed(4)}, ${_ref!.lon.toStringAsFixed(4)}',
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.textFaint),
                  ),
                ],
              ),
            ),
            OutlinedButton(
              onPressed: _locating || _loading ? null : _relocate,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.accent,
                side: const BorderSide(color: AppTheme.border),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: const Size(0, 34),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(_locating ? '定位中' : '重新定位',
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  /// 光污染等级选择器（本地记忆）
  ///
  /// 计划任务 9-3 的原方案是"用户预存常用机位的 Bortle 等级（本地配置，
  /// 无需在线地图）"—— 光污染是地点属性，用户自己最清楚常去的机位有多暗。
  Widget _bortleCard() => PanelCard(
        heading: '光污染等级（Bortle）',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: List.generate(9, (i) {
                final b = i + 1;
                final on = b == _bortle;
                return GestureDetector(
                  onTap: () => _setBortle(b),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 30,
                    height: 29,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on ? AppTheme.accent.withValues(alpha: .18) : AppTheme.bgInset,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(
                        color: on ? AppTheme.accent : AppTheme.border,
                        width: on ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      '$b',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: on ? AppTheme.accent : AppTheme.textDim,
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Icon(
                  BortleScale.isDarkEnough(_bortle)
                      ? Icons.nightlight_round
                      : Icons.location_city,
                  size: 14,
                  color: BortleScale.isDarkEnough(_bortle) ? AppTheme.green : AppTheme.orange,
                ),
                const SizedBox(width: 7),
                Text(
                  BortleScale.fullOf(_bortle),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: BortleScale.isDarkEnough(_bortle) ? AppTheme.green : AppTheme.orange,
                  ),
                ),
                const SizedBox(width: 8),
                Text('×${BortleScale.factor(_bortle).toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.textFaint)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              BortleScale.descOf(_bortle),
              style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim, height: 1.4),
            ),
            const SizedBox(height: 6),
            const Text(
              '光污染是机位属性，不随天气变化。设定后本地记住，用于星空评分。',
              style: TextStyle(fontSize: 10.5, color: AppTheme.textFaint, height: 1.4),
            ),
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
            Text('正在评估摄影机会…',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
          ],
        ),
      );

  Widget _emptyCard() => const PanelCard(
        heading: '摄影机会',
        child: Text('暂无可用数据（该点未来 7 天无日出日落数据）。',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
      );

  /// 最佳机会
  Widget _bestCard(PhotoScore s) {
    final c = _scoreColor(s.gradeRank);
    return PanelCard(
      heading: '最佳机会',
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
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.kind,
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600,
                            color: c.withValues(alpha: .9))),
                    const SizedBox(height: 5),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text('${s.score}',
                            style: TextStyle(
                                fontSize: 32, fontWeight: FontWeight.w700, color: c, height: 1)),
                        const SizedBox(width: 3),
                        Text('/100',
                            style: TextStyle(fontSize: 12, color: c.withValues(alpha: .7))),
                      ],
                    ),
                  ],
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: c.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.withValues(alpha: .5)),
                  ),
                  child: Text(s.grade,
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700, color: c)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.schedule, size: 13, color: AppTheme.textFaint),
              const SizedBox(width: 6),
              Text(s.label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.text)),
            ],
          ),
          // 分数构成：让"为什么是这个分"一目了然
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.calculate_outlined, size: 13, color: AppTheme.textFaint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(s.formulaText,
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim)),
              ),
            ],
          ),
          // 星空才有月相
          if (s.moon != null) ...[
            const SizedBox(height: 5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.nightlight_outlined, size: 13, color: AppTheme.textFaint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${s.moon!.phaseName} · 照亮 ${s.moon!.illuminationPercent}% · '
                    '高度角 ${s.moon!.altitudeDeg.toStringAsFixed(0)}° · ${s.moon!.interferenceText}',
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 今日光线时刻（日出日落 / 黄金 / 蓝调 / 月出月落）
  Widget _lightCard(DayPhotoTimes t) => PanelCard(
        heading: '今日光线时刻',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _timeRow(Icons.wb_twilight, '日出 / 日落',
                '${DayPhotoTimes.hhmm(t.sunrise)} / ${DayPhotoTimes.hhmm(t.sunset)}'),
            _timeRow(Icons.wb_sunny_outlined, '黄金时刻（晨）',
                '${t.morningGolden.text}${_dur(t.morningGolden)}'),
            _timeRow(Icons.nights_stay_outlined, '蓝调时刻（晨）',
                '${t.morningBlue.text}${_dur(t.morningBlue)}'),
            _timeRow(Icons.wb_sunny_outlined, '黄金时刻（暮）',
                '${t.eveningGolden.text}${_dur(t.eveningGolden)}'),
            _timeRow(Icons.nights_stay_outlined, '蓝调时刻（暮）',
                '${t.eveningBlue.text}${_dur(t.eveningBlue)}'),
            const Divider(height: 14, color: AppTheme.borderSoft),
            _timeRow(Icons.arrow_upward, '月出', DayPhotoTimes.hhmm(t.moonrise)),
            _timeRow(Icons.arrow_downward, '月落', DayPhotoTimes.hhmm(t.moonset)),
            _timeRow(
              Icons.brightness_2_outlined,
              '今晚月相',
              '${t.moonAt23.phaseName} · 照亮 ${t.moonAt23.illuminationPercent}% · '
                  '${t.moonAt23.interferenceText}',
            ),
          ],
        ),
      );

  String _dur(PhotoTimeWindow w) =>
      w.durationText.isEmpty ? '' : '（${w.durationText}）';

  Widget _timeRow(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 13, color: AppTheme.textFaint),
            const SizedBox(width: 7),
            SizedBox(
              width: 92,
              child: Text(label,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textFaint)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.text)),
            ),
          ],
        ),
      );

  /// 机会列表（可点选）
  Widget _listCard(String heading, List<PhotoScore> list) {
    if (list.isEmpty) return const SizedBox.shrink();
    return PanelCard(
      heading: heading,
      child: Column(
        children: list.map((s) {
          final on = _selected?.label == s.label;
          final c = _scoreColor(s.gradeRank);
          return GestureDetector(
            onTap: () => setState(() => _selected = s),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.only(bottom: 7),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: on ? c.withValues(alpha: .09) : AppTheme.bgInset,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: on ? c.withValues(alpha: .5) : AppTheme.borderSoft,
                  width: on ? 1.4 : 1,
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(s.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                          color: on ? AppTheme.text : AppTheme.textDim,
                        )),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: s.score / 100,
                        minHeight: 6,
                        backgroundColor: AppTheme.borderSoft,
                        valueColor: AlwaysStoppedAnimation(c),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 30,
                    child: Text('${s.score}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700, color: c)),
                  ),
                  const SizedBox(width: 7),
                  SizedBox(
                    width: 26,
                    child: Text(s.grade,
                        style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint)),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 7 天逐日指数曲线（计划任务 9-4：摄影报告页给出 7 天逐日指数）
  Widget _weekChart() {
    if (_sunsets.isEmpty && _starry.isEmpty) return const SizedBox.shrink();

    final now = DateTime.now();
    final days = List.generate(
      _days,
      (i) => DateTime(now.year, now.month, now.day).add(Duration(days: i)),
    );

    PhotoScore? onDay(List<PhotoScore> list, DateTime day) {
      for (final s in list) {
        if (s.time.year == day.year && s.time.month == day.month && s.time.day == day.day) {
          return s;
        }
      }
      return null;
    }

    String dayLabel(DateTime d) {
      final diff = d.difference(DateTime(now.year, now.month, now.day)).inDays;
      if (diff == 0) return '今日';
      if (diff == 1) return '明日';
      return '${d.month}/${d.day}';
    }

    return PanelCard(
      heading: '未来 $_days 天趋势',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 96,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: days.map((d) {
                final sun = onDay(_sunsets, d);
                final star = onDay(_starry, d);
                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // 柱子：左=火烧云（琥珀），右=星空（青）
                      SizedBox(
                        height: 70,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _bar(sun?.score, AppTheme.yellow),
                            const SizedBox(width: 3),
                            _bar(star?.score, AppTheme.cyan),
                          ],
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(dayLabel(d),
                          style: const TextStyle(fontSize: 9.5, color: AppTheme.textFaint)),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _legendDot(AppTheme.yellow, '火烧云'),
              const SizedBox(width: 14),
              _legendDot(AppTheme.cyan, '星空'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bar(int? score, Color color) {
    final h = score == null ? 2.0 : (2 + score / 100 * 66).clamp(2.0, 68.0);
    return Container(
      width: 9,
      height: h,
      decoration: BoxDecoration(
        color: score == null ? AppTheme.borderSoft : color.withValues(alpha: .85),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _legendDot(Color c, String label) => Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 10.5, color: AppTheme.textDim)),
        ],
      );

  /// 因子明细
  Widget _factorCard(PhotoScore s) => PanelCard(
        heading: '${s.kind} 评分依据',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...s.factors.map((f) => Padding(
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
                        child: _richText(
                          f,
                          const TextStyle(
                              fontSize: 12, color: AppTheme.textDim, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      );

  /// 把因子文本里的 `**强调**` 渲染成粗体高亮
  Widget _richText(String s, TextStyle base) {
    final spans = <TextSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) {
        spans.add(TextSpan(text: s.substring(last, m.start)));
      }
      spans.add(TextSpan(
        text: m.group(1),
        style: base.copyWith(color: AppTheme.accent, fontWeight: FontWeight.w700),
      ));
      last = m.end;
    }
    if (last < s.length) spans.add(TextSpan(text: s.substring(last)));
    return Text.rich(TextSpan(style: base, children: spans));
  }

  /// 模型说明与残留局限
  Widget _limitCard() => const PanelCard(
        heading: '评分模型',
        child: Text(
          '两层乘法模型：最终分 = 质量分 × 可见性门槛\n'
          '· 火烧云门槛看总云量（阴天直接压制）与低云；\n'
          '· 星空门槛 = 云量（观星要「万里无云」，总云量 5% 以内才满分）'
          ' × 月光因子（月明星稀） × 光污染因子（Bortle）。\n\n'
          '空气质量以 AOD（气溶胶光学厚度）为主指标，缺失时退回 PM2.5。\n'
          '月相、月出月落、黄金时刻、蓝调时刻均由 App 天文计算，'
          '不依赖任何外部数据源。\n\n'
          '时间均为本地时间。星空的 Bortle 等级由你在上方设定并本地记住。',
          style: TextStyle(fontSize: 11.5, color: AppTheme.textDim, height: 1.6),
        ),
      );

  // ==================== 颜色 ====================

  Color _scoreColor(int rank) {
    switch (rank) {
      case 3:
        return AppTheme.green;
      case 2:
        return AppTheme.cyan;
      case 1:
        return AppTheme.yellow;
      default:
        return AppTheme.textFaint;
    }
  }
}
