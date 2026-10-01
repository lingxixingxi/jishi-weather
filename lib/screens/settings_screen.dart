import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_identity.dart';
import '../data/radar_stations.dart';
import '../services/amap_location_service.dart';
import '../services/amap_service.dart';
import '../services/api_keys.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/background_tasks.dart';
import '../services/location_budget.dart';
import '../services/nmc_city_repository.dart';
import '../services/nmc_service.dart';
import '../services/nmc_station_radar.dart';
import '../services/qweather_budget.dart';
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

  // 三个「公测可填」的 Key（内测版留空 → 自动回退到包内 Secrets）
  final _amapWebCtrl = TextEditingController();
  final _amapAndroidCtrl = TextEditingController();
  final _qwKeyCtrl = TextEditingController();
  final _qwHostCtrl = TextEditingController();

  // 内置 Key 的今日用量（用户自填了对应 Key 时，该项不再受限）
  int _locUsed = 0;
  int _locRemain = 0;
  int _qwUsed = 0;
  int _qwRemain = 0;

  /// 日志缓冲里现有多少行（「问题反馈」卡片显示用）
  int _logLines = 0;

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
    _amapWebCtrl.dispose();
    _amapAndroidCtrl.dispose();
    _qwKeyCtrl.dispose();
    _qwHostCtrl.dispose();
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
    final amapWeb = await AppSettings.amapWebKey();
    final amapAndroid = await AppSettings.amapAndroidKey();
    final qwKey = await AppSettings.qweatherApiKey();
    final qwHost = await AppSettings.qweatherApiHost();
    // 内置 Key 的今日用量（用户自填了对应 Key 时 remain 返回 -1 = 不限）
    final locUsed = await LocationBudget.usedToday();
    final locRemain = await LocationBudget.remaining();
    final qwUsed = await QWeatherBudget.usedToday();
    final qwRemain = await QWeatherBudget.remaining();
    if (!mounted) return;
    setState(() {
      _hourly = hourly;
      _daily = daily;
      _loc = loc;
      _amapWebCtrl.text = amapWeb;
      _amapAndroidCtrl.text = amapAndroid;
      _qwKeyCtrl.text = qwKey;
      _qwHostCtrl.text = qwHost;
      _locUsed = locUsed;
      _locRemain = locRemain;
      _qwUsed = qwUsed;
      _qwRemain = qwRemain;
      _logLines = AppLog.lineCount;
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
  /// ⚠️ 这里**强制重新定位**（`forceRefresh`）：用户进设置页点这个按钮，
  /// 语义就是「按我**现在**所在的位置设提醒」，不能吃 [AmapLocationService]
  /// 那 3 分钟的共享缓存（其它页面的「预热定位」用缓存就够了）。
  Future<void> _useCurrentLocation() async {
    setState(() => _busy = true);
    try {
      final GeoPoint? located = await AmapLocationService.locate(
        timeout: const Duration(seconds: 8),
        forceRefresh: true,
      );
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

  /// 保存四个 Key 并**立即生效**
  ///
  /// 保存后必须重新 [_load]：用户「填了/清空了」自己的 Key 会改变
  /// 「走不走内置配额」这件事，额度面板的数字要跟着变。
  Future<void> _saveApiKeys() async {
    await AppSettings.setAmapWebKey(_amapWebCtrl.text);
    await AppSettings.setAmapAndroidKey(_amapAndroidCtrl.text);
    await AppSettings.setQweatherApiKey(_qwKeyCtrl.text);
    await AppSettings.setQweatherApiHost(_qwHostCtrl.text);
    await ApiKeys.reload();
    if (!mounted) return;
    await _load(); // 顺便刷新徽章与额度
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          !ApiKeys.hasAmapWeb
              ? '已保存，但高德 Web服务 Key 为空 —— 地点查询与路线规划不可用'
              : ApiKeys.hasQweather
                  ? '已保存并生效（含和风天气）'
                  : '已保存并生效（未填和风，将只用其余数据源）',
        ),
      ),
    );
  }

  /// 复制到剪贴板（包名 / SHA1 用）
  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制$label')),
    );
  }

  // ==================== 问题反馈 ====================

  /// 导出日志 → 拉起系统分享面板（选「邮件」就直接发给我）
  ///
  /// 走分享面板而不是直接 `mailto`：附件是分享面板带过去的，
  /// `mailto` 塞不下几十 KB 的日志正文。
  Future<void> _exportLogAndShare() async {
    setState(() => _busy = true);
    try {
      final file = await AppLog.exportToFile();
      if (!mounted) return;
      setState(() => _logLines = AppLog.lineCount);

      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'text/plain')],
        subject: '迹时天气 ${AppIdentity.appVersion} 问题反馈',
        text: '① 问题描述：在哪个页面、点了什么、期望看到什么、实际看到什么\n'
            '② 截图：把出问题那一屏一起附上\n'
            '③ 日志：见附件（已自动抹除 API Key，可直接发）',
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出 ${AppLog.lineCount} 行日志并拉起分享')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 复制日志全文到剪贴板 —— 分享面板不好使时的兜底
  Future<void> _copyLog() async {
    await Clipboard.setData(ClipboardData(text: AppLog.dump()));
    if (!mounted) return;
    setState(() => _logLines = AppLog.lineCount);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${AppLog.lineCount} 行日志，粘贴进邮件正文即可')),
    );
  }

  /// 直接拉起邮件 App（收件人与主题已填好）
  Future<void> _sendFeedbackMail() async {
    // ⚠️ 不要用 Uri(queryParameters:) —— 它按表单规则把空格编成 `+`，
    //    邮件客户端会原样显示成加号。这里手工用 %20。
    String enc(String s) => Uri.encodeComponent(s);
    final body = '【1】问题描述（在哪个页面、点了什么、期望看到什么、实际看到什么）：\n\n\n'
        '【2】复现步骤：\n1. \n2. \n3. \n\n'
        '【3】截图：请把出问题的那个界面截图一起附上（可以直接贴在邮件正文里）\n\n'
        '【4】日志：请把「导出日志」得到的文件作为附件加上\n'
        '　　—— 描述 + 截图 + 日志三样齐全，通常一次就能定位；只发一句「用不了」我只能靠猜。\n\n'
        '————————————————————\n'
        '应用版本：${AppIdentity.appVersion}'
        '（${ApiKeys.isPublicBuild ? "公测版" : "内测版"}）\n'
        '日志文件已自动抹除所有 API Key，可放心发送。';
    final uri = Uri.parse(
      'mailto:${AppIdentity.feedbackEmail}'
      '?subject=${enc("迹时天气 ${AppIdentity.appVersion} 问题反馈")}'
      '&body=${enc(body)}',
    );

    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[反馈] 拉起邮件失败: $e');
    }
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('没找到可用的邮件应用，请手动发到 '
            '${AppIdentity.feedbackEmail}'),
      ),
    );
  }

  /// Key 配置状态徽章
  Widget _keyBadge(String label, bool ok) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: ok ? AppTheme.green.withValues(alpha: .14) : AppTheme.bgInset,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: ok
                ? AppTheme.green.withValues(alpha: .55)
                : AppTheme.borderSoft,
          ),
        ),
        child: Text(
          '$label ${ok ? "已配置" : "未配置"}',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: ok ? AppTheme.green : AppTheme.textFaint,
          ),
        ),
      );

  /// 单个 Key 输入项（说明文字 + 输入框）
  Widget _keyField({
    required TextEditingController ctrl,
    required String hint,
    required String note,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(note,
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textFaint, height: 1.45)),
          const SizedBox(height: 5),
          TextField(
            controller: ctrl,
            style: const TextStyle(fontSize: 13, color: AppTheme.text),
            decoration: InputDecoration(
              hintText: hint,
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
        ],
      );

  /// 包名 + SHA1 —— 用户申请自己的高德 Android Key 时要用，点右侧可复制
  ///
  /// 这两个值**不是秘密**（谁都能从 APK 里读出来），但必须一字不差，
  /// 否则高德会拒签、地图白屏。调试签名与发布签名不同，这里给的是发布包。
  Widget _identityBlock() => Container(
        margin: const EdgeInsets.only(top: 7),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          color: AppTheme.bgInset,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _copyRow('包名', AppIdentity.packageName),
            const SizedBox(height: 6),
            _copyRow('签名 SHA1', AppIdentity.sha1),
          ],
        ),
      );

  Widget _copyRow(String label, String value) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: const TextStyle(fontSize: 10.5, color: AppTheme.textFaint),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                color: AppTheme.textDim,
                height: 1.4,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => _copy(label, value),
            borderRadius: BorderRadius.circular(5),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                '复制',
                style: TextStyle(fontSize: 10.5, color: AppTheme.accent),
              ),
            ),
          ),
        ],
      );

  /// 内置 Key 今日额度 —— 存在的主要目的是**推动用户填自己的 Key**
  ///
  /// 两份额度的计量单位不同，必须分开说：
  /// · 高德 = 1 次在线定位 = 1 单位（图面渲染不计费，所以地图随便拖）
  /// · 和风 = 1 个采样点 = 1 单位，一次路线研判固定取 N 个点，
  ///   所以要额外折算成「还能做几次研判」，否则用户看不懂那个数字
  Widget _quotaPanel() {
    // 内测版完全不设限 —— 直接换一句说明，**不显示数字**。
    // 显示「已用 x/20」会让人以为内测版也被限，反而误导。
    if (!ApiKeys.isPublicBuild) return _unmeteredPanel();

    final ownLoc = ApiKeys.hasOwnAmapAndroid;
    final ownQw = ApiKeys.hasOwnQweather;
    final qwRuns = _qwRemain < 0
        ? -1
        : (_qwRemain / QWeatherBudget.maxPointsPerRun).floor();
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
      decoration: BoxDecoration(
        color: AppTheme.bgInset,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppTheme.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.speed, size: 13, color: AppTheme.textFaint),
              const SizedBox(width: 5),
              const Text(
                '内置 Key · 今日额度',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textDim,
                ),
              ),
              const Spacer(),
              const Text(
                '按本机计',
                style: TextStyle(fontSize: 10, color: AppTheme.textFaint),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _quotaRow(
            '定位',
            ownLoc
                ? '不限 · 你已填自己的 Key'
                : '已用 $_locUsed / ${LocationBudget.dailyLimit} · '
                    '剩 $_locRemain 次',
            unlimited: ownLoc,
          ),
          const SizedBox(height: 4),
          _quotaRow(
            '和风天气',
            ownQw
                ? '不限 · 你已填自己的 Key'
                : '已用 $_qwUsed / ${QWeatherBudget.dailyLimit} · '
                    '剩 $_qwRemain 次',
            unlimited: ownQw,
          ),
          if (!ownQw && qwRuns >= 0) ...[
            const SizedBox(height: 6),
            Text(
              '≈ 还能做 $qwRuns 次「路线研判」'
              '（一次研判固定取 ${QWeatherBudget.maxPointsPerRun} 个采样点）',
              style: const TextStyle(
                  fontSize: 10.5, color: AppTheme.textFaint, height: 1.45),
            ),
          ],
          const SizedBox(height: 9),
          const Text(
            '这两份额度是所有使用内置 Key 的用户共享的，本机限制只挡单台设备，'
            '挡不住人多。填上你自己的 Key 后完全不受限，也不再占用大家的份额。',
            style: TextStyle(
                fontSize: 10.5, color: AppTheme.textFaint, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// 内测版：不设任何额度限制
  Widget _unmeteredPanel() => Container(
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
        decoration: BoxDecoration(
          color: AppTheme.bgInset,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppTheme.borderSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_user,
                    size: 13, color: AppTheme.green),
                const SizedBox(width: 5),
                const Text(
                  '内测版 · 不设额度限制',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            const Text(
              '内置 Key 供内部使用，定位与和风天气均不计数、不拦截。\n'
              '额度限制只对公测版中「没有自填 Key」的用户生效。',
              style: TextStyle(
                  fontSize: 10.5, color: AppTheme.textFaint, height: 1.5),
            ),
          ],
        ),
      );

  Widget _quotaRow(String label, String value, {required bool unlimited}) =>
      Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: AppTheme.textDim),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: unlimited ? AppTheme.green : AppTheme.accent,
              ),
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: '设置',
      subtitle: '提醒开关 · 提醒地点 · 数据源 Key · 额度',
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

          // ==================== API Key（数据源配置）====================
          PanelCard(
            heading: 'API Key · 数据源配置',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _keyBadge('高德 Web', ApiKeys.hasAmapWeb),
                    _keyBadge('高德安卓', ApiKeys.amapAndroid.isNotEmpty),
                    _keyBadge('和风天气', ApiKeys.hasQweather),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  ApiKeys.isPublicBuild
                      ? '公测版不带内置 Key，请尽量填自己的。\n'
                          '高德 Web服务 Key 建议必填 —— 不填就只能蹭发布者那份'
                          '共享额度，人多时会用完；和风天气可选，'
                          '不填则少一个数据源（其余源不受影响）。'
                      : '内测版已内置 Key，下面全部留空即可 —— '
                          '内测版不设任何额度限制。\n'
                          '若要改用自己的 Key，填入后会优先使用你那一份。',
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textDim, height: 1.5),
                ),
                const SizedBox(height: 12),
                _quotaPanel(),
                const SizedBox(height: 16),
                _keyField(
                  ctrl: _amapWebCtrl,
                  hint: '高德 Web服务 Key',
                  note: '① 高德 Web服务 Key —— 地理编码 / 路线规划 / 静态地图\n'
                      '申请：lbs.amap.com → 应用管理 → 创建应用 → 添加 Key，'
                      '服务平台选「Web服务」\n'
                      '只填 Key 字符串本身，前后不要带空格或别的参数。',
                ),
                const SizedBox(height: 14),
                _keyField(
                  ctrl: _amapAndroidCtrl,
                  hint: '高德 Android 平台 Key',
                  note: '② 高德 Android 平台 Key —— 地图显示 / 在线定位（可留空）\n'
                      '它跟「包名 + 签名 SHA1」绑死，必须为这个 App 新建一个：\n'
                      '添加 Key → 服务平台选「Android 平台」→ 填入下面的两项\n'
                      '（要填发布版 SHA1，调试版那个通不过）\n'
                      '⚠️ 这一项改完必须重启 App —— 地图 SDK 只在启动时初始化一次',
                ),
                _identityBlock(),
                const SizedBox(height: 14),
                _keyField(
                  ctrl: _qwKeyCtrl,
                  hint: '和风天气 API Key（可选）',
                  note: '③ 和风天气 API Key —— 可选数据源，'
                      '独有分钟级降水与气象预警\n'
                      '申请：dev.qweather.com（免费订阅 1000 次/天）',
                ),
                const SizedBox(height: 14),
                _keyField(
                  ctrl: _qwHostCtrl,
                  hint: '形如 abcdefg.re.qweatherapi.com',
                  note: '④ 和风天气专属 API Host\n'
                      '2024 改版后旧通用域名已停用，去控制台「设置」页复制；'
                      '留空则自动跳过和风源',
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _saveApiKeys,
                    style: _ghostStyle(),
                    child: const Text('保存并生效'),
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

          // ==================== 问题反馈 ====================
          PanelCard(
            heading: '问题反馈',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '遇到闪退、数据明显不对、地图白屏之类的问题，请按这个顺序发给我：\n'
                  '① 先描述问题（哪个页面、点了什么、期望什么、实际什么）'
                  '　② 配上出问题那一屏的截图　③ 再导出日志一起发。\n'
                  '描述 + 截图 + 日志三样齐全，通常一次就能定位。',
                  style: TextStyle(
                      fontSize: 11.5, color: AppTheme.textDim, height: 1.5),
                ),
                const SizedBox(height: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.green.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: AppTheme.green.withValues(alpha: .35)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_outline, size: 13, color: AppTheme.green),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '导出时会自动抹除所有 API Key，可以放心发送。',
                          style: TextStyle(
                              fontSize: 10.5,
                              color: AppTheme.textDim,
                              height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _exportLogAndShare,
                    icon: const Icon(Icons.upload_file, size: 16),
                    label: const Text('导出日志并分享'),
                    style: _ghostStyle(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _copyLog,
                        icon: const Icon(Icons.copy_all, size: 16),
                        label: const Text('复制全文'),
                        style: _ghostStyle(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _sendFeedbackMail,
                        icon: const Icon(Icons.mail_outline, size: 16),
                        label: const Text('发邮件'),
                        style: _ghostStyle(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '已缓冲 $_logLines 行 · 反馈邮箱 ${AppIdentity.feedbackEmail}',
                  style: const TextStyle(
                      fontSize: 10.5, color: AppTheme.textFaint, height: 1.45),
                ),
                const SizedBox(height: 4),
                const Text(
                  '缓冲上限 2500 行，满了会挤掉最旧的。出问题后建议先别重启 App，'
                  '直接来这里导出 —— 重启会丢掉现场。',
                  style: TextStyle(
                      fontSize: 10.5, color: AppTheme.textFaint, height: 1.45),
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
