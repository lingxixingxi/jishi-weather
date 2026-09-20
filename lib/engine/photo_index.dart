import 'dart:math' as math;

import '../data/bortle_scale.dart';
import '../services/open_meteo_extra.dart';
import 'moon_calculator.dart';
import 'solar_calculator.dart';

/// 摄影机会评分
class PhotoScore {
  /// 机会对应的时刻（日落 / 日出 / 夜间采样点）
  final DateTime time;

  /// 类型：火烧云（日落）/ 火烧云（日出）/ 星空
  final String kind;

  /// 展示标签，如「今日日落 17:54」
  final String label;

  /// 最终得分 0~100（= [baseScore] × [gate]）
  final int score;

  final List<String> factors;

  final double? cloudCover;
  final double? cloudLow;
  final double? cloudMid;
  final double? cloudHigh;
  final double? visibility;
  final double? humidity;
  final int? precipProb;
  final int? weatherCode;

  final double? aod; // 气溶胶光学厚度
  final double? pm25; // μg/m³
  final int? aqi; // EAQI

  /// 月亮状态（星空机会才有；火烧云在日落/日出，月光不是决定因素）
  final MoonInfo? moon;

  /// **光污染 Bortle 等级 1~9**（星空机会才有）
  ///
  /// 光污染是**地点属性**，由用户在摄影页自行设定（见 [BortleScale]）。
  final int? bortle;

  /// **云量门槛 0~1** —— 地面能看到多少天空（总云量为主，低云与恶劣天气为辅）
  final double cloudGate;

  /// **综合可见性门槛** = [cloudGate] × 月光因子
  final double gate;

  /// 门槛生效**之前**的质量分 0~100
  final int baseScore;

  const PhotoScore({
    required this.time,
    required this.kind,
    required this.label,
    required this.score,
    required this.factors,
    required this.cloudGate,
    required this.gate,
    required this.baseScore,
    this.cloudCover,
    this.cloudLow,
    this.cloudMid,
    this.cloudHigh,
    this.visibility,
    this.humidity,
    this.precipProb,
    this.weatherCode,
    this.aod,
    this.pm25,
    this.aqi,
    this.moon,
    this.bortle,
  });

  /// 等级文案
  String get grade {
    if (score >= 80) return '极佳';
    if (score >= 65) return '良好';
    if (score >= 45) return '一般';
    return '较差';
  }

  /// 等级序号（供配色：3 极佳 … 0 较差）
  int get gradeRank {
    if (score >= 80) return 3;
    if (score >= 65) return 2;
    if (score >= 45) return 1;
    return 0;
  }

  /// 分数构成，如 `质量分 62 × 云门槛 0.63 × 月光 0.57 × 光污染 0.64 = 14`
  String get formulaText {
    final m = moon;
    if (m == null) return '质量分 $baseScore × 云门槛 ${cloudGate.toStringAsFixed(2)} = $score';
    final b = bortle == null
        ? ''
        : ' × 光污染 ${BortleScale.factor(bortle!).toStringAsFixed(2)}';
    return '质量分 $baseScore × 云门槛 ${cloudGate.toStringAsFixed(2)}'
        ' × 月光 ${m.darknessFactor.toStringAsFixed(2)}$b = $score';
  }

  /// 门槛是否构成实质否决
  bool get gated => gate < 0.5;
}

/// 摄影指数引擎（火烧云 / 星空）
///
/// ## 三层模型
/// ```text
/// 最终分 = 质量分（云层画布 / 通透度 / 空气 / 干燥度） × 可见性门槛
/// 可见性门槛 = 云量门槛 × 月光因子
/// ```
///
/// ### 为什么需要「门槛」而不是纯加权
/// 早期版本只把分层云量当因子做加权平均，实测出现「阴天却给 91 分极佳」的
/// 荒谬结论（2026-09-20 南京：总云量 84%、天气码 3 = 阴，仍得 91 分）。根因：
/// 1. **总云量根本没进模型** —— 总云量才是"地面能看到多少天空"的直接度量；
/// 2. **中高云取算术平均掩盖了厚云挡光** —— 中云 82% + 高云 0% 平均成 41%，
///    恰好落进"最佳区间"拿满分，实际是一层厚中云。
///
/// 所以把"能不能看到天/夜空"独立成**门槛**（乘法否决），而不是又一个加权项。
///
/// ### 火烧云质量分
/// | 因子 | 权重 |
/// |---|---|
/// | 可照亮云量适中度（中云∪高云，30%~70% 最佳） | 40% |
/// | 低云少 | 20% |
/// | **空气质量** | 15% |
/// | 能见度 | 15% |
/// | 无降水 | 10% |
///
/// ### 星空：门槛更严 + 月光否决
/// - **云量**：观星要的是"万里无云"，因此 `≤5%` 才满分，`30%` 已压到 0.30，
///   `60%` 以上几乎归零（远比火烧云苛刻）
/// - **月光**：`月明星稀`。满月夜的天空背景亮度可比新月夜高 3~4 个星等，
///   银河与暗星云全部淹没 —— 用[MoonInfo.darknessFactor]（照亮比例 + 高度角）
///   作为第二重乘法门槛
/// - 质量分权重：空气质量 35% / 能见度 30% / 干燥度 20% / 低云 15%
///
/// ### 空气质量
/// 主指标是 **AOD（气溶胶光学厚度）**，比 AQI 更贴近摄影需求：它直接刻画
/// 大气对光线的消光与散射。AOD 高时霞光发浑、暗星被散射光淹没。
/// AOD 缺失时退回 PM2.5。
class PhotoIndexEngine {
  PhotoIndexEngine._();

  /// 火烧云取样：日落/日出前 30 分钟所代表的小时
  static const int sampleLeadMinutes = 30;

  // ==================== 对外入口 ====================

  /// 火烧云：日落
  static PhotoScore? sunset(ExtraWeather wx, DateTime day) {
    final t = wx.sunsetOn(day);
    if (t == null) return null;
    final s = wx.nearest(t.subtract(const Duration(minutes: sampleLeadMinutes))) ?? wx.nearest(t);
    if (s == null) return null;
    return _burn(s, t, '日落', day);
  }

  /// 火烧云：日出
  static PhotoScore? sunrise(ExtraWeather wx, DateTime day) {
    final t = wx.sunriseOn(day);
    if (t == null) return null;
    final s = wx.nearest(t.subtract(const Duration(minutes: sampleLeadMinutes))) ?? wx.nearest(t);
    if (s == null) return null;
    return _burn(s, t, '日出', day);
  }

  /// 星空：取当地 23:00 的小时点（含月相与光污染）
  ///
  /// [bortle] 光污染等级 1~9，默认取 [BortleScale.defaultLevel]，由用户在页面调节。
  static PhotoScore? starry(
    ExtraWeather wx,
    DateTime day, {
    int bortle = BortleScale.defaultLevel,
  }) {
    final t = DateTime(day.year, day.month, day.day, 23, 0);
    final s = wx.nearest(t);
    if (s == null) return null;
    return _star(wx, s, t, day, bortle);
  }

  // ==================== 可见性门槛 ====================

  /// 火烧云云量门槛（总云量 + 低云 + 恶劣天气）
  ///
  /// `≤30% → 1.00`｜`30~60% → 1.00→0.80`｜`60~85% → 0.80→0.20`｜`≥85% → 0.20→0.03`
  static double sunCloudGate({required double total, required double low, int? code}) {
    double g;
    if (total <= 30) {
      g = 1.0;
    } else if (total <= 60) {
      g = 1.0 - (total - 30) / 30 * 0.20;
    } else if (total <= 85) {
      g = 0.80 - (total - 60) / 25 * 0.60;
    } else {
      g = 0.20 - (total - 85) / 15 * 0.17;
    }

    if (low >= 80) {
      g *= 0.45;
    } else if (low >= 60) {
      g *= 0.70;
    } else if (low >= 40) {
      g *= 0.88;
    }

    if (isBadWeather(code)) g *= 0.15;
    return g.clamp(0.0, 1.0);
  }

  /// 星空云量门槛 —— **远比火烧云苛刻**，观星要的是"万里无云"
  ///
  /// `≤5% → 1.00`｜`5~15% → 1.00→0.75`｜`15~30% → 0.75→0.30`｜
  /// `30~60% → 0.30→0.05`｜`≥60% → 0.05→0.01`
  static double starCloudGate({required double total, required double low, int? code}) {
    double g;
    if (total <= 5) {
      g = 1.0;
    } else if (total <= 15) {
      g = 1.0 - (total - 5) / 10 * 0.25;
    } else if (total <= 30) {
      g = 0.75 - (total - 15) / 15 * 0.45;
    } else if (total <= 60) {
      g = 0.30 - (total - 30) / 30 * 0.25;
    } else {
      g = 0.05 - (total - 60) / 40 * 0.04;
    }

    if (low >= 60) {
      g *= 0.50;
    } else if (low >= 35) {
      g *= 0.78;
    }

    if (isBadWeather(code)) g *= 0.10;
    return g.clamp(0.0, 1.0);
  }

  /// 恶劣天气（雾 / 降水 / 雷暴）—— 火烧云与星空都不成立
  ///
  /// 注意 WMO `weather_code == 3`（阴）**不算**恶劣天气：它由总云量门槛处理，
  /// 在这里再叠加会重复惩罚。
  static bool isBadWeather(int? code) {
    if (code == null) return false;
    if (code == 45 || code == 48) return true; // 雾 / 雾凇
    if (code >= 51 && code <= 67) return true; // 毛毛雨 / 冻雨 / 雨
    if (code >= 71 && code <= 77) return true; // 雪
    if (code >= 80 && code <= 86) return true; // 阵性降水
    if (code >= 95) return true; // 雷暴
    return false;
  }

  /// WMO 天气码 → 中文简述
  static String weatherCodeText(int? code) {
    if (code == null) return '未知';
    if (code == 0) return '晴';
    if (code == 1) return '基本晴朗';
    if (code == 2) return '局部多云';
    if (code == 3) return '阴';
    if (code == 45 || code == 48) return '雾';
    if (code >= 51 && code <= 57) return '毛毛雨';
    if (code >= 61 && code <= 67) return '雨';
    if (code >= 71 && code <= 77) return '雪';
    if (code >= 80 && code <= 82) return '阵雨';
    if (code == 85 || code == 86) return '阵雪';
    if (code >= 95) return '雷暴';
    return '码 $code';
  }

  // ==================== 内部评分 ====================

  static PhotoScore _burn(ExtraHourly s, DateTime t, String kindName, DateTime day) {
    final mid = s.cloudMid ?? 0;
    final high = s.cloudHigh ?? 0;
    final total = s.cloudCover ?? math.max(mid, high);
    final low = s.cloudLow ?? total;

    final canvas = canvasCloud(mid, high);
    final canvasScore = _canvasScore(canvas);
    final lowScore = _lowCloudScore(low);
    final airScore = airQualityScore(s.aod, s.pm25);
    final visScore = _visScore(s.visibility);
    final precipScore = _precipScore(s.precipitation, s.precipProb);

    final base = (canvasScore * .40 +
            lowScore * .20 +
            airScore * .15 +
            visScore * .15 +
            precipScore * .10)
        .round()
        .clamp(0, 100);

    final gate = sunCloudGate(total: total, low: low, code: s.weatherCode);
    final score = (base * gate).round().clamp(0, 100);

    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');

    final factors = <String>[
      '**云量门槛 ${gate.toStringAsFixed(2)}** —— 总云量 ${total.round()}%'
          '（${weatherCodeText(s.weatherCode)}）'
          '${gate < 0.5 ? "，地面基本看不到天空，直接压制总分" : "，地面能看到天空"}',
      '中云 ${mid.round()}% + 高云 ${high.round()}% → 可照亮云量 '
          '${canvas.round()}%（并集，${canvasScore.round()} 分，30%~70% 最佳）',
      '低云 ${low.round()}%（${lowScore.round()} 分）',
      airText(s.aod, s.pm25, s.aqi, airScore),
      s.visibility == null
          ? '能见度 无数据'
          : '能见度 ${s.visibility!.toStringAsFixed(1)} km（${visScore.round()} 分）',
      '降水 ${(s.precipitation ?? 0).toStringAsFixed(1)} mm/h · 概率 ${s.precipProb ?? "--"}%'
          '（${precipScore.round()} 分）',
      if (canvas < 10) '中高云过少，缺少可被染色的云层，霞光会偏淡',
      if (canvas > 85) '中高云过厚，阳光难以穿透，大概率看不到霞光',
      if (low > 70) '低云较厚，地平线方向光路可能被挡',
      if (isBadWeather(s.weatherCode)) '当前有${weatherCodeText(s.weatherCode)}，火烧云条件不成立',
    ];

    return PhotoScore(
      time: t,
      kind: kindName == '日落' ? '火烧云（日落）' : '火烧云（日出）',
      label: '${_dayLabel(day)} $kindName $hh:$mm',
      score: score,
      baseScore: base,
      cloudGate: gate,
      gate: gate,
      factors: factors,
      cloudCover: s.cloudCover,
      cloudLow: s.cloudLow,
      cloudMid: s.cloudMid,
      cloudHigh: s.cloudHigh,
      visibility: s.visibility,
      humidity: s.humidity,
      precipProb: s.precipProb,
      weatherCode: s.weatherCode,
      aod: s.aod,
      pm25: s.pm25,
      aqi: s.aqi,
    );
  }

  static PhotoScore _star(
    ExtraWeather wx,
    ExtraHourly s,
    DateTime t,
    DateTime day,
    int bortle,
  ) {
    final total = s.cloudCover ?? 100;
    final low = s.cloudLow ?? total;

    final airScore = airQualityScore(s.aod, s.pm25);
    final visScore = _visScore(s.visibility);
    final dryScore = _drynessScore(s.humidity);
    final lowScore = _lowCloudScore(low);

    final base = (airScore * .35 + visScore * .30 + dryScore * .20 + lowScore * .15)
        .round()
        .clamp(0, 100);

    final cloudGate = starCloudGate(total: total, low: low, code: s.weatherCode);
    final moon = MoonCalculator.at(t, wx.lat, wx.lon);
    final lightFactor = BortleScale.factor(bortle);
    final gate = (cloudGate * moon.darknessFactor * lightFactor).clamp(0.0, 1.0);
    final score = (base * gate).round().clamp(0, 100);

    final factors = <String>[
      '**云量门槛 ${cloudGate.toStringAsFixed(2)}** —— 总云量 ${total.round()}%'
          '（${weatherCodeText(s.weatherCode)}）；观星要「万里无云」，'
          '5% 以内才满分，30% 已大幅压制',
      '**月光因子 ${moon.darknessFactor.toStringAsFixed(2)}**'
          ' —— ${moon.phaseName}（照亮 ${moon.illuminationPercent}%，月龄 '
          '${moon.ageDays.toStringAsFixed(1)} 天，高度角 ${moon.altitudeDeg.toStringAsFixed(1)}°）'
          '：${moon.interferenceText}',
      '**光污染因子 ${lightFactor.toStringAsFixed(2)}** —— Bortle ${BortleScale.fullOf(bortle)}'
          '：${BortleScale.descOf(bortle)}'
          '${BortleScale.isDarkEnough(bortle) ? "" : "（城区基本拍不到银河，建议前往暗空机位）"}',
      airText(s.aod, s.pm25, s.aqi, airScore, weight: '35%'),
      s.visibility == null
          ? '能见度 无数据'
          : '能见度 ${s.visibility!.toStringAsFixed(1)} km（${visScore.round()} 分，权重 30%）',
      s.humidity == null
          ? '湿度 无数据'
          : '湿度 ${s.humidity!.round()}%（${dryScore.round()} 分，权重 20%）',
      '低云 ${low.round()}%（${lowScore.round()} 分，权重 15%）',
      if (total >= 30) '总云量偏高，观星窗口有限',
      if (s.humidity != null && s.humidity! >= 90) '湿度极高，注意镜片结露',
      if (moon.illumination > 0.6 && moon.isUp) '月光明亮，银河与暗星云基本无法拍摄',
    ];

    return PhotoScore(
      time: t,
      kind: '星空',
      label: '${_dayLabel(day)}夜间 23:00',
      score: score,
      baseScore: base,
      cloudGate: cloudGate,
      gate: gate,
      factors: factors,
      cloudCover: s.cloudCover,
      cloudLow: s.cloudLow,
      cloudMid: s.cloudMid,
      cloudHigh: s.cloudHigh,
      visibility: s.visibility,
      humidity: s.humidity,
      precipProb: s.precipProb,
      weatherCode: s.weatherCode,
      aod: s.aod,
      pm25: s.pm25,
      aqi: s.aqi,
      moon: moon,
      bortle: bortle,
    );
  }

  // ==================== 空气质量 ====================

  /// 空气质量评分 0~100 —— **以 AOD 为主，PM2.5 兜底**
  ///
  /// AOD（气溶胶光学厚度）直接刻画大气消光，是摄影/天文最相关的量：
  /// 高原/海岛常年在 0.05 以下，而重霾城市可达 1.5 以上。
  /// AOD 缺失时退回 PM2.5（阈值参考国标一级 35 / 二级 75 μg/m³）。
  static double airQualityScore(double? aod, double? pm25) {
    if (aod != null) {
      if (aod <= 0.05) return 100;
      if (aod <= 0.10) return 97;
      if (aod <= 0.20) return 88;
      if (aod <= 0.35) return 70;
      if (aod <= 0.50) return 55;
      if (aod <= 0.80) return 38;
      if (aod <= 1.20) return 22;
      return 10;
    }
    if (pm25 != null) {
      if (pm25 <= 15) return 100;
      if (pm25 <= 35) return 85;
      if (pm25 <= 75) return 60;
      if (pm25 <= 115) return 38;
      if (pm25 <= 150) return 22;
      return 10;
    }
    return 60; // 无数据给中性分
  }

  /// 空气质量文案
  static String airText(double? aod, double? pm25, int? aqi, double score,
      {String? weight}) {
    final w = weight == null ? '' : '，权重 $weight';
    if (aod == null && pm25 == null) {
      return '空气质量 无数据（${score.round()} 分$w）';
    }
    final parts = <String>[];
    if (aod != null) parts.add('AOD ${aod.toStringAsFixed(2)}（${aodLevelText(aod)}）');
    if (pm25 != null) parts.add('PM2.5 ${pm25.round()}');
    if (aqi != null) parts.add('EAQI $aqi');
    return '${parts.join(' · ')}（${score.round()} 分$w）';
  }

  /// AOD 定性描述
  static String aodLevelText(double aod) {
    if (aod <= 0.10) return '极通透';
    if (aod <= 0.20) return '很通透';
    if (aod <= 0.35) return '一般';
    if (aod <= 0.60) return '偏浑浊';
    return '浑浊';
  }

  // ==================== 质量分小项 ====================

  /// 中云与高云按**概率并集**合成「可被照亮的云量」
  ///
  /// `1 − (1−mid)(1−high)`。用并集而非算术平均：中云 82% + 高云 0% 的真实含义
  /// 是**一层厚中云**（平均成 41% 会被误判为最佳区间），并集给出 82%，
  /// 正确反映"偏厚、会挡光"。
  static double canvasCloud(double mid, double high) {
    final m = (mid / 100).clamp(0.0, 1.0);
    final h = (high / 100).clamp(0.0, 1.0);
    return ((1 - (1 - m) * (1 - h)) * 100).clamp(0.0, 100.0);
  }

  /// 「可照亮云量」适中度：30%~70% 满分，两侧线性衰减
  static double _canvasScore(double canvas) {
    if (canvas >= 30 && canvas <= 70) return 100;
    if (canvas < 30) {
      if (canvas <= 5) return 5;
      return 5 + (canvas - 5) / 25 * 95;
    }
    if (canvas >= 95) return 10;
    return 100 - (canvas - 70) / 25 * 90;
  }

  /// 低云越少越好：≤20% 满分；≥70% 只剩 20 分
  static double _lowCloudScore(double low) {
    if (low <= 20) return 100;
    if (low >= 70) return 20;
    return 100 - (low - 20) / 50 * 80;
  }

  /// 能见度分：≥20km 满分；≤3km 只剩 10 分
  static double _visScore(double? visKm) {
    if (visKm == null) return 60;
    if (visKm >= 20) return 100;
    if (visKm <= 3) return 10;
    return 10 + (visKm - 3) / 17 * 90;
  }

  /// 降水惩罚：正在下雨 → 20；概率高 → 50；否则 100
  static double _precipScore(double? precip, int? prob) {
    if ((precip ?? 0) >= 0.5) return 20;
    if ((prob ?? 0) >= 70) return 50;
    if ((prob ?? 0) >= 40) return 80;
    return 100;
  }

  /// 干燥度：湿度越低越利于观星
  static double _drynessScore(double? hum) {
    if (hum == null) return 60;
    if (hum <= 50) return 100;
    if (hum >= 90) return 20;
    return 100 - (hum - 50) / 40 * 80;
  }

  /// 「今日 / 明日 / 月日」标签
  static String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final d0 = DateTime(now.year, now.month, now.day);
    final dd = DateTime(day.year, day.month, day.day);
    final diff = dd.difference(d0).inDays;
    if (diff == 0) return '今日';
    if (diff == 1) return '明日';
    return '${day.month}/${day.day}';
  }

  // ==================== 批量 ====================

  /// 未来 [days] 天内所有日落机会（已过滤掉过去的机会）
  static List<PhotoScore> bestSunsets(ExtraWeather wx, {int days = 3}) {
    final out = <PhotoScore>[];
    final now = DateTime.now();
    for (var i = 0; i < days; i++) {
      final d = DateTime(now.year, now.month, now.day).add(Duration(days: i));
      final s = sunset(wx, d);
      if (s != null && s.time.isAfter(now.subtract(const Duration(hours: 1)))) out.add(s);
    }
    return out;
  }

  /// 未来 [days] 天内所有星空机会
  static List<PhotoScore> bestStarry(
    ExtraWeather wx, {
    int days = 3,
    int bortle = BortleScale.defaultLevel,
  }) {
    final out = <PhotoScore>[];
    final now = DateTime.now();
    for (var i = 0; i < days; i++) {
      final d = DateTime(now.year, now.month, now.day).add(Duration(days: i));
      final s = starry(wx, d, bortle: bortle);
      if (s != null) out.add(s);
    }
    return out;
  }

  // ==================== 当日光线时刻 ====================

  /// 一天的摄影相关时刻（日出日落 / 黄金 / 蓝调 / 月出月落）
  ///
  /// 出处：计划任务 9-1「日出/日落/蓝调/黄金时刻、月相、月出月落（按坐标+日期）」。
  /// 日出日落来自 Open-Meteo daily，其余由 App 自行天文计算。
  static DayPhotoTimes dayTimes(ExtraWeather wx, DateTime day) {
    final sunrise = wx.sunriseOn(day);
    final sunset = wx.sunsetOn(day);
    return DayPhotoTimes(
      sunrise: sunrise,
      sunset: sunset,
      eveningGolden: sunset == null
          ? const PhotoTimeWindow(name: '黄金时刻')
          : SolarCalculator.goldenHourEvening(sunset, wx.lat, wx.lon),
      eveningBlue: sunset == null
          ? const PhotoTimeWindow(name: '蓝调时刻')
          : SolarCalculator.blueHourEvening(sunset, wx.lat, wx.lon),
      morningBlue: sunrise == null
          ? const PhotoTimeWindow(name: '蓝调时刻')
          : SolarCalculator.blueHourMorning(sunrise, wx.lat, wx.lon),
      morningGolden: sunrise == null
          ? const PhotoTimeWindow(name: '黄金时刻')
          : SolarCalculator.goldenHourMorning(sunrise, wx.lat, wx.lon),
      moonrise: MoonCalculator.moonrise(day, wx.lat, wx.lon),
      moonset: MoonCalculator.moonset(day, wx.lat, wx.lon),
      moonAt23: MoonCalculator.at(DateTime(day.year, day.month, day.day, 23), wx.lat, wx.lon),
    );
  }

  /// 在若干机会里挑分数最高的
  static PhotoScore? best(List<PhotoScore> scores) {
    if (scores.isEmpty) return null;
    var b = scores.first;
    for (final s in scores) {
      if (s.score > b.score) b = s;
    }
    return b;
  }

  /// 供 UI 排序
  static int byScoreDesc(PhotoScore a, PhotoScore b) => b.score.compareTo(a.score);
}

/// 一天的摄影相关时刻（日出日落 / 黄金时刻 / 蓝调时刻 / 月出月落）
class DayPhotoTimes {
  final DateTime? sunrise;
  final DateTime? sunset;

  final PhotoTimeWindow morningBlue;
  final PhotoTimeWindow morningGolden;
  final PhotoTimeWindow eveningGolden;
  final PhotoTimeWindow eveningBlue;

  final DateTime? moonrise;
  final DateTime? moonset;

  /// 当晚 23:00 的月亮状态
  final MoonInfo moonAt23;

  const DayPhotoTimes({
    this.sunrise,
    this.sunset,
    this.morningBlue = const PhotoTimeWindow(name: '蓝调时刻'),
    this.morningGolden = const PhotoTimeWindow(name: '黄金时刻'),
    this.eveningGolden = const PhotoTimeWindow(name: '黄金时刻'),
    this.eveningBlue = const PhotoTimeWindow(name: '蓝调时刻'),
    this.moonrise,
    this.moonset,
    required this.moonAt23,
  });

  /// `18:04` 格式化
  static String hhmm(DateTime? t) => t == null
      ? '—'
      : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
