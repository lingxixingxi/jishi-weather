import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/weather_warning.dart';

/// 中央气象台预警服务（免 key、国内直连）
///
/// ## 为什么拉全国全量
/// 接口的 `province=` / `prov=` 参数实测**会返回站点 500 错误页（HTML）**，
/// 唯一可靠取数方式是 `pageSize=500` 拉全量（实测 `count=209`，约 58 KB），
/// 再在本地按 `alertid` 前 6 位的行政区划码过滤。
///
/// 因此这里做 10 分钟内存缓存：一个页面内多次查询不会重复拉取。
class WarningService {
  static const String _url = 'http://www.nmc.cn/rest/findAlarm?pageNo=1&pageSize=500';

  /// 缓存有效期
  static const Duration cacheTtl = Duration(minutes: 10);

  final http.Client _client;
  WarningService({http.Client? client}) : _client = client ?? http.Client();

  List<WeatherWarning>? _cache;
  DateTime? _cacheAt;

  /// 全国预警全量（带缓存）
  Future<List<WeatherWarning>> all({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _cache != null &&
        _cacheAt != null &&
        now.difference(_cacheAt!) < cacheTtl) {
      return _cache!;
    }

    final resp = await _client.get(
      Uri.parse(_url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 13)',
        'Referer': 'http://www.nmc.cn/',
      },
    ).timeout(const Duration(seconds: 20));

    if (resp.statusCode != 200) {
      throw Exception('预警接口返回 ${resp.statusCode}');
    }

    // 站点在参数异常时会吐 GB2312 的 HTML 错误页，这里显式挡掉
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (body.trimLeft().startsWith('<')) {
      throw Exception('预警接口返回了 HTML（参数或站点异常）');
    }

    final root = jsonDecode(body) as Map<String, dynamic>;
    if (root['code'] != 0) {
      throw Exception('预警接口 code=${root['code']}');
    }
    final list = ((root['data'] as Map?)?['page'] as Map?)?['list'] as List? ?? const [];

    final out = <WeatherWarning>[];
    for (final item in list) {
      if (item is! Map) continue;
      final w = WeatherWarning.parse(item);
      if (w != null) out.add(w);
    }

    _cache = out;
    _cacheAt = now;
    return out;
  }

  /// 与目标 adcode 相关的预警（本区县 / 本市，可选同省），按危险度倒序
  ///
  /// 传入的 adcode 来自高德逆地理编码（6 位，如 `320115`）。
  static List<WeatherWarning> filter(
    List<WeatherWarning> all,
    String? adcode, {
    bool includeProvince = false,
  }) {
    if (adcode == null || adcode.length < 6) return const [];
    final out = <WeatherWarning>[];
    for (final w in all) {
      final scope = w.scopeFor(adcode);
      if (scope == null) continue;
      if (scope == WarningScope.province && !includeProvince) continue;
      out.add(w);
    }
    out.sort((a, b) {
      final c = b.rank.compareTo(a.rank);
      if (c != 0) return c;
      final ta = a.issueTime?.millisecondsSinceEpoch ?? 0;
      final tb = b.issueTime?.millisecondsSinceEpoch ?? 0;
      return tb.compareTo(ta);
    });
    return out;
  }

  /// 一步到位：拉全量 + 过滤
  Future<List<WeatherWarning>> forAdcode(
    String? adcode, {
    bool includeProvince = false,
    bool force = false,
  }) async {
    final all = await this.all(force: force);
    return filter(all, adcode, includeProvince: includeProvince);
  }

  void dispose() => _client.close();
}
