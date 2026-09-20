/// 光污染 Bortle 暗空分级
///
/// 计划（任务 9-3）的原方案：**用户预存常用机位的 Bortle 等级（本地配置，
/// 无需在线地图）**。光污染本质是**地点属性**而非气象量，所以不需要任何
/// 在线数据源 —— 用户自己知道常去的机位有多暗。
///
/// 当前实现：内置分级表 + 一个合理的默认值，用户可在摄影页直接调节，
/// 选择结果存入 shared_preferences。
class BortleScale {
  BortleScale._();

  /// 等级 1~9 → 简称与说明
  static const Map<int, String> labels = {
    1: '极暗',
    2: '典型真暗',
    3: '乡村暗空',
    4: '乡村/郊区',
    5: '郊区',
    6: '亮郊区',
    7: '城郊过渡',
    8: '城市',
    9: '城市中心',
  };

  static const Map<int, String> descriptions = {
    1: '原始暗空 · 银河投下阴影 · 肉眼可见黄道光',
    2: '银河结构清晰 · 夏季可辨 M33',
    3: '银河明亮 · 光污染仅在地平线附近',
    4: '银河仍清晰 · 地平线有光穹',
    5: '银河黯淡 · 仅隐约可见',
    6: '银河仅在天顶附近勉强可见',
    7: '银河基本不可见 · 天光明显发灰',
    8: '整个天空发亮 · 仅亮星与行星可见',
    9: '天空明亮 · 仅少数亮星可见',
  };

  /// **默认等级**：中国大陆地级市城区的典型值
  ///
  /// 用户可在摄影页直接改（计划要求的"预存机位等级"体现在这里）。
  static const int defaultLevel = 7;

  static String labelOf(int b) => labels[b] ?? '未知';
  static String descOf(int b) => descriptions[b] ?? '';

  /// 完整描述：`7 城郊过渡`
  static String fullOf(int b) => '$b ${labelOf(b)}';

  /// **光污染因子 0~1**（乘进星空评分）
  ///
  /// 与计划里的线性扣分等价：文档写 `分 -= (Bortle − 1) × 6`，
  /// 即 Bortle 9 在百分制上扣 48 分。这里换算成**乘法因子** `1 − (b−1)×0.06`，
  /// 好处是不会把分数压成负数，且对不同量级的基数影响比例一致。
  static double factor(int bortle) {
    final b = bortle.clamp(1, 9);
    return (1.0 - (b - 1) * 0.06).clamp(0.0, 1.0);
  }

  /// 是否属于"暗到能拍银河"的等级（Bortle ≤ 4）
  static bool isDarkEnough(int bortle) => bortle <= 4;
}
