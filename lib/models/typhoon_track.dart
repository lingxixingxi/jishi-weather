import 'dart:math' as math;

/// 台风路径点 / 风圈 / 详情模型
///
/// 数据来自**中央气象台台风网**（免 key、国内直连）：
/// `http://typhoon.nmc.cn/weatherservice/typhoon/jsons/view_{id}`
///
/// ## 实测原始结构（2026-09-20 实际抓取，勿凭猜测修改）
///
/// 详情接口返回 JSONP `typhoon_jsons_view_{id}({...})`，剥壳后：
/// ```
/// {"typhoon":[ id, nameEn, nameCn, number, number, null, 名字含义, status, [路径点...], null ]}
/// ```
/// 注意 `status`（`start`/`stop`）在 **index 7**，index 6 是「名字含义」
/// （如「杜鹃花」）—— 早期代码取 index 6 是错的。
///
/// 路径点共 13 个字段：
/// ```
/// [0] pointId            Int
/// [1] "202609200300"     时间 YYYYMMDDHHmm
/// [2] 1789873200000      时间戳（毫秒）
/// [3] "STS"              强度等级码
/// [4] 137.6              经度
/// [5] 29.2               纬度
/// [6] 980                中心气压 hPa
/// [7] 30                 风速 m/s
/// [8] "N"                移动方向
/// [9] 15                 移动速度 km/h
/// [10] [["30KTS",500,300,300,400,pointId], ...]  风圈（四象限半径 km）
/// [11] {"BABJ": [[12,"202609201500",137.5,30.8,980,30,"BABJ","STS"], ...]}
/// [12] ["202609201100","2026年09月20日11时00分"]  数据更新时间
/// ```
/// 预报点 8 字段：`[时效h, 时间, 经度, 纬度, 气压, 风速, 机构, 等级]`

/// 台风风圈（四象限半径，单位 km）
class TyphoonWindCircle {
  final String name; // 30KTS / 50KTS
  final double ne; // 东北
  final double se; // 东南
  final double sw; // 西南
  final double nw; // 西北

  const TyphoonWindCircle({
    required this.name,
    required this.ne,
    required this.se,
    required this.sw,
    required this.nw,
  });

  /// 最大象限半径（保守估计影响范围）
  double get maxRadius => math.max(math.max(ne, se), math.max(sw, nw));

  /// 风速阈值标签（30KTS ≈ 7 级风圈，50KTS ≈ 10 级风圈）
  String get label {
    if (name.startsWith('30')) return '7 级风圈';
    if (name.startsWith('50')) return '10 级风圈';
    if (name.startsWith('64')) return '12 级风圈';
    return name;
  }
}

/// 台风路径点（实况或预报）
class TyphoonPoint {
  final DateTime time;
  final double lat;
  final double lon;
  final double? pressure; // hPa
  final double? windSpeed; // m/s
  final String? levelCode; // TD/TS/STS/TY/STY/SuperTY
  final String? moveDir; // N / NNW / ...
  final double? moveSpeed; // km/h
  final List<TyphoonWindCircle> windCircles;

  /// 是否为预报点（实况路径为 false）
  final bool isForecast;

  /// 预报机构（BABJ = 中央气象台/北京，RJTD = 日本，KWBC = 美国…）
  final String? agency;

  /// 预报时效（小时），实况点为 null
  final int? leadHours;

  const TyphoonPoint({
    required this.time,
    required this.lat,
    required this.lon,
    this.pressure,
    this.windSpeed,
    this.levelCode,
    this.moveDir,
    this.moveSpeed,
    this.windCircles = const [],
    this.isForecast = false,
    this.agency,
    this.leadHours,
  });

  /// 强度等级中文（由中国气象台等级码映射）
  String get levelText => TyphoonLevel.text(levelCode);

  /// 按风速反推的等级（等级码缺失时的兜底）
  String get levelTextByWind => TyphoonLevel.textByWind(windSpeed);

  /// 移动方向中文
  String get moveDirText => TyphoonLevel.directionText(moveDir);
}

/// 台风详情（一条台风的完整路径）
class TyphoonDetail {
  final String id;
  final String nameEn;
  final String nameCn;
  final String number;
  final String status; // start / stop

  /// 实况路径（按时间正序）
  final List<TyphoonPoint> observed;

  /// 预报路径（按时间正序，默认取中央气象台 BABJ）
  final List<TyphoonPoint> forecast;

  /// 预报机构名（如「中央气象台」）
  final String? forecastAgency;

  /// **各机构的预报路径**（原始，用于计算「机构分歧」）
  ///
  /// key 为机构码（`BABJ` 中央气象台 / `RJTD` 日本 / `KWBC` 美国 …）。
  /// 「机构分歧」= 各机构预报点相对 BABJ 的**最大偏差距离**，
  /// 是路径预报不确定度的直接度量（计划任务 4-1 要求）。
  final Map<String, List<TyphoonPoint>> agencyForecasts;

  /// 数据更新时间（原始字符串，形如 `2026年09月20日11时00分`）
  final String? updatedAt;

  const TyphoonDetail({
    required this.id,
    required this.nameEn,
    required this.nameCn,
    required this.number,
    required this.status,
    this.observed = const [],
    this.forecast = const [],
    this.forecastAgency,
    this.agencyForecasts = const {},
    this.updatedAt,
  });

  bool get isActive => status == 'start';

  String get displayName =>
      (nameCn.isNotEmpty && nameCn != 'nameless') ? nameCn : (nameEn.isEmpty ? '未命名' : nameEn);

  /// 最新实况点
  TyphoonPoint? get latest => observed.isEmpty ? null : observed.last;

  /// 完整路径（实况 + 预报），供绘图/最短距离计算
  List<TyphoonPoint> get fullTrack => [...observed, ...forecast];

  /// 编号显示：`2625` → `第 25 号台风`（年份后两位 + 序号）
  String get numberText {
    if (number.length < 3) return number;
    final seq = int.tryParse(number.substring(number.length - 2));
    if (seq == null) return number;
    return '第 $seq 号';
  }
}

/// 台风等级码 ↔ 中文映射
class TyphoonLevel {
  TyphoonLevel._();

  static const Map<String, String> _map = {
    'TD': '热带低压',
    'TS': '热带风暴',
    'STS': '强热带风暴',
    'TY': '台风',
    'STY': '强台风',
    'SuperTY': '超强台风',
    'SUPERTY': '超强台风',
  };

  static const List<String> allTexts = [
    '热带低压',
    '热带风暴',
    '强热带风暴',
    '台风',
    '强台风',
    '超强台风',
  ];

  /// 等级码 → 中文
  static String text(String? code) {
    if (code == null || code.isEmpty) return '未知';
    return _map[code] ?? _map[code.toUpperCase()] ?? code;
  }

  /// 是否为等级中文名（列表接口在无名台风时把等级放在 nameCn）
  static bool isLevelText(String s) => allTexts.contains(s);

  /// 风速（m/s）→ 等级中文（国标 GB/T 19201-2006）
  ///
  /// 界限（**务必按国标，勿凭感觉写**）：
  /// 热带低压 10.8~17.1 / 热带风暴 17.2~24.4 / 强热带风暴 24.5~32.6 /
  /// 台风 32.7~41.4 / 强台风 41.5~50.9 / 超强台风 ≥51.0 m/s
  static String textByWind(double? ms) {
    if (ms == null) return '未知';
    if (ms < 17.2) return '热带低压';
    if (ms < 24.5) return '热带风暴';
    if (ms < 32.7) return '强热带风暴';
    if (ms < 41.5) return '台风';
    if (ms < 51.0) return '强台风';
    return '超强台风';
  }

  /// 等级 → 建议色用的危险度（0~5）
  static int severity(String? code) {
    switch (code) {
      case 'TD':
        return 1;
      case 'TS':
        return 2;
      case 'STS':
        return 3;
      case 'TY':
        return 4;
      case 'STY':
        return 5;
      case 'SuperTY':
        return 6;
      default:
        return 0;
    }
  }

  /// 移动方向码 → 中文
  static String directionText(String? code) {
    if (code == null || code.isEmpty) return '—';
    const d = {
      'N': '北',
      'NNE': '北东北',
      'NE': '东北',
      'ENE': '东东北',
      'E': '东',
      'ESE': '东东南',
      'SE': '东南',
      'SSE': '南东南',
      'S': '南',
      'SSW': '南西南',
      'SW': '西南',
      'WSW': '西西南',
      'W': '西',
      'WNW': '西西北',
      'NW': '西北',
      'NNW': '北西北',
      'STATIONARY': '少动',
      'QSTNR': '少动',
    };
    return d[code.toUpperCase()] ?? code;
  }

  /// 机构码 → 中文名
  static String agencyText(String? code) {
    if (code == null || code.isEmpty) return '';
    const a = {
      'BABJ': '中央气象台',
      'RJTD': '日本气象厅',
      'KWBC': '美国联合台风警报中心',
      'PGTW': '美国关岛',
      'RKSL': '韩国气象厅',
      'VHHH': '香港天文台',
      'RCTP': '台湾气象部门',
    };
    return a[code.toUpperCase()] ?? code;
  }
}

/// 两点大圆距离（km），Haversine
double distanceKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
