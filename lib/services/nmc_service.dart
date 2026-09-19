import 'dart:convert';

import 'package:http/http.dart' as http;

/// 台风信息
class Typhoon {
  final String id;
  final String nameEn;
  final String nameCn;
  final String number; // 编号，如 2625
  final String status; // start(活跃) / stop(停编)
  final String? level; // 强度等级，如 热带低压/TS/TY

  const Typhoon({
    required this.id,
    required this.nameEn,
    required this.nameCn,
    required this.number,
    required this.status,
    this.level,
  });

  bool get isActive => status == 'start';
  String get displayName =>
      (nameCn.isNotEmpty && nameCn != 'nameless') ? nameCn : (nameEn.isEmpty ? '未命名' : nameEn);
}

/// 中央气象台数据源（免 key、国内直连、响应极快）
///
/// ⚠️ 接口是 **HTTP 明文**，App 已开 `usesCleartextTraffic` 才能访问。
/// 台风网返回 **JSONP**：列表双括号 `cb(({...}))`、详情单括号 `cb({...})`，需剥壳。
class NmcService {
  static const String _typhoonList =
      'http://typhoon.nmc.cn/weatherservice/typhoon/jsons/list_default';
  static const String _typhoonView =
      'http://typhoon.nmc.cn/weatherservice/typhoon/jsons/view_';
  static const String _restWeather = 'http://www.nmc.cn/rest/weather';

  final http.Client _client;
  NmcService({http.Client? client}) : _client = client ?? http.Client();

  /// 台风列表
  Future<List<Typhoon>> typhoonList() async {
    final body = await _get(_typhoonList);
    final json = _stripJsonp(body, doubleParen: true);
    final list = (json['typhoonList'] as List?) ?? const [];
    final out = <Typhoon>[];
    for (final item in list) {
      if (item is! List || item.length < 6) continue;
      out.add(Typhoon(
        id: '${item[0]}',
        nameEn: '${item[1]}',
        nameCn: '${item[2]}',
        number: '${item[3]}',
        status: '${item[6] ?? ''}',
        level: item.length > 4 ? '${item[4]}' : null,
      ));
    }
    return out;
  }

  /// 台风详情（含路径点与多机构预报）
  Future<Map<String, dynamic>> typhoonDetail(String id) async {
    final body = await _get('$_typhoonView$id');
    return _stripJsonp(body, doubleParen: false);
  }

  /// 气象站实况（stationid 如 54511 = 北京）
  Future<Map<String, dynamic>> stationWeather(String stationId) async {
    final body = await _get('$_restWeather?stationid=$stationId');
    final root = jsonDecode(body) as Map<String, dynamic>;
    // data 字段是字符串，需二次解析
    final data = root['data'];
    if (data is String && data.isNotEmpty) {
      return jsonDecode(data) as Map<String, dynamic>;
    }
    return root;
  }

  Future<String> _get(String url) async {
    final resp = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('中央气象台返回 ${resp.statusCode}');
    }
    // 台风网为 GBK/UTF-8 混合，优先按 UTF-8 解，失败再退回 latin1 保底
    try {
      return utf8.decode(resp.bodyBytes);
    } catch (_) {
      return latin1.decode(resp.bodyBytes);
    }
  }

  /// 剥掉 JSONP 外壳：`cb(({...}))` 或 `cb({...})`
  Map<String, dynamic> _stripJsonp(String body, {required bool doubleParen}) {
    var s = body.trim();
    final start = s.indexOf(doubleParen ? '((' : '(');
    if (start >= 0) {
      s = s.substring(start + (doubleParen ? 2 : 1));
    }
    final end = s.lastIndexOf(doubleParen ? '))' : ')');
    if (end >= 0) {
      s = s.substring(0, end);
    }
    return jsonDecode(s) as Map<String, dynamic>;
  }

  void dispose() => _client.close();
}
