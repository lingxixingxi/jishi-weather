import 'package:shared_preferences/shared_preferences.dart';

import 'api_keys.dart';

/// 内置和风天气 Key 的请求预算守卫
///
/// ## 为什么这个比定位配额更要紧
///
/// 和风「免费订阅」是 **1000 次请求/天**（账号级）。而本项目的消耗方式是
/// **按采样点计**的，两者量级完全不同：
///
/// | 场景 | 和风请求数 |
/// |---|---|
/// | 地点查询（单点） | 1 |
/// | 赛道研判（单点） | 1 |
/// | **路线研判（沿途采样）** | **最多 40** ← 大头 |
///
/// 高德定位是「一次操作 = 一次配额」，和风是「**一次操作 = N 次配额**」。
/// 一次长途路线研判就能吃掉日额度的 4%，25 次就见底。
///
/// ## 两道闸（缺一不可）
///
/// 1. **采样点抽稀**（在 `MultiSourceService.fetchMany` 里）—— 只堵上限
///    不减少单次消耗，等于默认「用户一天只准研判 25 次」，体验很差。
///    所以路线页最多只用 [maxPointsPerRun] 个点取和风。
/// 2. **每日请求上限**（本类）—— 兜底，挡住异常重试与连点。
///
/// 内测版、或用户自填 Key → 两道闸都不生效
/// （内测版本就不设限；公测版自填则花他自己的额度）。
///
/// ## 超限后
///
/// **静默跳过和风源**，其余数据源完全不受影响 —— 和风本来就是可选增强源
/// （`isConfigured` 为假时本来就跳过）。
class QWeatherBudget {
  QWeatherBudget._();

  /// 每日请求上限
  ///
  /// 和风免费订阅 1000 次/天，取 800 留 20% 余量 —— 既避免贴边触发限流，
  /// 也给用户在同一账号下的其他调用留空间。
  static const int dailyLimit = 800;

  /// 路线页单次研判最多用几个采样点取和风
  ///
  /// 不抽稀的话，40 点的长途路线一次就是 40 次请求；抽到 8 个点后，
  /// 一次研判只花 8 次，800 的日额度可支撑约 **100 次**研判。
  ///
  /// 未被抽中的采样点只是**少一个源**，其余 6 个 Open-Meteo 源照常参与融合 ——
  /// 融合层本就按「有值的源」求均值与极差，缺源不会污染共识。
  static const int maxPointsPerRun = 8;

  static const _kDay = 'qw_budget_day';
  static const _kCount = 'qw_budget_count';

  /// 今日已消耗请求数（跨天自动归零）
  static Future<int> usedToday() async {
    final p = await SharedPreferences.getInstance();
    if (p.getString(_kDay) != _today()) return 0;
    return p.getInt(_kCount) ?? 0;
  }

  /// 还能不能发一次和风请求
  static Future<bool> canSpend() async {
    if (!ApiKeys.qweatherIsMetered) return true; // 内测版 / 用户自填 Key
    return await usedToday() < dailyLimit;
  }

  /// 记一次消耗 —— 必须在**真正发请求之前**调用
  ///
  /// 放在发起前而不是成功后：失败和重试的请求**同样计入和风的调用量**。
  static Future<void> spend() async {
    if (!ApiKeys.qweatherIsMetered) return;
    final p = await SharedPreferences.getInstance();
    final today = _today();
    final cur = p.getString(_kDay) == today ? (p.getInt(_kCount) ?? 0) : 0;
    await p.setString(_kDay, today);
    await p.setInt(_kCount, cur + 1);
  }

  /// 剩余可用请求数（-1 表示不限，即内测版或用户自填了 Key）
  static Future<int> remaining() async {
    if (!ApiKeys.qweatherIsMetered) return -1;
    return dailyLimit - await usedToday();
  }

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}'
        '-${n.day.toString().padLeft(2, '0')}';
  }
}
