import '../services/radar_service.dart';

/// 单站雷达 × 和风 的交叉验证
///
/// 两个独立来源对「目标点此刻下不下雨、多大」的判断：
/// · **央台单站雷达**：0.68 km/像素，直接读像素得到的 dBZ，经 Z-R 关系反演降水；
/// · **和风天气**：其数值产品给出的降水强度。
///
/// 二者分歧时**优先信央台**（按用户 2026-09-21 的要求）——
/// 雷达是实况观测，模式/融合产品在「此刻这一格」上天然更弱。
///
/// 分歧判定（任一成立即为分歧）：
/// · 一方有雨（≥0.1 mm/h）另一方无雨；
/// · 双方都有雨，但差值 ≥ [absToleranceMmh]；
/// · 双方都有雨，且大者是小者的 [ratioTolerance] 倍以上。
class RadarCrossCheck {
  /// 央台单站雷达读到的 dBZ（null = 该像素无回波）
  final int? stationDbz;

  /// 央台单站雷达反演的降水（mm/h）
  final double? stationRainMmh;

  /// 和风给出的降水（mm/h）
  final double? qweatherRainMmh;

  /// 命中的雷达站名（展示用）
  final String stationName;

  /// 和风数据缺失（如未配置 Key）时为 false
  final bool qweatherAvailable;

  const RadarCrossCheck({
    required this.stationDbz,
    required this.stationRainMmh,
    required this.qweatherRainMmh,
    required this.stationName,
    this.qweatherAvailable = true,
  });

  /// 有雨阈值（mm/h）
  static const double rainThreshold = 0.1;

  /// 绝对差值容差
  static const double absToleranceMmh = 2.0;

  /// 倍数容差
  static const double ratioTolerance = 3.0;

  bool get _stationWet => (stationRainMmh ?? 0) >= rainThreshold;
  bool get _qweatherWet => (qweatherRainMmh ?? 0) >= rainThreshold;

  /// 两者是否分歧
  bool get diverged {
    if (!qweatherAvailable || qweatherRainMmh == null) return false;
    final a = stationRainMmh ?? 0;
    final b = qweatherRainMmh!;

    // 一方有雨、另一方没有
    if (_stationWet != _qweatherWet) return true;

    // 都没雨 → 一致
    if (!_stationWet && !_qweatherWet) return false;

    // 都有雨：看差值或倍数
    if ((a - b).abs() >= absToleranceMmh) return true;
    final hi = a > b ? a : b;
    final lo = a < b ? a : b;
    if (lo > 0 && hi / lo >= ratioTolerance) return true;
    return false;
  }

  /// 分歧时采用的降水值（信央台）
  double? get adoptedRainMmh => stationRainMmh;

  /// 一句话结论
  String get conclusion {
    if (!qweatherAvailable || qweatherRainMmh == null) {
      final s = stationRainMmh;
      return s == null || s < rainThreshold
          ? '$stationName 单站雷达：这一格无回波'
          : '$stationName 单站雷达：约 ${s.toStringAsFixed(1)} mm/h'
              '（无和风数据可比对）';
    }

    final a = stationRainMmh ?? 0;
    final b = qweatherRainMmh!;

    if (!diverged) {
      if (!_stationWet && !_qweatherWet) return '两个源一致：当前无降水';
      return '两个源一致：约 ${a.toStringAsFixed(1)} mm/h';
    }

    if (_stationWet && !_qweatherWet) {
      return '两者分歧（雷达有回波、和风报无雨）→ 以雷达为准：'
          '约 ${a.toStringAsFixed(1)} mm/h';
    }
    if (!_stationWet && _qweatherWet) {
      return '两者分歧（和风报有雨、雷达无回波）→ 以雷达为准：当前无降水';
    }
    return '两者分歧（雷达 ${a.toStringAsFixed(1)} vs 和风 ${b.toStringAsFixed(1)} mm/h）'
        '→ 以雷达为准：约 ${a.toStringAsFixed(1)} mm/h';
  }

  /// dBZ → 降水（mm/h），复用雷达服务的 Z-R 关系
  static double? rainFromDbz(int? dbz) {
    if (dbz == null) return null;
    return RadarService.dbzToRainRate(dbz);
  }
}
