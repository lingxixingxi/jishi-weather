import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/secrets.dart';

/// 地理坐标点（GCJ-02 火星坐标，高德体系内一致，无需转换）
class GeoPoint {
  final double lat;
  final double lon;
  final String name;

  const GeoPoint({required this.lat, required this.lon, this.name = ''});

  @override
  String toString() => '$name($lon,$lat)';
}

/// 一条候选路线（高德一次规划通常返回多条，让用户选实际要走的那条）
class RouteOption {
  /// 候选序号（0 开始）
  final int index;

  /// 策略名（高德返回，如「速度最快」「距离最短」「少走高速」）
  final String strategy;

  /// 总距离（米）
  final int distanceMeters;

  /// 预计耗时（秒）
  final int durationSeconds;

  /// 过路费（元）
  final int tolls;

  /// 红绿灯数
  final int trafficLights;

  /// 主要途经道路（摘要，取自前几个 step 的道路名）
  final List<String> mainRoads;

  /// 抽稀折线（约 20 点，用于研判取点）
  final List<GeoPoint> polyline;

  /// 完整折线（用于地图绘制）
  final List<GeoPoint> fullPolyline;

  const RouteOption({
    required this.index,
    required this.strategy,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.tolls,
    required this.trafficLights,
    required this.mainRoads,
    required this.polyline,
    required this.fullPolyline,
  });

  double get distanceKm => distanceMeters / 1000.0;
  int get durationMinutes => (durationSeconds / 60).round();

  /// 展示用标签，如「速度最快 · 92km · 1h20m」
  String get summary =>
      '${strategy.isEmpty ? '推荐路线' : strategy} · ${distanceKm.toStringAsFixed(0)}km · ${_dur()}';

  String _dur() {
    final m = durationMinutes;
    if (m < 60) return '$m分钟';
    return '${m ~/ 60}h${(m % 60).toString().padLeft(2, '0')}m';
  }

  /// 副标题：过路费 / 红绿灯 / 途经
  String get detail {
    final parts = <String>[];
    if (tolls > 0) parts.add('过路费 ¥$tolls');
    if (trafficLights > 0) parts.add('$trafficLights个红绿灯');
    if (mainRoads.isNotEmpty) parts.add('经 ${mainRoads.take(3).join(' · ')}');
    return parts.join('　');
  }
}

/// 高德 Web 服务 API（地理编码 / 路线规划）
///
/// 高德逆地理编码结果
class AmapAddress {
  final String province;
  final String city;
  final String district;
  final String adcode;
  final String formatted;

  const AmapAddress({
    required this.province,
    required this.city,
    required this.district,
    required this.adcode,
    this.formatted = '',
  });

  @override
  String toString() => '$province$city$district';
}

/// ⚠️ 用的是 **Web服务 Key**，不是 Android 平台 Key。
/// 高德 POI 输入提示项（搜索联想候选）
class PoiTip {
  final String name;
  final String district; // 行政区（如「上海市浦东新区」）
  final String address; // 详细地址
  final String? lat;
  final String? lon;
  final String? adcode;
  final String type; // POI 类型码

  const PoiTip({
    required this.name,
    this.district = '',
    this.address = '',
    this.lat,
    this.lon,
    this.adcode,
    this.type = '',
  });

  /// 是否有坐标（高德对某些提示只给行政区不给坐标）
  bool get hasLocation =>
      lat != null && lon != null && lat!.isNotEmpty && lon!.isNotEmpty;

  GeoPoint? get point =>
      hasLocation ? GeoPoint(lat: double.parse(lat!), lon: double.parse(lon!), name: name) : null;

  /// 副标题：行政区 · 地址
  String get subtitle {
    final parts = <String>[];
    if (district.isNotEmpty && district != '[]') parts.add(district);
    if (address.isNotEmpty && address != '[]') parts.add(address);
    return parts.join(' · ');
  }
}

class AmapService {
  static const String _geoUrl = 'https://restapi.amap.com/v3/geocode/geo';
  static const String _regeoUrl = 'https://restapi.amap.com/v3/geocode/regeo';
  static const String _driveUrl = 'https://restapi.amap.com/v3/direction/driving';
  static const String _tipUrl = 'https://restapi.amap.com/v3/assistant/inputtips';

  final http.Client _client;
  AmapService({http.Client? client}) : _client = client ?? http.Client();

  /// **POI 输入提示**（搜索联想）—— 地点输入必须有候选列表
  ///
  /// ⚠️ 为什么必须做：
  /// 直接拿用户输入的文本去地理编码，**误差极大**。典型例子：
  /// 「海底捞火锅」全国有几千家，`geocode` 只会返回其中一家（或返回
  /// 一个莫名其妙的地点），用户以为查的是附近那家，结果跑了半个城。
  /// 正确做法是把候选列出来让用户**点选**。
  ///
  /// [city] 限定城市（可提高精度）；[location] 传 `经度,纬度` 时
  /// 高德会按距离排序（配合 `citylimit=false` 可跨城）。
  Future<List<PoiTip>> inputTips(
    String keyword, {
    String? city,
    String? location,
    int max = 12,
  }) async {
    _ensureKey();
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];

    final params = <String, String>{
      'keywords': kw,
      'key': Secrets.amapWebKey,
    };
    if (city != null && city.isNotEmpty) params['city'] = city;
    if (location != null && location.isNotEmpty) {
      params['location'] = location; // 按距离排序
      params['citylimit'] = 'false'; // 允许跨城结果
    }

    try {
      final uri = Uri.parse(_tipUrl).replace(queryParameters: params);
      final resp = await _client.get(uri).timeout(const Duration(seconds: 12));
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      if (data['status'] != '1') {
        debugPrint('[POI 联想] 失败: ${data['info']}');
        return const [];
      }
      final list = data['tips'] as List?;
      if (list == null) return const [];

      final out = <PoiTip>[];
      for (final e in list) {
        if (out.length >= max) break;
        final m = e as Map;
        final name = '${m['name'] ?? ''}';
        if (name.isEmpty) continue;

        final loc = '${m['location'] ?? ''}';
        String? lat, lon;
        if (loc.contains(',')) {
          final p = loc.split(',');
          if (p.length == 2 && p[0].isNotEmpty && p[1].isNotEmpty) {
            lon = p[0];
            lat = p[1];
          }
        }
        out.add(PoiTip(
          name: name,
          district: '${m['district'] ?? ''}',
          address: '${m['address'] ?? ''}',
          lat: lat,
          lon: lon,
          adcode: '${m['adcode'] ?? ''}',
          type: '${m['typecode'] ?? ''}',
        ));
      }
      debugPrint('[POI 联想] "$kw" -> ${out.length} 条候选');
      return out;
    } catch (e) {
      debugPrint('[POI 联想] 异常: $e');
      return const [];
    }
  }

  /// 地理编码：中文地名 → 坐标
  Future<GeoPoint?> geocode(String address) async {
    _ensureKey();
    final uri = Uri.parse(_geoUrl).replace(queryParameters: {
      'address': address,
      'key': Secrets.amapWebKey,
    });
    final resp = await _client.get(uri).timeout(const Duration(seconds: 15));
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (data['status'] != '1') {
      throw Exception('地理编码失败: ${data['info']}');
    }
    final list = data['geocodes'] as List?;
    if (list == null || list.isEmpty) return null;
    final loc = (list.first as Map)['location'] as String; // "经度,纬度"
    final parts = loc.split(',');
    return GeoPoint(lon: double.parse(parts[0]), lat: double.parse(parts[1]), name: address);
  }

  /// **逆地理编码**：坐标 → 行政区（用于匹配中央气象台城市）
  ///
  /// 中央气象台按「城市」组织数据（2529 个），没有经纬度索引，
  /// 所以用高德把采样点坐标还原成城市名，再去匹配它的城市 code。
  /// 直辖市（北京/上海/天津/重庆）的 `city` 字段为空，此时退回 `province`。
  Future<AmapAddress?> regeo(double lat, double lon) async {
    _ensureKey();
    final uri = Uri.parse(_regeoUrl).replace(queryParameters: {
      'location': '$lon,$lat',
      'extensions': 'base',
      'key': Secrets.amapWebKey,
    });
    final resp = await _client.get(uri).timeout(const Duration(seconds: 15));
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (data['status'] != '1') {
      throw Exception('逆地理编码失败: ${data['info']}');
    }
    final rc = data['regeocode'] as Map<String, dynamic>?;
    final comp = rc?['addressComponent'] as Map<String, dynamic>?;
    if (comp == null) return null;

    var city = '${comp['city'] ?? ''}';
    if (city.isEmpty || city == '[]' || city == 'null') {
      city = '${comp['province'] ?? ''}'; // 直辖市
    }
    return AmapAddress(
      province: '${comp['province'] ?? ''}',
      city: city,
      district: '${comp['district'] ?? ''}',
      adcode: '${comp['adcode'] ?? ''}',
      formatted: '${rc?['formatted_address'] ?? ''}',
    );
  }

  /// 驾车路线规划 —— 返回**多条候选路线**供用户选择
  ///
  /// [strategy] 高德策略：0=速度优先(默认) / 1=费用优先 / 2=距离优先 /
  /// 3=不走快速路 / 4=结合实时路况 / 9=躲避拥堵 …
  /// 必须带 `extensions=all`，否则不返回 steps 里的 polyline。
  Future<List<RouteOption>> drivingRoutes(
    GeoPoint from,
    GeoPoint to, {
    String strategy = '0',
  }) async {
    _ensureKey();
    final uri = Uri.parse(_driveUrl).replace(queryParameters: {
      'origin': '${from.lon},${from.lat}',
      'destination': '${to.lon},${to.lat}',
      'extensions': 'all',
      'strategy': strategy,
      'key': Secrets.amapWebKey,
    });
    final resp = await _client.get(uri).timeout(const Duration(seconds: 20));
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (data['status'] != '1') {
      throw Exception('路线规划失败: ${data['info']}');
    }
    final route = (data['route'] as Map?) ?? const {};
    final paths = (route['paths'] as List?) ?? const [];
    if (paths.isEmpty) return const [];

    final options = <RouteOption>[];
    for (var i = 0; i < paths.length; i++) {
      final path = paths[i] as Map;

      final full = <GeoPoint>[];
      final roads = <String>[];
      for (final step in (path['steps'] as List? ?? const [])) {
        final s = step as Map;
        final road = (s['road'] as String?)?.trim();
        if (road != null && road.isNotEmpty && !roads.contains(road)) {
          roads.add(road);
        }
        final poly = s['polyline'] as String?;
        if (poly == null || poly.isEmpty) continue;
        for (final seg in poly.split(';')) {
          final p = seg.split(',');
          if (p.length == 2) {
            final lon = double.tryParse(p[0]);
            final lat = double.tryParse(p[1]);
            if (lon != null && lat != null) full.add(GeoPoint(lon: lon, lat: lat));
          }
        }
      }
      if (full.isEmpty) continue;

      options.add(RouteOption(
        index: options.length,
        strategy: (path['strategy'] as String?)?.trim() ?? '',
        distanceMeters: int.tryParse('${path['distance'] ?? 0}') ?? 0,
        durationSeconds: int.tryParse('${path['duration'] ?? 0}') ?? 0,
        tolls: int.tryParse('${path['tolls'] ?? 0}') ?? 0,
        trafficLights: int.tryParse('${path['traffic_lights'] ?? 0}') ?? 0,
        mainRoads: roads,
        polyline: simplify(full, maxPoints: 20),
        fullPolyline: full,
      ));
    }
    return options;
  }

  /// IP 定位兜底：**无需 GPS、无需定位权限**，只要有网就能拿到城市级大概位置。
  ///
  /// 天气研判是 10km 尺度，城市级位置完全够用；室内/无 GPS 场景靠它保底。
  /// 链路：太平洋 IP 库拿出口 IP 的 adcode（纯数字，避开 GBK 中文编码问题）
  ///      → 高德行政区划 API 换中心坐标。
  Future<GeoPoint?> ipLocation() async {
    try {
      // 1) 取出口 IP 对应的行政区划码
      final ipResp = await _client
          .get(Uri.parse('https://whois.pconline.com.cn/ipJson.jsp?json=true'))
          .timeout(const Duration(seconds: 10));
      // 该接口返回 GBK，中文会乱码，但我们只提取纯数字 adcode，不受影响
      final text = latin1.decode(ipResp.bodyBytes);
      final m = RegExp(r'"cityCode"\s*:\s*"(\d+)"').firstMatch(text);
      final adcode = m?.group(1);
      if (adcode == null || adcode == '0' || adcode.isEmpty) return null;

      // 2) adcode → 中心坐标（高德行政区划）
      final uri = Uri.parse('https://restapi.amap.com/v3/config/district').replace(queryParameters: {
        'keywords': adcode,
        'subdistrict': '0',
        'extensions': 'base',
        'key': Secrets.amapWebKey,
      });
      final resp = await _client.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      if (data['status'] != '1') return null;
      final districts = data['districts'] as List?;
      if (districts == null || districts.isEmpty) return null;
      final first = districts.first as Map;
      final center = first['center'] as String?;
      if (center == null || center.isEmpty) return null;
      final parts = center.split(',');
      final cityName = (first['name'] as String?) ?? '所在城市';
      return GeoPoint(
        lon: double.parse(parts[0]),
        lat: double.parse(parts[1]),
        name: '$cityName（IP定位）',
      );
    } catch (_) {
      return null;
    }
  }

  /// 折线抽稀：沿路径均匀取 [maxPoints] 个点（含首尾）
  static List<GeoPoint> simplify(List<GeoPoint> pts, {int maxPoints = 20}) {
    if (pts.length <= maxPoints) return List.of(pts);
    final out = <GeoPoint>[];
    final step = (pts.length - 1) / (maxPoints - 1);
    for (var i = 0; i < maxPoints; i++) {
      out.add(pts[(i * step).round().clamp(0, pts.length - 1)]);
    }
    return out;
  }

  /// 两点球面距离（km，Haversine）
  static double distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// 沿折线按固定间距重新采样（用于沿途天气取点）
  static List<({GeoPoint point, double kmFromStart})> sampleAlong(
    List<GeoPoint> polyline, {
    double intervalKm = 10,
  }) {
    if (polyline.isEmpty) return const [];
    if (polyline.length == 1) {
      return [(point: polyline.first, kmFromStart: 0)];
    }
    final out = <({GeoPoint point, double kmFromStart})>[];
    var acc = 0.0;
    var nextMark = 0.0;
    out.add((point: polyline.first, kmFromStart: 0));
    for (var i = 1; i < polyline.length; i++) {
      final a = polyline[i - 1];
      final b = polyline[i];
      final segLen = distanceKm(a.lat, a.lon, b.lat, b.lon);
      if (segLen <= 0) continue;
      while (nextMark + intervalKm <= acc + segLen) {
        nextMark += intervalKm;
        final t = (nextMark - acc) / segLen;
        out.add((
          point: GeoPoint(
            lat: a.lat + (b.lat - a.lat) * t,
            lon: a.lon + (b.lon - a.lon) * t,
          ),
          kmFromStart: nextMark,
        ));
      }
      acc += segLen;
    }
    final last = polyline.last;
    if (out.last.kmFromStart < acc - 0.5) {
      out.add((point: last, kmFromStart: acc));
    }
    return out;
  }

  void _ensureKey() {
    if (Secrets.amapWebKey.isEmpty) {
      throw Exception('未配置高德 Web服务 Key（见 lib/config/secrets.example.dart）');
    }
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  void dispose() => _client.close();
}
