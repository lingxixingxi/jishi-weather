import 'dart:async';
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

/// 中央气象台城市条目（全国约 2529 个）
class NmcCity {
  final String code; // 接口用 code，如 WwcJd
  final String province; // 上海市
  final String city; // 上海

  const NmcCity({required this.code, required this.province, required this.city});

  /// 用于匹配的关键词（去掉「市/县/区」等后缀）
  String get matchedName {
    var s = city;
    for (final suf in ['市', '县', '区', '自治州', '地区', '盟']) {
      if (s.endsWith(suf) && s.length > suf.length) {
        s = s.substring(0, s.length - suf.length);
        break;
      }
    }
    return s;
  }
}

/// 中央气象台逐小时实测点（来自 passedchart，过去 24 小时）
class NmcHourlyPoint {
  final DateTime time;
  final double? temperature;
  final double? rain1h;
  final double? humidity;
  final double? pressure;
  final double? windSpeed; // m/s
  final double? windDirection; // 度

  const NmcHourlyPoint({
    required this.time,
    this.temperature,
    this.rain1h,
    this.humidity,
    this.pressure,
    this.windSpeed,
    this.windDirection,
  });
}

/// 中央气象台未来预报（predict.detail，7 天）
class NmcDailyForecast {
  final String date;
  final String? dayText;
  final String? nightText;
  final double? dayTemp;
  final double? nightTemp;
  final double? precipitation;
  final String? dayWindDirect;
  final String? dayWindPower;

  const NmcDailyForecast({
    required this.date,
    this.dayText,
    this.nightText,
    this.dayTemp,
    this.nightTemp,
    this.precipitation,
    this.dayWindDirect,
    this.dayWindPower,
  });

  double? get maxTemp => dayTemp;
  double? get minTemp => nightTemp;
}

/// 中央气象台完整天气数据
class NmcWeather {
  final String stationId;
  final String cityName;
  final DateTime? publishTime;

  // ===== real 实况 =====
  final double? temperature;
  final double? humidity;
  final double? rain; // mm
  final String? weatherText;
  final String? weatherImg; // 天气图标码（≈天气码）
  final double? windSpeed; // m/s
  final double? windDegree; // 度
  final String? windDirect; // 风向文字
  final String? windPower; // 风力等级文字
  final double? pressure;

  // ===== passedchart 过去 24h 逐小时实测 =====
  final List<NmcHourlyPoint> history;

  // ===== predict 未来 7 天 =====
  final List<NmcDailyForecast> forecast;

  // ===== radar 雷达拼图 =====
  final String? radarImagePath;
  final String? radarTitle;

  // ===== air 空气质量 =====
  final int? aqi;
  final String? aqiText;

  const NmcWeather({
    required this.stationId,
    required this.cityName,
    this.publishTime,
    this.temperature,
    this.humidity,
    this.rain,
    this.weatherText,
    this.weatherImg,
    this.windSpeed,
    this.windDegree,
    this.windDirect,
    this.windPower,
    this.pressure,
    this.history = const [],
    this.forecast = const [],
    this.radarImagePath,
    this.radarTitle,
    this.aqi,
    this.aqiText,
  });

  /// 雷达图完整 URL
  String? get radarImageUrl =>
      radarImagePath == null ? null : 'http://www.nmc.cn$radarImagePath';

  /// 在 history 中取最接近指定时刻的实测点
  NmcHourlyPoint? historyAt(DateTime t) {
    if (history.isEmpty) return null;
    NmcHourlyPoint? best;
    var bestDiff = const Duration(days: 999).inMinutes;
    for (final p in history) {
      final d = p.time.difference(t).inMinutes.abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = p;
      }
    }
    return best;
  }

  /// 在 forecast 中取指定日期的预报
  NmcDailyForecast? forecastAt(DateTime t) {
    if (forecast.isEmpty) return null;
    final key = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    for (final f in forecast) {
      if (f.date == key) return f;
    }
    return forecast.first;
  }
}

/// 中央气象台数据源（免 key、国内直连、响应极快）
///
/// 接口是 **HTTP 明文**，App 已开 `usesCleartextTraffic` 才能访问。
/// 台风网返回 **JSONP**：列表双括号 `cb(({...}))`、详情单括号 `cb({...})`，需剥壳。
///
/// 城市体系：`/rest/province` → 34 省；`/rest/province/{省code}` → 城市列表；
/// `/rest/weather?stationid={城市code}` → 完整天气。
class NmcService {
  static const String _base = 'http://www.nmc.cn';
  static const String _typhoonList =
      'http://typhoon.nmc.cn/weatherservice/typhoon/jsons/list_default';
  static const String _typhoonView =
      'http://typhoon.nmc.cn/weatherservice/typhoon/jsons/view_';

  final http.Client _client;
  NmcService({http.Client? client}) : _client = client ?? http.Client();

  // ==================== 台风 ====================

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

  // ==================== 城市 ====================

  /// 全部省份（34 个）
  Future<List<({String code, String name})>> provinces() async {
    final body = await _get('$_base/rest/province');
    final list = jsonDecode(body) as List;
    return list.map((e) {
      final m = e as Map;
      return (code: '${m['code']}', name: '${m['name']}');
    }).toList();
  }

  /// 某省的城市列表
  Future<List<NmcCity>> citiesOf(String provinceCode) async {
    final body = await _get('$_base/rest/province/$provinceCode');
    final list = jsonDecode(body) as List;
    return list.map((e) {
      final m = e as Map;
      return NmcCity(
        code: '${m['code']}',
        province: '${m['province']}',
        city: '${m['city']}',
      );
    }).toList();
  }

  /// **全国全部城市**（34 省并行拉取，共约 2529 个）
  ///
  /// 首次拉取后应缓存到本地（城市表基本不变），避免每次启动都请求 34 次。
  Future<List<NmcCity>> allCities() async {
    final provs = await provinces();
    final results = await Future.wait(provs.map((p) => citiesOf(p.code)));
    return results.expand((e) => e).toList();
  }

  /// 按城市名模糊匹配（用于「经纬度 → 高德逆地理编码得到城市名」后的定位）
  static NmcCity? matchCity(List<NmcCity> cities, String cityName, {String? province}) {
    if (cityName.isEmpty) return null;
    final target = cityName.replaceAll(RegExp(r'(市|县|区|自治州|地区|盟)$'), '').trim();
    if (target.isEmpty) return null;

    // 1. 同名 + 同省
    for (final c in cities) {
      if (c.matchedName == target && (province == null || c.province.contains(province))) {
        return c;
      }
    }
    // 2. 同名（不限省）
    for (final c in cities) {
      if (c.matchedName == target) return c;
    }
    // 3. 包含匹配
    for (final c in cities) {
      if (c.matchedName.contains(target) || target.contains(c.matchedName)) {
        return c;
      }
    }
    return null;
  }

  // ==================== 天气 ====================

  /// 完整天气（实况 + 过去24h逐小时 + 7天预报 + 雷达 + 空气质量）
  Future<NmcWeather> weather(String stationId, {String cityName = ''}) async {
    final body = await _get('$_base/rest/weather?stationid=$stationId');
    final root = jsonDecode(body) as Map<String, dynamic>;
    var data = root['data'];
    if (data is String) {
      if (data.isEmpty) {
        throw Exception('中央气象台返回空数据（stationid=$stationId 可能无效）');
      }
      data = jsonDecode(data);
    }
    final map = data as Map<String, dynamic>;

    double? toNum(dynamic v) {
      if (v == null) return null;
      double? d;
      if (v is num) {
        d = v.toDouble();
      } else {
        d = double.tryParse('$v');
      }
      if (d == null) return null;
      return (d == 9999) ? null : d; // 9999 = 中央气象台缺测值
    }

    // ===== real 实况 =====
    final real = map['real'] as Map<String, dynamic>?;
    final station = real?['station'] as Map<String, dynamic>?;
    final wx = real?['weather'] as Map<String, dynamic>?;
    final wind = real?['wind'] as Map<String, dynamic>?;
    final publishStr = real?['publish_time'] as String?;

    // ===== passedchart 过去 24h 逐小时实测 =====
    final history = <NmcHourlyPoint>[];
    final pc = map['passedchart'];
    if (pc is List) {
      for (final item in pc) {
        if (item is! Map) continue;
        final t = DateTime.tryParse('${item['time']}');
        if (t == null) continue;
        history.add(NmcHourlyPoint(
          time: t,
          temperature: toNum(item['temperature']),
          rain1h: toNum(item['rain1h']),
          humidity: toNum(item['humidity']),
          pressure: toNum(item['pressure']),
          windSpeed: toNum(item['windSpeed']),
          windDirection: toNum(item['windDirection']),
        ));
      }
      history.sort((a, b) => a.time.compareTo(b.time)); // 接口倒序，统一为正序
    }

    // ===== predict.detail 未来 7 天 =====
    final forecast = <NmcDailyForecast>[];
    final predict = map['predict'] as Map<String, dynamic>?;
    final detail = predict?['detail'];
    if (detail is List) {
      for (final item in detail) {
        if (item is! Map) continue;
        final day = item['day'] as Map?;
        final night = item['night'] as Map?;
        final dayWx = day?['weather'] as Map?;
        final nightWx = night?['weather'] as Map?;
        final dayWind = day?['wind'] as Map?;
        forecast.add(NmcDailyForecast(
          date: '${item['date']}',
          dayText: dayWx?['info'] as String?,
          nightText: nightWx?['info'] as String?,
          dayTemp: toNum(dayWx?['temperature']),
          nightTemp: toNum(nightWx?['temperature']),
          precipitation: toNum(item['precipitation']),
          dayWindDirect: dayWind?['direct'] as String?,
          dayWindPower: dayWind?['power'] as String?,
        ));
      }
    }

    // ===== radar / air =====
    final radar = map['radar'] as Map<String, dynamic>?;
    final air = map['air'] as Map<String, dynamic>?;

    return NmcWeather(
      stationId: stationId,
      cityName: (station?['city'] as String?) ?? cityName,
      publishTime: publishStr == null ? null : DateTime.tryParse(publishStr),
      temperature: toNum(wx?['temperature']),
      humidity: toNum(wx?['humidity']),
      rain: toNum(wx?['rain']),
      weatherText: wx?['info'] as String?,
      weatherImg: wx?['img'] == null ? null : '${wx?['img']}',
      windSpeed: toNum(wind?['speed']),
      windDegree: toNum(wind?['degree']),
      windDirect: wind?['direct'] as String?,
      windPower: wind?['power'] as String?,
      pressure: toNum(wx?['airpressure']),
      history: history,
      forecast: forecast,
      radarImagePath: radar?['image'] as String?,
      radarTitle: radar?['title'] as String?,
      aqi: toNum(air?['aqi'])?.round(),
      aqiText: air?['text'] as String?,
    );
  }

  /// 兼容旧调用：站点天气原始 JSON
  Future<Map<String, dynamic>> stationWeather(String stationId) async {
    final body = await _get('$_base/rest/weather?stationid=$stationId');
    final root = jsonDecode(body) as Map<String, dynamic>;
    final data = root['data'];
    if (data is String && data.isNotEmpty) {
      return jsonDecode(data) as Map<String, dynamic>;
    }
    return root;
  }

  // ==================== 基础请求 ====================

  Future<String> _get(String url) async {
    final resp = await _client.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 13)',
        'Referer': '$_base/',
      },
    ).timeout(const Duration(seconds: 15));
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
