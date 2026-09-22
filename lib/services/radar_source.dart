import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/radar_stations.dart';
import 'nmc_station_radar.dart';
import 'radar_projection.dart';
import 'radar_service.dart';

/// 选定的雷达数据源：帧序列 + 投影 + 出处
///
/// 把「用哪个源」与「怎么分析」解耦：选源由 [RadarSourcePicker] 决定，
/// 分析一律走 `RadarService`（自动按 [projection] 换算）。
class RadarSource {
  /// 该源的投影（拼图 / 单站）
  final RadarProjection projection;

  /// 帧序列（按时间正序，旧 → 新）
  final List<RadarRawFrame> frames;

  /// 是否来自**单站雷达**（false = 拼图兜底）
  final bool fromStation;

  /// 单站雷达最近一次可用的观测时间
  ///
  /// **即使已过期也会带上** —— 拼图兜底时需要在 UI 上如实告诉用户
  /// 「单站上次更新是几点」，否则用户无法判断兜底数据的可信度。
  final DateTime? stationLastTime;

  /// 距离最近的雷达站（拼图兜底时也保留，用于说明「查过哪个站」）
  final RadarStation? station;

  /// 到最近雷达站的距离（km）
  final double? stationDistanceKm;

  const RadarSource({
    required this.projection,
    required this.frames,
    this.fromStation = false,
    this.stationLastTime,
    this.station,
    this.stationDistanceKm,
  });

  bool get isEmpty => frames.isEmpty;

  /// 数据源标签（日志 / UI）
  String get label => projection.label;

  /// 空间精度描述
  String get resolutionText => fromStation
      ? '约 ${projection.kmPerPixel.toStringAsFixed(2)} km/像素'
      : '约 ${projection.kmPerPixel.toStringAsFixed(1)} km/像素';
}

/// 雷达数据源选择器 —— **单站优先，查过且过期才回退拼图**
///
/// 这是「雷达定调」用哪张图的口径统一入口。地点查询 / 出行路线 / 赛道研判
/// 三处的判断逻辑必须完全一致，所以规则只写在这里一份。
///
/// ## 规则
/// 1. 找离目标点最近的雷达站；若在 256 km 覆盖内 → **先查单站**
///    （单站图 0.68 km/px，精度约为拼图的 4 倍）
/// 2. 单站最近一帧距今 ≤ [RadarService.stationFreshMinutes]（60 分钟）
///    → **用单站图**，并带上它的 [StationProjection]
/// 3. 单站查过但没有新鲜帧（无记录 / 已过期）→ **回退区域拼图**
///    （2.6 km/px，实测 80% 的窗口有数据），同时保留「单站上次更新时间」
///    供 UI 如实标注
/// 4. 目标点超出所有单站覆盖（或不在华东拼图范围内）→ 同样走拼图
///
/// ⚠️ 早期实现在 `RadarService.fetchRecentFrames` 里**无条件**把站点码
/// 替换成 `AECN`，等于主动放弃单站精度，且没有任何「有没有更新」的判断 ——
/// 本类就是来纠正这一点的。
class RadarSourcePicker {
  RadarSourcePicker._();

  /// 内置的华东拼图模板（仅取文件名模板，时间戳由取帧函数按当前 UTC 重算）
  static const String mosaicTemplatePath = '/product/2026/01/01/RDCP/'
      'SEVP_AOC_RDCP_SLDAS3_ECREF_AECN_L88_PI_20260101000000000.PNG';

  /// 选源
  ///
  /// [mapRadarPath] 是央台接口给的雷达图路径；它可能指向单站（如南京返回
  /// `AZ9250`），此时**忽略其中的产品码**，只把它当作拼图的备用来源。
  static Future<RadarSource> pick({
    required double lat,
    required double lon,
    String? mapRadarPath,
    int count = 3,
    http.Client? client,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();

    // ---- 1) 先查单站 ----
    final st = nearestRadarStation(lat, lon);
    final dist = StationProjection.distanceKm(lat, lon, st.lat, st.lon);

    DateTime? stationLast;
    if (dist <= StationProjection.coverageKm) {
      List<RadarRawFrame> stationFrames;
      try {
        stationFrames = await NmcStationRadar.fetchRecent(
          stationCode: st.code,
          count: count,
          client: client,
          now: at,
        );
      } catch (e) {
        stationFrames = const [];
        debugPrint('[雷达选源] 单站 ${st.name}(${st.code}) 取图异常: $e');
      }

      stationLast = stationFrames.isEmpty ? null : stationFrames.last.time;
      final ageMin =
          stationLast == null ? null : at.difference(stationLast).inMinutes;

      if (stationLast != null && ageMin! <= RadarService.stationFreshMinutes) {
        // 新鲜 → 单站定调
        debugPrint('[雷达选源] 用【单站】${st.name}(${st.code}) '
            '距 ${dist.toStringAsFixed(0)}km · ${stationFrames.length} 帧 · '
            '最新 ${stationLast.hour.toString().padLeft(2, "0")}:'
            '${stationLast.minute.toString().padLeft(2, "0")}'
            '（$ageMin 分钟前）· 精度 ${StationProjection.stationKmPerPx} km/px');
        return RadarSource(
          projection: StationProjection(
            stationCode: st.code,
            stationName: st.name,
            stationLat: st.lat,
            stationLon: st.lon,
          ),
          frames: stationFrames,
          fromStation: true,
          stationLastTime: stationLast,
          station: st,
          stationDistanceKm: dist,
        );
      }

      debugPrint('[雷达选源] 单站 ${st.name}(${st.code}) 查过但'
          '${stationLast == null ? "无可用帧（4 小时窗口）" : "最新帧已 $ageMin 分钟前，超过 ${RadarService.stationFreshMinutes} 分钟"}'
          ' → 回退区域拼图');
    } else {
      debugPrint('[雷达选源] 最近站点 ${st.name} 距 ${dist.toStringAsFixed(0)}km，'
          '超出 ${StationProjection.coverageKm.toInt()}km 覆盖，直接用拼图');
    }

    // ---- 2) 回退拼图 ----
    //
    // 目标点若不在华东拼图覆盖内（海外赛道 / 中国西部），取帧也是白取 ——
    // 直接返回「空帧 + 拼图投影」，由调用方按「不在覆盖范围」提示，
    // 而不是让用户等一次注定失败的下载。
    const mosaic = EastChinaProjection();
    if (!mosaic.covers(lat, lon)) {
      debugPrint('[雷达选源] 目标点不在华东拼图覆盖内'
          '（${lat.toStringAsFixed(2)}, ${lon.toStringAsFixed(2)}），跳过取帧');
      return RadarSource(
        projection: mosaic,
        frames: const [],
        fromStation: false,
        stationLastTime: stationLast,
        station: st,
        stationDistanceKm: dist,
      );
    }

    final path = mapRadarPath ?? mosaicTemplatePath;
    final mosaicFrames = await RadarService.fetchRecentFrames(
      radarPath: path,
      count: count,
      client: client,
      now: at,
      forceMosaic: true,
    );

    return RadarSource(
      projection: const EastChinaProjection(),
      frames: mosaicFrames,
      fromStation: false,
      stationLastTime: stationLast,
      station: st,
      stationDistanceKm: dist,
    );
  }
}
