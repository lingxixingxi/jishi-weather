import 'dart:math' as math;

import '../services/open_meteo_extra.dart';

/// 摄影机会评分
class PhotoScore {
  /// 机会对应的时刻（日落 / 日出 / 夜间采样点）
  final DateTime time;

  /// 类型：火烧云 / 星空
  final String kind;

  /// 展示标签，如「今日日落 17:54」
  final String label;

  /// 0~100
  final int score;

  final List<String> factors;

  final double? cloudCover;
  final double? cloudLow;
  final double? cloudMid;
  final double? cloudHigh;
  final double? visibility;
  final double? humidity;
  final int? precipProb;

  const PhotoScore({
    required this.time,
    required this.kind,
    required this.label,
    required this.score,
    required this.factors,
    this.cloudCover,
    this.cloudLow,
    this.cloudMid,
    this.cloudHigh,
    this.visibility,
    this.humidity,
    this.precipProb,
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
}

/// 摄影指数引擎（火烧云 / 星空）
///
/// ## 模型说明
/// 两个指数都以 **Open-Meteo 分层云量**为核心（免 key 实测可用）：
/// `cloud_cover`（总）、`cloud_cover_low` / `mid` / `high`，
/// 辅以能见度、湿度与降水概率。
///
/// ### 火烧云（日落 / 日出）权重
/// | 因子 | 权重 | 说明 |
/// |---|---|---|
/// | 中高云「适中度」 | 40% | 云太少无云可烧、太多遮蔽光线，**30%~70% 最佳** |
/// | 低云少 | 25% | 低云会挡住地平线方向的通透光路 |
/// | 能见度 | 20% | 通透度，决定霞光是否干净 |
/// | 无降水 | 15% | 正在下雨/高降水概率会毁掉机会 |
///
/// ### 星空权重
/// | 因子 | 权重 | 说明 |
/// |---|---|---|
/// | 总云量少 | 50% | 决定性因子 |
/// | 低云少 | 20% | 低云最影响地面观星 |
/// | 能见度 | 15% | 通透度 / 气溶胶 |
/// | 干燥度 | 15% | 高湿容易起雾、结露、镜片起雾 |
///
/// 注意：**未纳入月相与光污染** —— 两者当前都无免 key 数据源，
/// 界面会显式标注这一局限，避免给出过度自信的评分。
class PhotoIndexEngine {
  PhotoIndexEngine._();

  /// 火烧云：日落
  static PhotoScore? sunset(ExtraWeather wx, DateTime day) {
    final t = wx.sunsetOn(day);
    if (t == null) return null;
    // 用日落前 30 分钟所在的小时点代表当时的云况
    final s = wx.nearest(t.subtract(const Duration(minutes: 30))) ?? wx.nearest(t);
    if (s == null) return null;
    return _burn(wx, s, t, '日落', day);
  }

  /// 火烧云：日出
  static PhotoScore? sunrise(ExtraWeather wx, DateTime day) {
    final t = wx.sunriseOn(day);
    if (t == null) return null;
    final s = wx.nearest(t.subtract(const Duration(minutes: 30))) ?? wx.nearest(t);
    if (s == null) return null;
    return _burn(wx, s, t, '日出', day);
  }

  /// 星空：取当地 23:00 的小时点
  static PhotoScore? starry(ExtraWeather wx, DateTime day) {
    final t = DateTime(day.year, day.month, day.day, 23, 0);
    final s = wx.nearest(t);
    if (s == null) return null;

    final cloud = s.cloudCover ?? 50;
    final low = s.cloudLow ?? cloud;
    final vis = s.visibility;
    final hum = s.humidity;

    final clearScore = (100 - cloud).clamp(0, 100).toDouble();
    final lowScore = _lowCloudScore(low);
    final visScore = _visScore(vis);
    final dryScore = _drynessScore(hum);

    final score = (clearScore * .50 + lowScore * .20 + visScore * .15 + dryScore * .15)
        .round()
        .clamp(0, 100);

    final factors = <String>[
      '总云量 ${cloud.round()}%（晴空度 ${clearScore.round()} 分）',
      '低云 ${low.round()}%（${lowScore.round()} 分）',
      vis == null ? '能见度 无数据' : '能见度 ${vis.toStringAsFixed(1)} km（${visScore.round()} 分）',
      hum == null ? '湿度 无数据' : '湿度 ${hum.round()}%（${dryScore.round()} 分）',
      if (cloud >= 80) '云量过高，基本无观星窗口',
      if (hum != null && hum >= 90) '湿度极高，注意镜片结露',
    ];

    return PhotoScore(
      time: t,
      kind: '星空',
      label: '${_dayLabel(day, wx)}夜间 23:00',
      score: score,
      factors: factors,
      cloudCover: s.cloudCover,
      cloudLow: s.cloudLow,
      cloudMid: s.cloudMid,
      cloudHigh: s.cloudHigh,
      visibility: s.visibility,
      humidity: s.humidity,
      precipProb: s.precipProb,
    );
  }

  // ==================== 内部 ====================

  static PhotoScore _burn(
    ExtraWeather wx,
    ExtraHourly s,
    DateTime t,
    String kindName,
    DateTime day,
  ) {
    final mid = s.cloudMid ?? 0;
    final high = s.cloudHigh ?? 0;
    // 中高云取均值作为「可被照亮的云量」
    final mh = (mid + high) / 2;
    final low = s.cloudLow ?? (s.cloudCover ?? 0);

    final mhScore = _midHighScore(mh);
    final lowScore = _lowCloudScore(low);
    final visScore = _visScore(s.visibility);
    final dryScore = _precipScore(s.precipitation, s.precipProb);

    final score = (mhScore * .40 + lowScore * .25 + visScore * .20 + dryScore * .15)
        .round()
        .clamp(0, 100);

    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');

    final factors = <String>[
      '中云 ${mid.round()}% / 高云 ${high.round()}% → 「可照亮云量」${mh.round()}%'
          '（${mhScore.round()} 分，30%~70% 最佳）',
      '低云 ${low.round()}%（${lowScore.round()} 分，越低越好）',
      s.visibility == null
          ? '能见度 无数据'
          : '能见度 ${s.visibility!.toStringAsFixed(1)} km（${visScore.round()} 分）',
      '降水 ${(s.precipitation ?? 0).toStringAsFixed(1)} mm/h'
          ' · 概率 ${s.precipProb ?? "--"}%（${dryScore.round()} 分）',
      if (mh < 10) '中高云过少，缺少可被染色的云层，霞光会偏淡',
      if (mh > 85) '中高云过厚，阳光难以穿透，大概率看不到霞光',
      if (low > 70) '低云较厚，地平线方向光路可能被挡',
    ];

    return PhotoScore(
      time: t,
      kind: kindName == '日落' ? '火烧云（日落）' : '火烧云（日出）',
      label: '${_dayLabel(day, wx)}$kindName $hh:$mm',
      score: score,
      factors: factors,
      cloudCover: s.cloudCover,
      cloudLow: s.cloudLow,
      cloudMid: s.cloudMid,
      cloudHigh: s.cloudHigh,
      visibility: s.visibility,
      humidity: s.humidity,
      precipProb: s.precipProb,
    );
  }

  /// 「可照亮云量」适中度：30%~70% 满分，两侧线性衰减
  static double _midHighScore(double mh) {
    if (mh >= 30 && mh <= 70) return 100;
    if (mh < 30) {
      if (mh <= 5) return 5;
      return 5 + (mh - 5) / 25 * 95;
    }
    if (mh >= 95) return 10;
    return 100 - (mh - 70) / 25 * 90;
  }

  /// 低云越少越好：≤20% 满分；≥70% 只剩 20 分
  static double _lowCloudScore(double low) {
    if (low <= 20) return 100;
    if (low >= 70) return 20;
    return 100 - (low - 20) / 50 * 80;
  }

  /// 能见度分：≥20km 满分；≤3km 只剩 10 分
  static double _visScore(double? visKm) {
    if (visKm == null) return 60; // 无数据给中性分，不惩罚也不奖励
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
  static String _dayLabel(DateTime day, ExtraWeather wx) {
    final now = DateTime.now();
    final d0 = DateTime(now.year, now.month, now.day);
    final dd = DateTime(day.year, day.month, day.day);
    final diff = dd.difference(d0).inDays;
    if (diff == 0) return '今日';
    if (diff == 1) return '明日';
    return '${day.month}/${day.day}';
  }

  /// 未来 [days] 天内所有日落机会，按分数倒序
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

  /// 未来 [days] 天内所有星空机会，按分数倒序
  static List<PhotoScore> bestStarry(ExtraWeather wx, {int days = 3}) {
    final out = <PhotoScore>[];
    final now = DateTime.now();
    for (var i = 0; i < days; i++) {
      final d = DateTime(now.year, now.month, now.day).add(Duration(days: i));
      final s = starry(wx, d);
      if (s != null) out.add(s);
    }
    return out;
  }

  /// 综合最优推荐（在日落与星空之间挑分数最高的）
  static PhotoScore? best(List<PhotoScore> scores) {
    if (scores.isEmpty) return null;
    var best = scores.first;
    for (final s in scores) {
      if (s.score > best.score) best = s;
    }
    return best;
  }

  /// 便于 UI 排序
  static int byScoreDesc(PhotoScore a, PhotoScore b) => b.score.compareTo(a.score);

  /// 数值夹取（供外部使用）
  static double clamp01(double v) => math.min(1, math.max(0, v));
}
