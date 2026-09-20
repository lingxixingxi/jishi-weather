/// 气象预警信号模型
///
/// 数据来自**中央气象台预警发布接口**（免 key、国内直连）：
/// `http://www.nmc.cn/rest/findAlarm?pageNo=1&pageSize=500`
///
/// ## 实测返回（2026-09-20 抓取，勿凭猜测修改）
/// ```json
/// {"msg":"success","code":0,"data":{"page":{"pageNo":1,"pageSize":500,
///   "count":209,"prev":1,"next":2,"list":[
///     {"alertid":"52011341600000_20260920141525",
///      "issuetime":"2026/09/20 14:15",
///      "title":"贵州省贵阳市白云区气象台发布大风蓝色预警信号",
///      "url":"/publish/alarm/52011341600000_20260920141525.html",
///      "pic":"https://image.nmc.cn/assets/img/alarm/p0007004.png"}]}}}
/// ```
///
/// ## 两个关键坑
/// 1. `province=` / `prov=` 参数实测**会触发站点 500 错误页**（返回 HTML 而非
///    JSON），`pageSize=500` 时才拿到全量 209 条。→ 必须**拉全国全量后本地过滤**。
/// 2. `alertid` **前 6 位 = 行政区划代码**（`520113` = 贵阳市白云区），
///    用于与高德逆地理编码返回的 `adcode` 做前缀匹配。
library;

/// 预警等级（颜色）
enum WarningSeverity {
  blue(1, '蓝色'),
  yellow(2, '黄色'),
  orange(3, '橙色'),
  red(4, '红色');

  const WarningSeverity(this.rank, this.label);

  /// 危险度 1~4（越大越严重）
  final int rank;

  /// 中文色名
  final String label;

  static WarningSeverity? fromColor(String color) {
    switch (color) {
      case '蓝色':
        return WarningSeverity.blue;
      case '黄色':
        return WarningSeverity.yellow;
      case '橙色':
        return WarningSeverity.orange;
      case '红色':
        return WarningSeverity.red;
      default:
        return null;
    }
  }
}

/// 预警与目标点的行政区划关系
enum WarningScope {
  /// 同区县（adcode 前 6 位相同）
  district('本区县', 3),

  /// 同市（前 4 位相同）
  city('本市', 2),

  /// 同省（前 2 位相同）
  province('同省', 1);

  const WarningScope(this.label, this.rank);

  final String label;
  final int rank;
}

/// 一条气象预警信号
class WeatherWarning {
  /// alertid 原文
  final String id;

  /// alertid 前 6 位 = 行政区划代码
  final String adcode;

  /// 从标题提取的发布台站地名（如「贵州省贵阳市白云区」）
  final String region;

  /// 预警类型（大风 / 雷电 / 暴雨 / 高温 …），标题解析所得
  final String type;

  /// 等级；无法解析时为 null
  final WarningSeverity? severity;

  /// 标题原文
  final String title;

  final DateTime? issueTime;

  /// 详情页相对路径（需拼 `http://www.nmc.cn`）
  final String url;

  /// 图标 URL
  final String? iconUrl;

  const WeatherWarning({
    required this.id,
    required this.adcode,
    required this.region,
    required this.type,
    required this.severity,
    required this.title,
    this.issueTime,
    this.url = '',
    this.iconUrl,
  });

  /// 详情页完整地址
  String get detailUrl => url.isEmpty ? '' : 'http://www.nmc.cn$url';

  /// 危险度（无法解析等级时给 0）
  int get rank => severity?.rank ?? 0;

  /// 与给定 adcode 的行政区划关系（无交集返回 null）
  ///
  /// 逐级退让：先比前 6 位（本区县）→ 前 4 位（本市）→ 前 2 位（同省）。
  WarningScope? scopeFor(String? target) {
    if (target == null || target.length < 6 || adcode.length < 6) return null;
    if (adcode.substring(0, 6) == target.substring(0, 6)) return WarningScope.district;
    if (adcode.substring(0, 4) == target.substring(0, 4)) return WarningScope.city;
    if (adcode.substring(0, 2) == target.substring(0, 2)) return WarningScope.province;
    return null;
  }

  /// 解析一条原始记录
  static WeatherWarning? parse(Map raw) {
    final id = '${raw['alertid'] ?? ''}';
    if (id.length < 6) return null;
    final title = '${raw['title'] ?? ''}';
    final parsed = parseTitle(title);

    DateTime? t;
    final its = raw['issuetime'];
    if (its is String && its.isNotEmpty) {
      // "2026/09/20 14:15"
      final norm = its.replaceAll('/', '-');
      t = DateTime.tryParse(norm);
    }

    return WeatherWarning(
      id: id,
      adcode: id.substring(0, 6),
      region: parsed.region,
      type: parsed.type,
      severity: parsed.severity,
      title: title,
      issueTime: t,
      url: '${raw['url'] ?? ''}',
      iconUrl: raw['pic'] == null ? null : '${raw['pic']}',
    );
  }

  /// 从标题解析「地区 / 类型 / 等级」
  ///
  /// 典型标题：
  /// - `贵州省贵阳市白云区气象台发布大风蓝色预警信号`
  /// - `广东省广州市从化区气象台发布雷雨大风黄色预警信号`
  /// - `江西省赣州市寻乌县气象台发布雷电黄色预警信号`
  ///
  /// 注意部分站点会带后缀（如 `…暴雨橙色预警信号[II级/严重]`），
  /// 因此正则只锚定「气象台发布 … 颜色 + 预警」这一段，其余忽略。
  static ({String region, String type, WarningSeverity? severity}) parseTitle(String title) {
    final m = RegExp(r'^(.*?)气象台发布(.+?)(蓝色|黄色|橙色|红色)预警').firstMatch(title);
    if (m == null) {
      // 兜底：至少把颜色捞出来
      final c = RegExp(r'(蓝色|黄色|橙色|红色)').firstMatch(title)?.group(1);
      return (region: '', type: title, severity: c == null ? null : WarningSeverity.fromColor(c));
    }
    return (
      region: m.group(1) ?? '',
      type: m.group(2) ?? '',
      severity: WarningSeverity.fromColor(m.group(3) ?? ''),
    );
  }
}
