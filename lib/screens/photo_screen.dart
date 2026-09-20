import 'package:flutter/material.dart';

import '../engine/photo_index.dart';
import '../services/amap_location_service.dart';
import '../services/amap_service.dart' show GeoPoint;
import '../services/open_meteo_extra.dart';
import '../theme/app_theme.dart';
import '../widgets/fade_slide_in.dart';
import 'home_screen.dart' show PanelCard, ScreenScaffold;

/// 摄影指数页
///
/// 两个指数都基于 Open-Meteo 分层云量（免 key）：
/// - **火烧云**：日落/日出，中高云「适中度」是决定因素（30%~70% 最佳）
/// - **星空**：夜间，总云量是决定因素
///
/// ⚠️ 未纳入月相与光污染（当前无免 key 数据源），界面显式标注该局限。
class PhotoScreen extends StatefulWidget {
  const PhotoScreen({super.key});

  @override
  State<PhotoScreen> createState() => _PhotoScreenState();
}

class _PhotoScreenState extends State<PhotoScreen> {
  final _extra = OpenMeteoExtraService();

  GeoPoint? _ref;
  bool _locating = true;
  bool _loading = true;
  String? _error;

  List<PhotoScore> _sunsets = const [];
  List<PhotoScore> _starry = const [];
  PhotoScore? _selected;

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
        forecastDays: 3,
      );
      final sunsets = PhotoIndexEngine.bestSunsets(wx, days: 3)
        ..sort(PhotoIndexEngine.byScoreDesc);
      final starry = PhotoIndexEngine.bestStarry(wx, days: 3)
        ..sort(PhotoIndexEngine.byScoreDesc);
      final best = PhotoIndexEngine.best([...sunsets, ...starry]);
      debugPrint('[摄影] 日落 ${sunsets.length} 项 / 星空 ${starry.length} 项 / '
          '最佳 ${best?.label} ${best?.score}');
      if (!mounted) return;
      setState(() {
        _sunsets = sunsets;
        _starry = starry;
        _selected = best;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[摄影] 失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '摄影指数数据拉取失败：$e';
        _loading = false;
      });
    }
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
    return ScreenScaffold(
      title: '摄影指数',
      subtitle: '火烧云 / 星空机会评估 · 基于分层云量与通透度',
      children: [
        FadeSlideIn(child: _refCard()),
        if (_error != null) FadeSlideIn(delayMs: 20, child: _errorCard()),
        if (_loading) FadeSlideIn(delayMs: 40, child: _loadingCard()),
        if (!_loading && _selected != null) ...[
          FadeSlideIn(delayMs: 40, child: _bestCard(_selected!)),
          FadeSlideIn(delayMs: 60, child: _listCard('火烧云 · 日落机会', _sunsets)),
          FadeSlideIn(delayMs: 80, child: _listCard('星空机会', _starry)),
          FadeSlideIn(delayMs: 100, child: _factorCard(_selected!)),
          FadeSlideIn(delayMs: 120, child: _limitCard()),
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
        child: Text('暂无可用数据（该点未来 3 天无日出日落数据）。',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
      );

  /// 最佳推荐
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
        ],
      ),
    );
  }

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
                        child: Text(f,
                            style: const TextStyle(
                                fontSize: 12, color: AppTheme.textDim, height: 1.5)),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      );

  /// 局限说明
  Widget _limitCard() => const PanelCard(
        heading: '评分局限',
        child: Text(
          '当前模型**未纳入月相与光污染**：满月会显著压低星空可见度，'
          '城市光污染会让再好的晴天也难以拍到银河。两者都需要额外的数据源，'
          '因此本指数只回答「天气条件是否配合」，'
          '不回答「月亮会不会碍事」。请结合当地实际光环境与农历月相自行判断。',
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
