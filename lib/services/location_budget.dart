import 'package:shared_preferences/shared_preferences.dart';

import 'api_keys.dart';

/// 内置高德 Key 的定位预算守卫
///
/// ## 为什么需要
///
/// 高德「在线定位」是**账号级共享配额**（个人认证开发者 150 万次/月，
/// 且账号下所有 Key 共用这一个池子）。而 App 里五个页面（地点 / 路线 /
/// 台风 / 摄影 / 设置）都会在 `initState` 预热定位 —— 内置 Key 时，
/// **全体公测用户共用的是同一份配额**。
///
/// 没有服务端就做不了全局统计，但可以在客户端**自我约束**，挡住的正是
/// 最危险的那类消耗：**单机高频调用**（连点、循环定位、异常重试）。
///
/// ## 三层保护
///
/// | 层 | 机制 | 位置 |
/// |---|---|---|
/// | 1 | 结果缓存 3 分钟 + 并发去重 | `AmapLocationService` |
/// | 2 | **每日真实定位上限** | 本类 |
/// | 3 | **内测版 / 用户自填 Key → 完全不限** | `ApiKeys.amapAndroidIsMetered` |
///
/// ⚠️ **地图图面显示不消耗配额** —— 高德计费表里根本没有这一项
/// （Android 地图 SDK 是本地渲染）。所以地图的缩放 / 拖动 / 叠加层
/// **完全不受本类限制**，只有「在线定位」计数。
///
/// ## 超限后的行为
///
/// **不报错、不弹窗**，静默降级：
/// 1. 有缓存 → 用缓存（哪怕过了 3 分钟有效期，位置通常还在同一城区）
/// 2. 无缓存 → 返回 null，由调用方走 IP 定位兜底
class LocationBudget {
  LocationBudget._();

  /// 每日真实定位上限（**仅在使用内置 Key 时生效**）
  ///
  /// 定 20 的理由：正常用户一天开三五次 App、每次 1 次定位，用不到 5 次；
  /// 20 留了充足余量，同时把「狂点 / 循环定位」这类滥用挡在门外。
  ///
  /// 按 150 万次/月的账号配额、20 次/天的单机上限估算：
  /// 即使所有活跃用户都跑满，也只有约 **2500 个日活用户**会吃满整个池子。
  static const int dailyLimit = 20;

  static const _kDay = 'loc_budget_day';
  static const _kCount = 'loc_budget_count';

  /// 今日已消耗次数（跨天自动归零）
  static Future<int> usedToday() async {
    final p = await SharedPreferences.getInstance();
    if (p.getString(_kDay) != _today()) return 0;
    return p.getInt(_kCount) ?? 0;
  }

  /// 还能不能发起一次真实定位
  static Future<bool> canSpend() async {
    if (!ApiKeys.amapAndroidIsMetered) return true; // 内测版 / 用户自填 Key
    return await usedToday() < dailyLimit;
  }

  /// 记一次消耗 —— 必须在**真正发起定位之前**调用
  ///
  /// 放在发起前而不是成功后，是因为**超时和失败的请求同样消耗高德配额**。
  static Future<void> spend() async {
    if (!ApiKeys.amapAndroidIsMetered) return;
    final p = await SharedPreferences.getInstance();
    final today = _today();
    final cur = p.getString(_kDay) == today ? (p.getInt(_kCount) ?? 0) : 0;
    await p.setString(_kDay, today);
    await p.setInt(_kCount, cur + 1);
  }

  /// 剩余可用次数
  ///
  /// 返回 **-1 表示不限**（内测版，或用户填了自己的 Key）。
  static Future<int> remaining() async {
    if (!ApiKeys.amapAndroidIsMetered) return -1;
    return dailyLimit - await usedToday();
  }

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}'
        '-${n.day.toString().padLeft(2, '0')}';
  }
}
