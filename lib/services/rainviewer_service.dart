import 'dart:convert';

import 'package:http/http.dart' as http;

/// RainViewer 雷达瓦片信息
class RainTileInfo {
  /// 瓦片 URL 模板，形如 `https://host/path/256/{z}/{x}/{y}/4/1_1.png`
  final String urlTemplate;

  /// 该帧的时间
  final DateTime time;

  const RainTileInfo({required this.urlTemplate, required this.time});
}

/// RainViewer 雷达瓦片服务
///
/// **免费、免 key、瓦片式** —— 这是解决「雷达图放大模糊」的关键：
/// 中央气象台的拼图是一张 774×1326 的固定分辨率图片（1px≈2.6km），
/// 放大后必然模糊；而瓦片按 z/x/y 分级请求，**任意缩放级别都是清晰的**。
///
/// 文档：https://www.rainviewer.com/api.html
class RainViewerService {
  static const String _metaUrl = 'https://api.rainviewer.com/public/weather-maps.json';

  final http.Client _client;
  RainViewerService({http.Client? client}) : _client = client ?? http.Client();

  /// 取最近一帧雷达瓦片模板
  ///
  /// [colorScheme] 配色方案（0~8，4 = Universal Blue）
  /// [options] 选项：`smooth`_`snow`，如 `1_1` = 平滑 + 无雪
  /// [frameOffset] 取倒数第几帧（0 = 最新）
  Future<RainTileInfo?> latestRadar({
    String colorScheme = '4',
    String options = '1_1',
    int frameOffset = 0,
  }) async {
    try {
      final resp = await _client
          .get(Uri.parse(_metaUrl))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;

      final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final host = j['host'] as String?;
      final radar = j['radar'] as Map<String, dynamic>?;
      final past = (radar?['past'] as List?) ?? const [];
      if (host == null || past.isEmpty) return null;

      final idx = (past.length - 1 - frameOffset).clamp(0, past.length - 1);
      final item = past[idx] as Map;
      final path = item['path'] as String?;
      final ts = item['time'] as int?;
      if (path == null || ts == null) return null;

      return RainTileInfo(
        urlTemplate: '$host$path/256/{z}/{x}/{y}/$colorScheme/$options.png',
        time: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
      );
    } catch (_) {
      return null;
    }
  }

  /// 列出可用于时间轴的全部历史帧
  Future<List<({DateTime time, String path})>> history() async {
    try {
      final resp = await _client
          .get(Uri.parse(_metaUrl))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final past = ((j['radar'] as Map?)?['past'] as List?) ?? const [];
      return past
          .map((e) {
            final m = e as Map;
            return (
              time: DateTime.fromMillisecondsSinceEpoch((m['time'] as int) * 1000),
              path: '${m['path']}',
            );
          })
          .toList();
    } catch (_) {
      return const [];
    }
  }

  void dispose() => _client.close();
}
