/// 赛道坐标库
///
/// 坐标全部经**高德地理编码实测校准**（2026-09-20），不是手填：
/// `https://restapi.amap.com/v3/geocode/geo?address=<赛道名>&key=<Web服务Key>`
///
/// ⚠️ 高德对部分赛道名会误匹配（实测「鄂尔多斯国际赛车场」被匹配到珠海、
/// 「成都天府国际赛道」只匹配到「成都天府国际」前缀），因此**未收录**这些
/// 不可靠结果 —— 宁缺毋滥，避免研判指向错误地点。
class TrackCircuit {
  /// 赛道名
  final String name;

  /// 所在城市
  final String city;

  final double lat;
  final double lon;

  /// 行政区划码（高德返回，可复用于预警等）
  final String adcode;

  /// 赛道单圈长度（km，公开资料）
  final double lengthKm;

  /// 特点说明
  final String note;

  const TrackCircuit({
    required this.name,
    required this.city,
    required this.lat,
    required this.lon,
    required this.adcode,
    required this.lengthKm,
    this.note = '',
  });

  String get displayName => name;
}

/// 预置赛道
const List<TrackCircuit> kTrackCircuits = [
  TrackCircuit(
    name: '上海国际赛车场',
    city: '上海市嘉定区',
    lat: 31.337034,
    lon: 121.231089,
    adcode: '310114',
    lengthKm: 5.451,
    note: 'F1 中国大奖赛场地 · 1 号螺线弯重刹 · 长直道尾速高',
  ),
  TrackCircuit(
    name: '珠海国际赛车场',
    city: '广东省珠海市香洲区',
    lat: 22.364622,
    lon: 113.561460,
    adcode: '440402',
    lengthKm: 4.319,
    note: '中国首个永久性赛道 · 南方湿热 · 雨季排水压力大',
  ),
  TrackCircuit(
    name: '浙江国际赛车场',
    city: '浙江省绍兴市柯桥区',
    lat: 30.032385,
    lon: 120.469855,
    adcode: '330603',
    lengthKm: 3.20,
    note: 'FIA 二级赛道 · 依山而建 · 高差大、路面温度变化快',
  ),
  TrackCircuit(
    name: '上海天马赛车场',
    city: '上海市松江区',
    lat: 31.075831,
    lon: 121.120017,
    adcode: '310117',
    lengthKm: 2.063,
    note: '短赛道多弯 · 缓冲区小 · 湿滑容错率低',
  ),
];
