import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_identity.dart';
import 'api_keys.dart';

/// App 内日志环形缓冲 + 导出
///
/// ## 为什么需要
///
/// Android 上 `debugPrint` 只进 logcat —— **用户拿不到，也没法发给我们**。
/// 出问题时只能靠用户口述「点哪儿崩了」，信息量极低。
///
/// 这里把 `debugPrint` 的输出**同时**抄一份进内存环形缓冲，
/// 用户在设置页一键导出成 txt，再经系统分享面板发邮件过来。
///
/// ## 怎么挂上去
///
/// [install] 里**重写全局 `debugPrint`** ——
/// 所以全 App 已有的几百处 `debugPrint` 一处都不用改，自动全部进缓冲。
/// 在 `main()` 最早期调用一次即可。
///
/// ## 隐私与脱敏
///
/// 导出前会做**两件事**，因为日志是要发给别人的：
///
/// 1. **抹掉所有 Key**：`key=xxx` / `api_key=xxx` / `token=xxx` 一律替换成 `***`。
///    高德接口的 Key 是拼在 URL query 里的，服务层日志会把它带出来 ——
///    公测用户填的是**他自己的 Key**，绝不能跟着日志外传。
/// 2. **只导出我们自己写的行**：Flutter 框架的 `debugPrint`（布局溢出警告之类）
///    会按帧刷屏，把有效日志冲掉，所以带 `[` 前缀（本项目的约定）的才收。
class AppLog {
  AppLog._();

  /// 环形缓冲上限（行）
  ///
  /// 2500 行 ≈ 250 KB。一次完整操作（冷启动 → 查地点 → 规划路线 → 看赛道）
  /// 大概产生 60~120 行，够回溯十几轮操作。
  static const int maxLines = 2500;

  static final List<String> _lines = <String>[];
  static bool _hooked = false;
  static String? _lastRaw;
  static int _dropped = 0;

  /// 装了多少行（设置页显示用）
  static int get lineCount => _lines.length;

  /// 是否已经开始记录
  static bool get isRecording => _hooked;

  /// 安装全局 hook —— 在 `main()` 最早期调用一次
  static void install() {
    if (_hooked) return;
    _hooked = true;

    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      add(message);
      original(message, wrapWidth: wrapWidth);
    };

    add('[日志] 开始记录 · 缓冲 $maxLines 行 · 版本 ${AppIdentity.appVersion}');
  }

  /// 收一行
  ///
  /// · 只收带 `[` 前缀的（本项目 debugPrint 的约定），挡掉框架刷屏
  /// · 连续重复行直接丢弃（网络重试失败会连打几十遍同一句）
  static void add(String? message) {
    if (message == null || message.isEmpty) return;

    final s = message.trim();
    if (!s.startsWith('[')) return;

    if (s == _lastRaw) {
      _dropped++;
      return;
    }
    if (_dropped > 0) {
      final n = _dropped;
      _dropped = 0;
      _lines.add('${_stamp()}  （上一行重复 $n 次，已折叠）');
    }
    _lastRaw = s;

    _lines.add('${_stamp()}  $s');
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
  }

  /// 清空缓冲
  static void clear() {
    _lines.clear();
    _lastRaw = null;
    _dropped = 0;
  }

  static String _stamp() {
    final t = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    String p3(int v) => v.toString().padLeft(3, '0');
    return '${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)}.${p3(t.millisecond)}';
  }

  /// 抹掉日志里可能出现的 Key
  ///
  /// 高德/和风的请求参数都是 query 形式（`?key=abcd…`），
  /// 服务层打 URL 时会把 Key 原样带进日志。
  static String sanitize(String text) {
    var out = text.replaceAllMapped(
      RegExp(r'\b(key|api_?key|apikey|token|secret|password)\b\s*[=:]\s*[^&\s]+',
          caseSensitive: false),
      (m) => '${m.group(1)}=***',
    );
    // 兜底：32 位十六进制串（高德 Key 的形态）也不放过
    out = out.replaceAllMapped(
      RegExp(r'\b[0-9a-fA-F]{32}\b'),
      (m) => '***',
    );
    return out;
  }

  /// 生成完整导出文本（含环境头部）
  static String dump() {
    final now = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    final ts = '${now.year}-${p2(now.month)}-${p2(now.day)} '
        '${p2(now.hour)}:${p2(now.minute)}:${p2(now.second)}';

    final b = StringBuffer()
      ..writeln('迹时天气 · 日志导出')
      ..writeln('=' * 60)
      ..writeln('导出时间 : $ts')
      ..writeln('应用版本 : ${AppIdentity.appVersion}'
          '（${ApiKeys.isPublicBuild ? "公测版" : "内测版"}）')
      ..writeln('包名     : ${AppIdentity.packageName}')
      ..writeln('系统     : ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}')
      ..writeln('Key 状态 : 高德Web ${ApiKeys.hasAmapWeb ? "已配置" : "未配置"} · '
          '高德安卓 ${ApiKeys.hasOwnAmapAndroid ? "用户自填" : "内置"} · '
          '和风 ${ApiKeys.hasQweather ? "已配置" : "未配置"}')
      ..writeln('日志行数 : ${_lines.length}（上限 $maxLines，超出后挤掉最旧的）')
      ..writeln('-' * 60)
      ..writeln();

    if (_lines.isEmpty) {
      b.writeln('（缓冲里没有内容 —— 刚启动或刚清空过，请先复现一次问题再导出）');
    } else {
      for (final line in _lines) {
        b.writeln(line);
      }
    }

    b
      ..writeln()
      ..writeln('-' * 60)
      ..writeln('说明：本文件已自动抹除 API Key，可直接发送。');

    return sanitize(b.toString());
  }

  /// 写到文件，返回该文件
  ///
  /// 优先写 App 的外部私有目录（`Android/data/<包名>/files/`）——
  /// 不需要任何存储权限。失败则退回 App 文档目录。
  static Future<File> exportToFile() async {
    Directory? dir;
    try {
      dir = await getExternalStorageDirectory();
    } catch (_) {
      // 部分设备/桌面平台没有外部目录
    }
    dir ??= await getApplicationDocumentsDirectory();

    final now = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    final name = 'jishi-log-${now.year}${p2(now.month)}${p2(now.day)}'
        '-${p2(now.hour)}${p2(now.minute)}${p2(now.second)}.txt';

    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.parent.create(recursive: true);
    await file.writeAsString(dump(), flush: true);
    debugPrint('[日志] 已导出 ${await file.length()} 字节 → ${file.path}');
    return file;
  }
}
