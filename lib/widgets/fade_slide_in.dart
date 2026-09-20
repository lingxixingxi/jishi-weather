import 'package:flutter/material.dart';

/// 内容出现时的「淡入 + 轻微上移」
///
/// ## 动效决策（按 animate skill 的门槛逐条判断）
///
/// - **频率**：偶尔（每次查询/研判结果出现时）→ 允许标准动画
/// - **目的**：**防止跳变** —— 结果卡片若凭空出现，视觉上很突兀，
///   淡入上移把「新内容到来」这件事表达清楚
/// - **工具**：`TweenAnimationBuilder`（一次性进入动画，无需状态管理）
/// - **属性**：只用 `opacity` + `transform`（GPU 友好；不动 width/height）
/// - **曲线**：`Curves.easeOutCubic` ≈ `cubic-bezier(0.23, 1, 0.32, 1)`
/// - **时长**：默认 200ms（内容进入属 150~250ms 区间）
/// - **起始**：`translateY 10px`（**不是 scale(0)**，也不是从屏外飞入）
/// - **无障碍**：系统开启「减少动画」时只保留淡入、去掉位移
/// - **stagger**：相邻卡片传 [delayMs] 30~80ms 递增，避免整屏一起冒出来
class FadeSlideIn extends StatelessWidget {
  final Widget child;

  /// 延迟（毫秒）—— 用于列表错峰进入
  final int delayMs;

  /// 位移距离（像素）
  final double offsetY;

  final Duration duration;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.delayMs = 0,
    this.offsetY = 10,
    this.duration = const Duration(milliseconds: 200),
  });

  @override
  Widget build(BuildContext context) {
    // 无障碍：减少动画时保留淡入（帮助理解内容变化），去掉位移
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final dy = reduce ? 0.0 : offsetY;

    return TweenAnimationBuilder<double>(
      // 总时长 = 延迟 + 动画（延迟期间进度保持 0，即「先不动，再淡入」）
      tween: Tween(begin: 0.0, end: 1.0),
      duration: reduce
          ? const Duration(milliseconds: 120)
          : Duration(milliseconds: duration.inMilliseconds + delayMs),
      curve: Curves.easeOutCubic,
      builder: (ctx, t, c) {
        // 错峰：把总进度按 delay 压缩到 0~1
        final totalMs = duration.inMilliseconds + delayMs;
        final p = (!reduce && delayMs > 0)
            ? ((t * totalMs - delayMs) / duration.inMilliseconds).clamp(0.0, 1.0)
            : t;
        final eased = Curves.easeOutCubic.transform(p);
        return Opacity(
          opacity: eased,
          child: Transform.translate(
            offset: Offset(0, dy * (1 - eased)),
            child: c,
          ),
        );
      },
      child: child,
    );
  }
}
