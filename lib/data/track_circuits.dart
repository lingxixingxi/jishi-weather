/// 赛道坐标库
///
/// ## 坐标来源（全部实测，不是手填）
///
/// **国内赛道** —— 高德 **POI 搜索**（`v3/place/text` + `city` 限定）实测，
/// 2026-09-22；`adcode` 由逆地理编码按坐标反查。
///
/// ⚠️ **不要用 `v3/geocode/geo`（地址解析）** —— 实测大量误匹配：
/// | 赛道名 | geocode 返回 | 实际 |
/// |---|---|---|
/// | 鄂尔多斯国际赛车场 | 珠海市香洲区 | 鄂尔多斯康巴什 |
/// | 北京金港国际赛车场 | 朝阳区「金港国际」**住宅小区** | 朝阳区金盏乡 |
/// | 南京万驰国际赛车场 | 南京市中心（level=市） | 溧水区柘塘 |
/// | 广东竞速国际赛车场 | 珠海国际赛车场公交站 | 东莞麻涌 |
/// | 纽博格林北环赛道 | 张家港万达广场 | 德国 |
/// POI 搜索配合城市限定才准，这是「地理编码完善」的一条实测结论。
///
/// **海外赛道** —— 赛道经纬度是稳定公开事实，录入后用 **Open-Meteo 时区
/// 反查**校验（落错国家时区会立刻暴露，实测 8/8 相符），海拔也与地理特征
/// 吻合（纽北 619 m 山区、斯帕 391 m 阿登高原、蒙特卡洛 16 m 海边）。
/// OSM Nominatim 在国内网络不可用（超时），故未采用。
///
/// ## 设计前提
/// **赛道坐标一旦录入就固定** —— 赛道不会搬家，因此运行时**不再做地理编码**，
/// 直接按坐标取天气数据。
///
/// ## ⚠️ 海外赛道的数据源边界（客观限制，务必知悉）
/// | 数据源 | 国内 | 海外 |
/// |---|---|---|
/// | Open-Meteo（ECMWF/GFS/ICON） | ✓ | ✓ 全球 |
/// | 和风天气 | ✓ | ✓ |
/// | 中央气象台实况 | ✓ | ✗ 仅中国 |
/// | 雷达（拼图 / 单站） | ✓ 华东 | ✗ 仅中国 |
/// 所以海外赛道页面上雷达定调与央台实况会缺失 —— 这不是 bug，是数据源边界。
class TrackCircuit {
  /// 赛道名
  final String name;

  /// 所在城市 / 地区
  final String city;

  /// 大区（用于下拉菜单分组）
  final String region;

  final double lat;
  final double lon;

  /// 行政区划码（高德逆地理编码所得，可复用于预警前缀匹配）
  ///
  /// **海外赛道为空字符串** —— 高德无海外行政区划数据。
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
    this.region = '国内',
    this.note = '',
  });

  String get displayName => name;

  /// 是否为中国境外赛道
  ///
  /// 境外赛道没有 adcode，且中央气象台与雷达都不覆盖 ——
  /// 相关卡片需要据此降级，不能把「数据源没有」显示成「无回波 / 无降水」。
  bool get isOverseas => adcode.isEmpty;
}

/// 预置赛道（国内 14 + 海外 8）
///
/// 2026-10-01 补录三条华南赛道：广东国际赛车场（肇庆 GIC）、
/// 惠州福岗赛车场（HDC）、广东大河马赛车场（江门恩平）。
/// 坐标均由高德 POI 搜索实测 + `regeo` 反查 adcode，原始返回留档
/// `_research/amap_poi_raw.json`。
///
/// ⚠️ 两处名称订正（群友反馈的「惠州福冈」「江门赛道」）：
/// · 「惠州福冈」实为惠州**福岗**赛车场（土字旁，港澳资料繁体作「福崗」）；
///   用「福冈」在惠州市域只能搜到博罗县长宁镇的「福岗村」系列 POI。
/// · **「江门国际赛车场」不存在** —— 高德 POI 与网络检索均无此实体，
///   江门实际录入的是恩平的**广东大河马赛车场**（1.2km 卡丁车赛道）。
const List<TrackCircuit> kTrackCircuits = [
  // ==================== 华东 ====================
  TrackCircuit(
    name: '上海国际赛车场',
    city: '上海市嘉定区',
    region: '华东',
    lat: 31.337034,
    lon: 121.231089,
    adcode: '310114',
    lengthKm: 5.451,
    note: 'F1 中国大奖赛场地 · 1 号螺线弯重刹 · 长直道尾速高',
  ),
  TrackCircuit(
    name: '上海天马赛车场',
    city: '上海市松江区',
    region: '华东',
    lat: 31.075831,
    lon: 121.120017,
    adcode: '310117',
    lengthKm: 2.063,
    note: '短赛道多弯 · 缓冲区小 · 湿滑容错率低',
  ),
  TrackCircuit(
    name: '浙江国际赛车场',
    city: '浙江省绍兴市柯桥区',
    region: '华东',
    lat: 30.032385,
    lon: 120.469855,
    adcode: '330603',
    lengthKm: 3.20,
    note: 'FIA 二级赛道 · 依山而建 · 高差大、路面温度变化快',
  ),
  TrackCircuit(
    name: '宁波国际赛道',
    city: '浙江省宁波市北仑区',
    region: '华东',
    lat: 29.758442,
    lon: 121.869661,
    adcode: '330206',
    lengthKm: 4.01,
    note: 'FIA 二级赛道 · 春晓临海 · 海风与盐雾明显，雨后干得慢',
  ),
  TrackCircuit(
    name: '江苏万驰国际赛车场',
    city: '江苏省南京市溧水区',
    region: '华东',
    lat: 31.670688,
    lon: 119.038159,
    adcode: '320117',
    lengthKm: 2.4,
    note: '丘陵地形赛道 · 起伏多盲弯 · 局地阵雨影响大',
  ),

  // ==================== 华南 ====================
  TrackCircuit(
    name: '珠海国际赛车场',
    city: '广东省珠海市香洲区',
    region: '华南',
    lat: 22.364622,
    lon: 113.561460,
    adcode: '440402',
    lengthKm: 4.319,
    note: '中国首个永久性赛道 · 南方湿热 · 雨季排水压力大',
  ),
  TrackCircuit(
    name: '广东竞速国际赛车场',
    city: '广东省东莞市麻涌镇',
    region: '华南',
    lat: 23.057594,
    lon: 113.554801,
    adcode: '441900',
    lengthKm: 2.0,
    note: '俗称「麻涌赛车场」· 珠三角水乡 · 夏季雷雨频繁、湿度极高',
  ),
  TrackCircuit(
    name: '广东国际赛车场',
    city: '广东省肇庆市四会市',
    region: '华南',
    lat: 23.268540,
    lon: 112.822025,
    adcode: '441284',
    lengthKm: 2.82,
    note: '简称 GIC · 华南内陆 · 夏季高温多雨，午后雷阵雨频繁',
  ),
  TrackCircuit(
    name: '惠州福岗赛车场',
    city: '广东省惠州市惠城区',
    region: '华南',
    lat: 23.019183,
    lon: 114.180261,
    adcode: '441302',
    lengthKm: 1.4,
    note: '简称 HDC · 珠三角东岸 · 紧邻潼湖湿地，湿度常年偏高',
  ),

  // ==================== 华北 ====================
  TrackCircuit(
    name: '北京金港国际赛车场',
    city: '北京市朝阳区金盏乡',
    region: '华北',
    lat: 40.014825,
    lon: 116.563025,
    adcode: '110105',
    lengthKm: 2.4,
    note: '北方老牌赛道 · 春季风沙 · 冬季低温需注意路面结冰',
  ),
  TrackCircuit(
    name: '北京锐思赛车场',
    city: '北京市怀柔区杨宋镇',
    region: '华北',
    lat: 40.255025,
    lon: 116.695625,
    adcode: '110116',
    lengthKm: 1.8,
    note: '短赛道 · 以驾驶培训为主 · 山区局地天气变化快',
  ),
  TrackCircuit(
    name: '鄂尔多斯国际赛车场',
    city: '内蒙古自治区鄂尔多斯市康巴什区',
    region: '华北',
    lat: 39.624775,
    lon: 109.877925,
    adcode: '150603',
    lengthKm: 3.751,
    note: 'FIA 二级赛道 · 高原干旱 · 昼夜温差大、春季沙尘',
  ),

  // ==================== 西南 ====================
  TrackCircuit(
    name: '成都天府国际赛道',
    city: '四川省成都市简阳市',
    region: '西南',
    lat: 30.494041,
    lon: 104.433035,
    adcode: '510185',
    lengthKm: 3.2,
    note: 'FIA 二级赛道 · 简州新城 · 盆地多雾、冬季能见度低',
  ),

  // ==================== 海外 ====================
  TrackCircuit(
    name: '纽博格林北环赛道',
    city: '德国 · 艾费尔山区',
    region: '海外',
    lat: 50.3356,
    lon: 6.9475,
    adcode: '',
    lengthKm: 20.832,
    note: '「绿色地狱」· 全长 20.8km · 山区林间赛道，局部湿滑极常见',
  ),
  TrackCircuit(
    name: '银石赛道',
    city: '英国 · 北安普敦郡',
    region: '海外',
    lat: 52.0786,
    lon: -1.0169,
    adcode: '',
    lengthKm: 5.891,
    note: 'F1 英国大奖赛场地 · 高速流畅 · 英国天气多变，晴雨切换快',
  ),
  TrackCircuit(
    name: '蒙扎赛道',
    city: '意大利 · 蒙扎',
    region: '海外',
    lat: 45.6156,
    lon: 9.2811,
    adcode: '',
    lengthKm: 5.793,
    note: '「速度圣殿」· 全油门路段多 · 夏末雷暴来得急',
  ),
  TrackCircuit(
    name: '铃鹿赛道',
    city: '日本 · 三重县',
    region: '海外',
    lat: 34.8431,
    lon: 136.5406,
    adcode: '',
    lengthKm: 5.807,
    note: '8 字立体交叉布局 · 秋季台风与锋面雨影响显著',
  ),
  TrackCircuit(
    name: '斯帕-弗朗科尔尚赛道',
    city: '比利时 · 阿登高原',
    region: '海外',
    lat: 50.4372,
    lon: 5.9714,
    adcode: '',
    lengthKm: 7.004,
    note: '海拔起伏大 · **赛道一头下雨一头干**是常态，局部性极强',
  ),
  TrackCircuit(
    name: '蒙特卡洛街道赛道',
    city: '摩纳哥 · 蒙特卡洛',
    region: '海外',
    lat: 43.7347,
    lon: 7.4206,
    adcode: '',
    lengthKm: 3.337,
    note: 'F1 摩纳哥大奖赛 · 城市街道无缓冲区 · 地中海气候偶发骤雨',
  ),
  TrackCircuit(
    name: '勒芒萨尔特赛道',
    city: '法国 · 勒芒',
    region: '海外',
    lat: 47.9561,
    lon: 0.2078,
    adcode: '',
    lengthKm: 13.626,
    note: '勒芒 24 小时耐力赛 · 大量公共道路 · 夜间降温与露水影响大',
  ),
  TrackCircuit(
    name: '印第安纳波利斯赛道',
    city: '美国 · 印第安纳州',
    region: '海外',
    lat: 39.7950,
    lon: -86.2347,
    adcode: '',
    lengthKm: 4.023,
    note: '印地 500 场地 · 中西部平原 · 强对流与龙卷天气需警惕',
  ),
];
