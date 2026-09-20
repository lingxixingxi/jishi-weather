import 'package:flutter/material.dart';

import '../engine/typhoon_verdict.dart';
import '../models/typhoon_track.dart';
import '../services/amap_location_service.dart';
import '../services/amap_service.dart' show GeoPoint;
import '../services/nmc_service.dart';
import '../theme/app_theme.dart';
import '../widgets/fade_slide_in.dart';
import 'home_screen.dart' show PanelCard, ScreenScaffold;

/// 台风研判页
///
/// 数据源：中央气象台台风网（免 key、国内直连）
/// - 列表：`typhoon/jsons/list_default`（JSONP 双括号）
/// - 详情：`typhoon/jsons/view_{id}`（JSONP 单括号，含实况路径 + 多机构预报）
///
/// 研判基准是**参考点**（优先高德混合定位，失败退回上海），
/// 结合「预报路径最近距离 + 7 级风圈 + 台风强度」给出影响等级。
class TyphoonScreen extends StatefulWidget {
  const TyphoonScreen({super.key});

  @override
  State<TyphoonScreen> createState() => _TyphoonScreenState();
}

class _TyphoonScreenState extends State<TyphoonScreen> {
  final _nmc = NmcService();

  bool _loading = true;
  bool _locating = true;
  String? _error;
  List<Typhoon> _list = const [];
  TyphoonDetail? _detail;
  TyphoonImpact? _impact;
  String? _pickedId;
  GeoPoint? _ref;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _nmc.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    // ===== 1) 参考点：优先定位，失败退回上海 =====
    GeoPoint? ref;
    try {
      ref = await AmapLocationService.locate(timeout: const Duration(seconds: 10));
    } catch (_) {
      // 忽略，走兜底
    }
    ref ??= GeoPoint(lat: 31.2304, lon: 121.4737, name: '上海（默认）');
    if (!mounted) return;
    setState(() {
      _ref = ref;
      _locating = false;
    });

    // ===== 2) 台风列表 =====
    try {
      final list = await _nmc.typhoonList();
      if (!mounted) return;
      setState(() => _list = list);

      Typhoon? pick;
      for (final t in list) {
        if (t.isActive) {
          pick = t;
          break;
        }
      }
      pick ??= list.isEmpty ? null : list.first;

      if (pick == null) {
        setState(() => _loading = false);
      } else {
        await _select(pick);
      }
    } catch (e) {
      debugPrint('[台风] 列表失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '台风列表拉取失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _select(Typhoon t) async {
    setState(() {
      _pickedId = t.id;
      _loading = true;
      _error = null;
    });
    try {
      final d = await _nmc.typhoonTrack(t.id);
      if (!mounted) return;
      final ref = _ref;
      final impact = ref == null
          ? null
          : TyphoonVerdictEngine.judge(typhoon: d, lat: ref.lat, lon: ref.lon);
      debugPrint('[台风] ${d.displayName} 实况 ${d.observed.length} 点 / '
          '预报 ${d.forecast.length} 点（${d.forecastAgency ?? "无"}）'
          '→ ${impact?.level.label ?? "未研判"}');
      setState(() {
        _detail = d;
        _impact = impact;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[台风] 详情失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '台风详情拉取失败：$e';
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
        const SnackBar(content: Text('定位失败，仍使用当前参考点')),
      );
      return;
    }
    setState(() {
      _ref = ref;
      _locating = false;
    });
    final d = _detail;
    if (d != null) {
      setState(() {
        _impact = TyphoonVerdictEngine.judge(typhoon: d, lat: ref!.lat, lon: ref.lon);
      });
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: '台风研判',
      subtitle: '中央气象台台风网 · 路径追踪与本地影响评估',
      children: [
        if (_error != null) FadeSlideIn(child: _errorCard()),
        FadeSlideIn(delayMs: 20, child: _refCard()),
        if (_list.isNotEmpty) FadeSlideIn(delayMs: 40, child: _pickerCard()),
        if (_loading) FadeSlideIn(delayMs: 60, child: _loadingCard()),
        if (!_loading && _list.isEmpty && _error == null)
          FadeSlideIn(delayMs: 60, child: _emptyCard()),
        if (!_loading && _detail != null) ...[
          if (_impact != null) FadeSlideIn(delayMs: 60, child: _impactCard(_impact!)),
          FadeSlideIn(delayMs: 80, child: _currentCard(_detail!)),
          if (_detail!.forecast.isNotEmpty)
            FadeSlideIn(delayMs: 100, child: _forecastCard(_detail!)),
        ],
      ],
    );
  }

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
              onPressed: _bootstrap,
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
            Text('正在获取台风路径…', style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
          ],
        ),
      );

  Widget _emptyCard() => const PanelCard(
        heading: '台风动态',
        child: Row(
          children: [
            Icon(Icons.verified_outlined, size: 15, color: AppTheme.green),
            SizedBox(width: 8),
            Expanded(
              child: Text('当前无活跃台风，西北太平洋暂无编号台风活动。',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
            ),
          ],
        ),
      );

  /// 参考点卡片
  Widget _refCard() => PanelCard(
        heading: '研判基准点',
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
              onPressed: _locating ? null : _relocate,
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

  /// 台风选择卡片
  Widget _pickerCard() {
    final active = _list.where((t) => t.isActive).toList();
    final shown = active.isEmpty ? _list.take(6).toList() : active;
    return PanelCard(
      heading: active.isEmpty ? '近期台风（均无活跃）' : '活跃台风 · ${active.length} 个',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: shown.map((t) {
          final on = t.id == _pickedId;
          return GestureDetector(
            onTap: _loading ? null : () => _select(t),
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: t.isActive ? AppTheme.red : AppTheme.textFaint,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    t.displayName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: on ? AppTheme.accent : AppTheme.text,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    t.number,
                    style: const TextStyle(fontSize: 11, color: AppTheme.textFaint),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 影响研判卡片（最核心）
  Widget _impactCard(TyphoonImpact im) {
    final c = _levelColor(im.level);
    return PanelCard(
      heading: '影响研判 · ${im.typhoon.displayName}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 等级横幅
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
                Icon(_levelIcon(im.level), size: 18, color: c),
                const SizedBox(width: 9),
                Text(
                  im.level.label,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c),
                ),
                const Spacer(),
                Text(
                  '最近约 ${(im.nearestKm ?? im.distanceNowKm).round()} km',
                  style: TextStyle(fontSize: 12, color: c.withValues(alpha: .9)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            im.advice,
            style: const TextStyle(fontSize: 12.5, color: AppTheme.text, height: 1.55),
          ),
          const SizedBox(height: 12),
          const Text('研判依据',
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  color: AppTheme.textFaint, letterSpacing: .6)),
          const SizedBox(height: 6),
          ...im.reasons.map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 5),
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
        ],
      ),
    );
  }

  /// 当前实况卡片
  Widget _currentCard(TyphoonDetail d) {
    final p = d.latest;
    if (p == null) {
      return const PanelCard(
        heading: '当前实况',
        child: Text('无实况路径数据', style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
      );
    }
    return PanelCard(
      heading: '当前实况 · ${d.numberText}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${d.displayName}（${d.nameEn}）',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.text),
                ),
              ),
              _badge(d.isActive ? '活跃' : '停编',
                  d.isActive ? AppTheme.red : AppTheme.textFaint),
            ],
          ),
          const SizedBox(height: 10),
          _kv('强度等级', p.levelText, valueColor: _levelColorByCode(p.levelCode)),
          _kv('中心位置', '${p.lat.toStringAsFixed(1)}°N, ${p.lon.toStringAsFixed(1)}°E'),
          _kv('中心气压', p.pressure == null ? '—' : '${p.pressure!.round()} hPa'),
          _kv('最大风速', p.windSpeed == null ? '—' : '${p.windSpeed!.round()} m/s'),
          _kv('移动方向', p.moveDirText),
          _kv('移动速度', p.moveSpeed == null ? '—' : '${p.moveSpeed!.round()} km/h'),
          _kv('观测时刻', _fmt(p.time)),
          if (d.updatedAt != null) _kv('数据更新', d.updatedAt!),
        ],
      ),
    );
  }

  /// 预报路径卡片
  Widget _forecastCard(TyphoonDetail d) => PanelCard(
        heading: '预报路径 · ${d.forecastAgency ?? "机构预报"}（${d.forecast.length} 时次）',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 表头
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: const [
                  SizedBox(width: 74, child: Text('时间', style: _th)),
                  SizedBox(width: 44, child: Text('强度', style: _th)),
                  Expanded(child: Text('中心位置', style: _th)),
                  SizedBox(width: 52, child: Text('气压', style: _th, textAlign: TextAlign.right)),
                  SizedBox(width: 46, child: Text('风速', style: _th, textAlign: TextAlign.right)),
                ],
              ),
            ),
            const Divider(height: 1, color: AppTheme.borderSoft),
            ...d.forecast.map((p) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 74,
                        child: Text(_fmtShort(p.time),
                            style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim)),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          _shortLevel(p.levelCode),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: _levelColorByCode(p.levelCode),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${p.lat.toStringAsFixed(1)}°N ${p.lon.toStringAsFixed(1)}°E',
                          style: const TextStyle(fontSize: 11.5, color: AppTheme.text),
                        ),
                      ),
                      SizedBox(
                        width: 52,
                        child: Text(
                          p.pressure == null ? '—' : '${p.pressure!.round()}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim),
                        ),
                      ),
                      SizedBox(
                        width: 46,
                        child: Text(
                          p.windSpeed == null ? '—' : '${p.windSpeed!.round()}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 11.5, color: AppTheme.textDim),
                        ),
                      ),
                    ],
                  ),
                )),
            const SizedBox(height: 2),
            const Text('气压 hPa · 风速 m/s　路径预报存在不确定性，越靠后误差越大',
                style: TextStyle(fontSize: 10.5, color: AppTheme.textFaint)),
          ],
        ),
      );

  // ==================== 小组件 ====================

  static const _th = TextStyle(
      fontSize: 10.5, fontWeight: FontWeight.w700,
      color: AppTheme.textFaint, letterSpacing: .4);

  Widget _kv(String k, String v, {Color? valueColor}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3.5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 68,
              child: Text(k, style: const TextStyle(fontSize: 12, color: AppTheme.textFaint)),
            ),
            Expanded(
              child: Text(
                v,
                style: TextStyle(
                  fontSize: 12.5,
                  color: valueColor ?? AppTheme.text,
                  fontWeight: valueColor == null ? FontWeight.w400 : FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _badge(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: c.withValues(alpha: .45)),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c)),
      );

  Color _levelColor(TyphoonImpactLevel l) {
    switch (l) {
      case TyphoonImpactLevel.severe:
        return AppTheme.red;
      case TyphoonImpactLevel.alert:
        return AppTheme.orange;
      case TyphoonImpactLevel.watch:
        return AppTheme.yellow;
      case TyphoonImpactLevel.none:
        return AppTheme.green;
    }
  }

  IconData _levelIcon(TyphoonImpactLevel l) {
    switch (l) {
      case TyphoonImpactLevel.severe:
        return Icons.warning_amber_rounded;
      case TyphoonImpactLevel.alert:
        return Icons.error_outline;
      case TyphoonImpactLevel.watch:
        return Icons.visibility_outlined;
      case TyphoonImpactLevel.none:
        return Icons.check_circle_outline;
    }
  }

  /// 强度码 → 颜色
  Color _levelColorByCode(String? code) {
    switch (TyphoonLevel.severity(code)) {
      case 6:
        return AppTheme.red;
      case 5:
        return AppTheme.red;
      case 4:
        return AppTheme.orange;
      case 3:
        return AppTheme.yellow;
      case 2:
        return AppTheme.cyan;
      default:
        return AppTheme.textDim;
    }
  }

  /// 表格用短等级（列宽有限）
  String _shortLevel(String? code) {
    switch (code) {
      case 'TD':
        return '低压';
      case 'TS':
        return '风暴';
      case 'STS':
        return '强风暴';
      case 'TY':
        return '台风';
      case 'STY':
        return '强台风';
      case 'SuperTY':
        return '超强台风';
      default:
        return TyphoonLevel.text(code);
    }
  }

  String _fmt(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _fmtShort(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}时';
}
