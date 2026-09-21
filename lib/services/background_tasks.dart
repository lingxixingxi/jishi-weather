import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'weather_alert_service.dart';

/// 后台任务调度（WorkManager）
///
/// 两类任务：
/// · [kHourlyTask]：每小时检查一次天气变化，有变化才通知
/// · [kDailyTask] ：每天一次，由 [WeatherAlertService] 内部判断
///                  「是否已到 23:00 之后且今天还没推送」，再发次日预报
///
/// ⚠️ WorkManager 的周期任务**不保证精确到点**（系统会按电耗/网络情况调度，
/// 最短间隔 15 分钟，实际往往有几分钟到几十分钟的漂移）。
/// 所以「每天 24:00 推送次日天气」的做法是：注册每天一次的周期任务，
/// 由任务内部判断时间是否满足，而不是指望它在 24:00 整点被唤醒。
const kHourlyTask = 'jishi.weather.hourly';
const kDailyTask = 'jishi.weather.daily';

/// 后台任务入口
///
/// 必须是**顶层函数**并标注 `vm:entry-point`，否则 release 构建下
/// AOT 会把没被引用的函数裁掉，后台 isolate 找不到入口。
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    debugPrint('[后台任务] 触发: $task');
    try {
      await WeatherAlertService.init();
      final msg = await WeatherAlertService.checkAndNotify(force: true);
      debugPrint('[后台任务] $task 结果: $msg');
      return true;
    } catch (e) {
      debugPrint('[后台任务] $task 失败: $e');
      return false;
    }
  });
}

class BackgroundTasks {
  BackgroundTasks._();

  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;
    try {
      await Workmanager().initialize(backgroundCallbackDispatcher);
      _inited = true;
      debugPrint('[后台任务] 调度器已初始化');
    } catch (e) {
      debugPrint('[后台任务] 初始化失败: $e');
    }
  }

  // ==================== 每小时变化检查 ====================

  static Future<void> enableHourly() async {
    await init();
    try {
      await Workmanager().registerPeriodicTask(
        kHourlyTask,
        kHourlyTask,
        frequency: const Duration(minutes: 60),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
      debugPrint('[后台任务] 已注册「每小时天气变化检查」');
    } catch (e) {
      debugPrint('[后台任务] 注册每小时任务失败: $e');
    }
  }

  static Future<void> disableHourly() async {
    await init();
    try {
      await Workmanager().cancelByUniqueName(kHourlyTask);
      debugPrint('[后台任务] 已取消每小时任务');
    } catch (e) {
      debugPrint('[后台任务] 取消失败: $e');
    }
  }

  // ==================== 每日次日预报 ====================

  static Future<void> enableDaily() async {
    await init();
    try {
      await Workmanager().registerPeriodicTask(
        kDailyTask,
        kDailyTask,
        // 周期设为 24 小时；具体是否推送由任务内部按「23:00 之后 + 今天没发过」判断。
        // initialDelay 给到 1 小时，避免刚开启就立刻打扰。
        frequency: const Duration(hours: 24),
        initialDelay: const Duration(hours: 1),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
      debugPrint('[后台任务] 已注册「每日次日预报」');
    } catch (e) {
      debugPrint('[后台任务] 注册每日任务失败: $e');
    }
  }

  static Future<void> disableDaily() async {
    await init();
    try {
      await Workmanager().cancelByUniqueName(kDailyTask);
      debugPrint('[后台任务] 已取消每日任务');
    } catch (e) {
      debugPrint('[后台任务] 取消失败: $e');
    }
  }

  /// 按当前设置同步调度状态（设置页改开关后调用）
  static Future<void> syncWithSettings({
    required bool hourly,
    required bool daily,
  }) async {
    if (hourly) {
      await enableHourly();
    } else {
      await disableHourly();
    }
    if (daily) {
      await enableDaily();
    } else {
      await disableDaily();
    }
  }

  /// 已注册任务的状态（供设置页展示，便于排查"到底有没有生效"）
  ///
  /// ⚠️ 不能用 `Workmanager().printScheduledTasks()` —— 它只在桌面端实现，
  /// Android 上会抛 Unsupported operation（实测踩过）。
  /// 这里改用 `isScheduledByUniqueName` 逐个查询。
  static Future<String> describe() async {
    await init();
    final buf = StringBuffer();
    for (final entry in {kHourlyTask: '每小时变化检查', kDailyTask: '每日次日预报'}.entries) {
      try {
        final ok = await Workmanager().isScheduledByUniqueName(entry.key);
        buf.writeln('· ${entry.value}：${ok ? "已注册 ✓" : "未注册"}');
      } catch (e) {
        buf.writeln('· ${entry.value}：查询失败（$e）');
      }
    }
    return buf.toString().trimRight();
  }
}
