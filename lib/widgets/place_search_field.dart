import 'dart:async';

import 'package:flutter/material.dart';

import '../services/amap_service.dart';
import '../theme/app_theme.dart';

/// 地点搜索输入框（带 **POI 联想候选列表**）
///
/// ⚠️ 为什么必须有候选列表而不是纯文本输入：
/// 很多地点名是**连锁品牌**（「海底捞火锅」「星巴克」「万达广场」），
/// 全国有成百上千家。直接把文本丢给地理编码，返回的是**某一家**
/// （且常不是用户想去的那家），偏差可能有几十公里。
/// 正确做法：输入时实时给出候选，让用户**点选**。
///
/// 用法：
/// ```dart
/// PlaceSearchField(
///   controller: _origin,
///   hint: '输入起点',
///   amap: _amap,
///   near: _myLocation,          // 可选：按距离排序
///   onSelected: (p) { ... },    // 用户点选候选后拿到精确坐标
/// )
/// ```
class PlaceSearchField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;

  /// 用于联想查询的服务
  final AmapService amap;

  /// 用户点选候选后的回调（已含精确坐标）
  final void Function(GeoPoint point, PoiTip tip) onSelected;

  /// 限定城市（可选，提高精度）
  final String? city;

  /// 当前位置/参考点（可选）—— 传了会按距离排序，附近的结果排前面
  final GeoPoint? near;

  /// 左侧图标
  final IconData icon;

  /// 输入框辅助文字（如「出发时间」那种副标题）
  final String? subtitle;

  /// 传入后，输入框右侧会出现一个「定位」按钮，点击即用当前位置
  ///
  /// 出行路线页的起点常用「我的位置」，但之前的组件只能手输/联想，
  /// 用户没法一键填入。
  final VoidCallback? onUseCurrentLocation;

  const PlaceSearchField({
    super.key,
    required this.controller,
    required this.amap,
    required this.onSelected,
    this.hint = '输入地点',
    this.city,
    this.near,
    this.icon = Icons.search,
    this.subtitle,
    this.onUseCurrentLocation,
  });

  @override
  State<PlaceSearchField> createState() => _PlaceSearchFieldState();
}

class _PlaceSearchFieldState extends State<PlaceSearchField> {
  Timer? _debounce;
  List<PoiTip> _tips = const [];
  bool _loading = false;
  bool _open = false;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// 输入变化 → 防抖 350ms → 联想查询（避免每敲一个字都请求）
  void _onChanged(String v) {
    _debounce?.cancel();
    final kw = v.trim();
    if (kw.length < 2) {
      setState(() {
        _tips = const [];
        _open = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(kw));
  }

  Future<void> _search(String kw) async {
    setState(() => _loading = true);
    final loc = widget.near == null
        ? null
        : '${widget.near!.lon.toStringAsFixed(6)},${widget.near!.lat.toStringAsFixed(6)}';
    final list = await widget.amap.inputTips(kw, city: widget.city, location: loc);
    if (!mounted) return;
    setState(() {
      _tips = list;
      _loading = false;
      _open = list.isNotEmpty;
    });
  }

  void _pick(PoiTip tip) {
    final p = tip.point;
    if (p == null) {
      // 少数提示没有坐标（只给行政区），退化为文本
      widget.controller.text = tip.name;
      setState(() => _open = false);
      return;
    }
    widget.controller.text = tip.name;
    setState(() => _open = false);
    widget.onSelected(p, tip);
  }

  @override
  Widget build(BuildContext context) {
    // 无障碍：系统开启「减少动画」时降级为无位移的淡入（不是完全不动）
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    const dur = Duration(milliseconds: 180); // 0.18s，落在 150~250ms 区间

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppTheme.bgInset,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: _open ? AppTheme.accent : AppTheme.borderSoft),
          ),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Icon(widget.icon, size: 17, color: AppTheme.accent),
              ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  onChanged: _onChanged,
                  style: const TextStyle(fontSize: 14, color: AppTheme.text),
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    hintStyle: const TextStyle(fontSize: 13.5, color: AppTheme.textFaint),
                    // ⚠️ 说明文字**不放这里**。
                    // InputDecoration.helperText 会绘制在 TextField 内部下沿，
                    // 而 TextField 又被外层 Container 包着，于是文字落在框**里面**
                    // （用户反馈「把输入框里的小字移出去」）。
                    // 现在改为容器下方的独立 Text（见下方 _subtitleText）。
                    // ⚠️ 边框必须把**所有状态**都设成 none。
                    // 只设 border 不够 —— Flutter 在聚焦/错误时会改用
                    // focusedBorder/errorBorder，未显式指定就回落到主题默认的
                    // OutlineInputBorder，于是外层容器边框内侧又多出一圈琥珀框
                    // （用户反馈「高亮部分没有全部覆盖整个搜索框」）。
                    // 高亮统一由外层 Container 的 border 负责。
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                  ),
                ),
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.8, color: AppTheme.accent),
                  ),
                )
              else if (widget.controller.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    widget.controller.clear();
                    setState(() {
                      _tips = const [];
                      _open = false;
                    });
                  },
                  child: const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: Icon(Icons.close, size: 15, color: AppTheme.textFaint),
                  ),
                ),

              // 「用当前位置」按钮（出行路线页的起点常用）
              if (widget.onUseCurrentLocation != null)
                GestureDetector(
                  onTap: widget.onUseCurrentLocation,
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 2, right: 12),
                    child: Icon(Icons.my_location, size: 17, color: AppTheme.accent),
                  ),
                ),
            ],
          ),
        ),

        // 说明文字：放在**输入框容器外面**（不再用 InputDecoration.helperText，
        // 那个会画在框内部下沿，视觉上像「框里的小字」）
        if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 12, color: AppTheme.textFaint),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    widget.subtitle!,
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint, height: 1.3),
                  ),
                ),
              ],
            ),
          ),

        // ===== 候选列表 =====
        //
        // 动效决策（频率：偶尔 / 目的：空间一致性 + 防止下方内容被顶得跳变）
        // · 工具: AnimatedSize（高度）+ 一次性 fade/scale 进入
        // · 属性: opacity + transform（不动 width/height 的动画，只让 AnimatedSize 控高）
        // · 曲线: easeOutCubic ≈ cubic-bezier(0.23, 1, 0.32, 1)
        // · 时长: 180ms
        // · 起始: scale 0.97（**绝不 scale(0)**），原点在顶部（从输入框下方展开）
        AnimatedSize(
          duration: reduce ? Duration.zero : dur,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: reduce ? Duration.zero : dur,
                  curve: Curves.easeOutCubic,
                  builder: (ctx, t, child) => Opacity(
                    opacity: t,
                    child: Transform.scale(
                      scale: 0.97 + 0.03 * t,
                      alignment: Alignment.topCenter,
                      child: child,
                    ),
                  ),
                  child: _tipsBody(),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }

  Widget _tipsBody() {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.55)),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _tips.length,
        separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderSoft),
        itemBuilder: (_, i) {
          final t = _tips[i];
          return InkWell(
            onTap: () => _pick(t),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    t.hasLocation ? Icons.place_outlined : Icons.map_outlined,
                    size: 15,
                    color: t.hasLocation ? AppTheme.cyan : AppTheme.textFaint,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.name,
                          style: const TextStyle(
                              fontSize: 13.5,
                              color: AppTheme.text,
                              fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (t.subtitle.isNotEmpty)
                          Text(
                            t.subtitle,
                            style: const TextStyle(fontSize: 11, color: AppTheme.textFaint),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (t.hasLocation)
                    const Text('选择',
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.accent, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
