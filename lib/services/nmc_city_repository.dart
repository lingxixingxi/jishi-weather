import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'amap_service.dart';
import 'nmc_service.dart';

/// 中央气象台城市表仓库（带本地缓存 + 经纬度→城市映射）
///
/// 全国 2529 个城市基本不变，首次拉取后写入 shared_preferences，
/// 后续启动直接读缓存（省下 34 次 HTTP 请求）。
///
/// 经纬度 → 城市：中央气象台按「城市」组织数据且无经纬度索引，
/// 因此用高德逆地理编码把坐标还原成城市名，再在本表中匹配 code。
class NmcCityRepository {
  static const String _cacheKey = 'nmc_cities_v1';

  final NmcService _nmc;
  final AmapService _amap;

  List<NmcCity> _cities = const [];
  bool _loading = false;

  /// 经纬度 → 城市 的内存缓存（key: 保留 2 位小数的坐标 ≈ 1km 精度）
  final Map<String, NmcCity?> _locateCache = {};

  /// 逆地理编码结果缓存
  final Map<String, AmapAddress?> _regeoCache = {};

  NmcCityRepository(this._nmc, this._amap);

  List<NmcCity> get cities => _cities;
  bool get isLoaded => _cities.isNotEmpty;

  /// 加载城市表（优先缓存，无则拉取并缓存）
  Future<List<NmcCity>> load() async {
    if (_cities.isNotEmpty) return _cities;
    if (_loading) {
      // 避免并发重复拉取
      while (_loading) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return _cities;
    }
    _loading = true;
    try {
      // 1. 尝试缓存
      try {
        final prefs = await SharedPreferences.getInstance();
        final cached = prefs.getString(_cacheKey);
        if (cached != null && cached.isNotEmpty) {
          final list = jsonDecode(cached) as List;
          final parsed = list.map((e) {
            final m = e as Map;
            return NmcCity(
              code: '${m['code']}',
              province: '${m['province']}',
              city: '${m['city']}',
            );
          }).toList();
          if (parsed.isNotEmpty) {
            _cities = parsed;
            return _cities;
          }
        }
      } catch (_) {
        // 缓存损坏则忽略，走网络
      }

      // 2. 网络拉取（34 省并行）
      _cities = await _nmc.allCities();

      // 3. 写缓存
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _cacheKey,
          jsonEncode(_cities
              .map((c) => {'code': c.code, 'province': c.province, 'city': c.city})
              .toList()),
        );
      } catch (_) {
        // 缓存写入失败不影响使用
      }
      return _cities;
    } finally {
      _loading = false;
    }
  }

  /// 经纬度 → 中央气象台城市（先用高德逆地理编码，再匹配城市表）
  ///
  /// 返回 null 表示无法定位（此时应跳过中央气象台源，不影响其他源）。
  Future<NmcCity?> locate(double lat, double lon) async {
    final key = '${lat.toStringAsFixed(2)},${lon.toStringAsFixed(2)}';
    if (_locateCache.containsKey(key)) return _locateCache[key];

    try {
      if (_cities.isEmpty) await load();
      if (_cities.isEmpty) {
        _locateCache[key] = null;
        return null;
      }

      final addr = await _regeo(lat, lon);
      if (addr == null) {
        _locateCache[key] = null;
        return null;
      }

      // 用城市名匹配，直辖市用 province
      var city = NmcService.matchCity(_cities, addr.city, province: addr.province);
      city ??= NmcService.matchCity(_cities, addr.province);
      city ??= NmcService.matchCity(_cities, addr.district, province: addr.province);

      _locateCache[key] = city;
      return city;
    } catch (_) {
      _locateCache[key] = null;
      return null;
    }
  }

  /// 逆地理编码（带缓存）
  Future<AmapAddress?> _regeo(double lat, double lon) async {
    final key = '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}';
    if (_regeoCache.containsKey(key)) return _regeoCache[key];
    final addr = await _amap.regeo(lat, lon);
    _regeoCache[key] = addr;
    return addr;
  }

  /// 对外暴露逆地理编码结果（复用同一份缓存，不重复请求）
  ///
  /// 气象预警按 **6 位行政区划码**（adcode）过滤，需要它。
  Future<AmapAddress?> addressAt(double lat, double lon) => _regeo(lat, lon);

  void clearLocateCache() => _locateCache.clear();
}
