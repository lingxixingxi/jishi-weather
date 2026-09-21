import 'package:flutter/material.dart';

import '../data/radar_stations.dart';
import '../services/amap_location_service.dart';
import '../services/amap_service.dart';
import '../services/app_settings.dart';
import '../services/background_tasks.dart';
import '../services/nmc_city_repository.dart';
import '../services/nmc_service.dart';
import '../services/nmc_station_radar.dart';
import '../services/weather_alert_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart' show PanelCard, ScreenScaffold;

/// 设置页
///
/// · 开关两类天气提醒（每小时变化 / 每日次日预报）
/// · 设置提醒地点（默认跟随地点查询的定位）
/// · 为将来公测预留 API Key 填写位
/// · 展示后台任务注册状态（便于排查"到底有没有生效"）
class SettingsScreen extends StatefulWidget {
  /// 当前定位（用于「把提醒地点设为当前位置」）
  final ({double lat, double lon, String name})? currentLocation;

  const SettingsScreen({super.key, this.currentLocation});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loading = true;
  bool _hourly = false;
  bool _daily = false;
  ({double lat, double lon, String name})? _loc;
  String _taskInfo = '';
  String _lastCheckMsg = '';
  bool _busy = false;

  final _apiCtrl = TextEditingController();

  /// 反地理编码（把坐标换成可读地名）
  final _amap = AmapService();
  final _nmc = NmcService();
  late final NmcCityRepository _cityRepo = NmcCityRepository(_nmc, _amap);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiCtrl.dispose();
    _amap.dispose();
    _nmc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final hourly = await AppSettings.hourlyAlertEnabled();
    final daily = await AppSettings.dailyAlertEnabled();
    var loc = await AppSettings.alertLocation();
    // 还没设过提醒地点 → 用当前定位兜底
    final cur = widget.currentLocation;
    if (loc == null && cur != null) {
      loc = (lat: cur.lat, lon: cur.lon, name: cur.name);
      await AppSettings.setAlertLocation(cur.lat, cur.lon, cur.name);
    }
    final key = await AppSettings.publicApiKey();
    if (!mounted) return;
    setState(() {
      _hourly = hourly;
      _daily = daily;
      _loc = loc;
      _apiCtrl.text = key;
      _loading = false;
    });
    await _refreshTasks();
  }

  Future<void> _refreshTasks() async {
    try {
      final info = await BackgroundTasks.describe();
      if (mounted) setState(() => _taskInfo = info);
    } catch (e) {
      if (mounted) setState(() => _taskInfo = '查询失败：$e');
    }
  }

  Future<void> _toggleHourly(bool v) async {
    setState(() => _busy = true);
    await AppSettings.setHourlyAlert(v);
    if (v) {
      final ok = await WeatherAlertService.requestPermission();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未获得通知权限，提醒可能不会显示')),
        );
      }
    }
    final daily = await AppSettings.dailyAlertEnabled();
    await BackgroundTasks.syncWithSettings(hourly: v, daily: daily);
    if (!mounted) return;
    setState(() {
      _hourly = v;
      _busy = false;
    });
    await _refreshTasks();
  }

  Future<void> _toggleDaily(bool v) async {
    setState(() => _busy = true);
    await AppSettings.setDailyAlert(v);
    if (v) {
      final ok = await WeatherAlertService.requestPermission();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未获得通知权限，提醒可能不会显示')),
        );
      }
    }
    final hourly = await AppSettings.hourlyAlertEnabled();
    await BackgroundTasks.syncWithSettings(hourly: hourly, daily: v);
    if (!mounted) return;
    setState(() {
      _daily = v;
      _busy = false;
    });
    await _refreshTasks();
  }

  /// 用当前位置作为提醒地点
  ///
  /// 设置页是从任意页面的顶栏进来的，拿不到别处的定位结果，
  /// 所以这里**自己重新定位**（用户可能已经移动了）。
  Future<void> _useCurrentLocation() async {
    setState(() => _busy = true);
    try {
      final GeoPoint? located =
          await AmapLocationService.locate(timeout: const Duration(seconds: 8));
      final GeoPoint? p = located ?? await _amap.ipLocation(); // 真实定位失败时用 IP 兜底
      if (!mounted) return;
      if (p == null) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('定位失败，请确认已开启定位权限')),
        );
        return;
      }
      var name = '当前位置 ${p.lat.toStringAsFixed(3)},${p.lon.toStringAsFixed(3)}';
      try {
        final addr = await _cityRepo.addressAt(p.lat, p.lon);
        if (addr != null && addr.formatted.isNotEmpty) name = addr.formatted;
      } catch (_) {
        // 反查失败不影响使用坐标
      }
      await AppSettings.setAlertLocation(p.lat, p.lon, name);
      if (!mounted) return;
      setState(() {
        _loc = (lat: p.lat, lon: p.lon, name: name);
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提醒地点已设为「$name」')),
      );
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      debugPrint('[设置] 定位失败: $e');
    }
  }

  Future<void> _runCheckNow() async {
    setState(() => _busy = true);
    // alsoDaily: 顺手把每日推送也发一条，方便验证推送通道
    final msg = await WeatherAlertService.checkAndNotify(
      force: true,
      alsoDaily: true,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastCheckMsg = msg;
    });
    await _refreshTasks();
  }

  Future<void> _saveApiKey() async {
    await AppSettings.setPublicApiKey(_apiCtrl.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_apiCtrl.text.trim().isEmpty ? '已清空 API Key' : '已保存 API Key')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: '设置',
      subtitle: '提醒开关 · 提醒地点 · 公测 API Key',
      children: [
        if (_loading)
          const PanelCard(
            heading: '设置',
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.accent),
                ),
                SizedBox(width: 10),
                Text('读取设置…',
                    style: TextStyle(fontSize: 12.5, color: AppTheme.textDim)),
              ],
            ),
          )
        else ...[
          // ==================== 天气提醒 ====================
          PanelCard(
            heading: '天气提醒',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _switchRow(
                  title: '每小时天气变化提醒',
                  desc: '每小时检查一次，天气现象 / 气温 / 降水概率 / 雨强'
                      '有明显变化时才通知（不变则不打扰）',
                  value: _hourly,
                  onChanged: _busy ? null : _toggleHourly,
                ),
                const Divider(height: 22, color: AppTheme.borderSoft),
                _switchRow(
                  title: '每日天气推送',
                  desc: '约 24:00 推送次日预报（含天气、气温、降水概率）。'
                      '系统后台调度不保证精确到点，可能有几十分钟漂移',
                  value: _daily,
                  onChanged: _busy ? null : _toggleDaily,
                ),
                const Divider(height: 22, color: AppTheme.borderSoft),
                Row(
                  children: [
                    const Text('提醒地点',
                        style: TextStyle(fontSize: 13, color: AppTheme.text)),
                    const SizedBox(width: 10),
                    // 地名可能很长（如「江苏省南京市江宁区东山街道上元大街164号武夷花园」），
                    // 必须给 Flexible + 省略号，否则会把标签挤没并顶出容器
                    Expanded(
                      child: Text(
                        _loc == null ? '未设置' : _loc!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.accent),
                      ),
                    ),
                  ],
                ),
                if (_loc != null)
                  Builder(builder: (_) {
                    final st = nearestRadarStation(_loc!.lat, _loc!.lon);
                    final dist = NmcStationRadar.distanceKm(
                        _loc!.lat, _loc!.lon, st.lat, st.lon);
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        // 控制长度：之前带站点码 + 3 位小数会超出容器宽度
                        '${_loc!.lat.toStringAsFixed(2)}, '
                        '${_loc!.lon.toStringAsFixed(2)}　'
                        '最近站 ${st.name} · ${dist.toStringAsFixed(0)} km'
                        '${dist > NmcStationRadar.coverageKm ? '（超出覆盖）' : ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10.5, color: AppTheme.textFaint, height: 1.4),
                      ),
                    );
                  }),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _useCurrentLocation,
                        icon: const Icon(Icons.my_location, size: 16),
                        label: const Text('用当前位置'),
                        style: _ghostStyle(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _runCheckNow,
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('立即检查一次'),
                        style: _ghostStyle(),
                      ),
                    ),
                  ],
                ),
                if (_lastCheckMsg.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('上次检查：$_lastCheckMsg',
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textDim, height: 1.4)),
                  ),
              ],
            ),
          ),

          // ==================== 公测 API Key ====================
          PanelCard(
            heading: '公测 API Key（预留）',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '当前内测版的 Key 已内置在安装包里，无需填写。\n'
                  '将来公测版会把 Key 改由用户自己提供，到那时在这里填入即可。',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.textDim, height: 1.5),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _apiCtrl,
                  style: const TextStyle(fontSize: 13, color: AppTheme.text),
                  decoration: InputDecoration(
                    hintText: '粘贴 API Key（留空表示使用内置）',
                    hintStyle:
                        const TextStyle(fontSize: 12.5, color: AppTheme.textFaint),
                    filled: true,
                    fillColor: AppTheme.bgInset,
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: AppTheme.borderSoft),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: AppTheme.borderSoft),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: AppTheme.accent),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _saveApiKey,
                    style: _ghostStyle(),
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ),

          // ==================== 后台任务状态 ====================
          PanelCard(
            heading: '后台任务状态',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Android 的后台调度由系统统一安排（省电优先），'
                  '实际触发时间可能比设定的晚几分钟到几十分钟。',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.textDim, height: 1.5),
                ),
                const SizedBox(height: 8),
                Text(
                  _taskInfo.isEmpty ? '（暂无信息）' : _taskInfo,
                  style: const TextStyle(
                      fontSize: 10.5, color: AppTheme.textFaint, height: 1.4),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _refreshTasks,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('刷新'),
                    style: _ghostStyle(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static ButtonStyle _ghostStyle() => OutlinedButton.styleFrom(
        foregroundColor: AppTheme.accent,
        side: const BorderSide(color: AppTheme.border),
        padding: const EdgeInsets.symmetric(vertical: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      );

  Widget _switchRow({
    required String title,
    required String desc,
    required bool value,
    required void Function(bool)? onChanged,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13.5,
                        color: AppTheme.text,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(desc,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textDim, height: 1.45)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppTheme.accent,
          ),
        ],
      );
}
