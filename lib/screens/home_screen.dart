import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';
import 'location_screen.dart';
import 'settings_screen.dart';
import 'photo_screen.dart';
import 'route_screen.dart';
import 'track_screen.dart';
import 'typhoon_screen.dart';

/// 主页：底部导航（试点版先做「地点查询」+「出行路线」两个功能）
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  // 保持页面状态（切 tab 不重建）
  final _pages = const [
    LocationScreen(),
    RouteScreen(),
    TrackScreen(),
    TyphoonScreen(),
    PhotoScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _index, children: _pages),
      ),
      bottomNavigationBar: _BottomNav(
        index: _index,
        onChanged: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onChanged;

  const _BottomNav({required this.index, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF20D121A),
        border: Border(top: BorderSide(color: AppTheme.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              _item(0, '地点查询', Icons.location_on_outlined),
              _item(1, '出行路线', Icons.navigation_outlined),
              _item(2, '赛道研判', Icons.flag_outlined),
              _item(3, '台风研判', Icons.cyclone_outlined),
              _item(4, '摄影指数', Icons.camera_alt_outlined),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(int i, String label, IconData icon) {
    final on = i == index;
    return Expanded(
      child: InkWell(
        onTap: () => onChanged(i),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: on ? AppTheme.accent : AppTheme.textDim),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: on ? AppTheme.accent : AppTheme.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 通用页面外壳：标题 + 内容滚动区
class ScreenScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> children;

  const ScreenScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    // ⚠️ 兜底：显式清掉可能被继承的文本装饰（下划线）。
    // 背景：Text(style:) 是 **merge** 语义 —— style 里没写 decoration 时，
    // 会保留 DefaultTextStyle 中的 decoration。若某一层把默认样式设成了
    // underline，页面上所有「只指定了 fontSize/color 的 Text」都会带上一条
    // 琥珀色下划线（实测在设置页出现过，连标题与副标题都有；而按钮内的文字
    // 因为自带完整 ButtonStyle 反而正常）。
    // 这里统一兜一层，确保任何页面都不会继承到装饰。
    //
    // ⚠️ SafeArea 也是必须的：设置页是 Navigator.push 出来的，外面没有
    // Scaffold，若不处理安全区，顶栏会**和系统状态栏（通知栏）重叠**
    // （用户反馈「顶部和通知栏撞在一起」）。
    return DefaultTextStyle(
      style: const TextStyle(
        decoration: TextDecoration.none,
        color: AppTheme.text,
      ),
      child: SafeArea(
        child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const _Logo(),
                      const SizedBox(width: 9),
                      // 左侧组（标题 + 徽章）：放在 Expanded 里自适应收缩，
                      // 这样长标题会省略号而不是把右侧齿轮挤出屏幕
                      Expanded(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.text,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // 内测版标识（内测，禁止外传）
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.accent.withValues(alpha: .15),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color:
                                          AppTheme.accent.withValues(alpha: .55)),
                                ),
                                child: const Text(
                                  '0.1.7 内测 · 禁止外传',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: AppTheme.accent,
                                    fontWeight: FontWeight.w700,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 设置入口（提醒开关 / 提醒地点 / 公测 API Key）
                      const _SettingsButton(),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.textDim,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            sliver: SliverList(delegate: SliverChildListDelegate(children)),
          ),
        ],
        ),
      ),
    );
  }
}

/// 顶栏右上角的设置入口
///
/// 放在 [ScreenScaffold] 里，所以每个功能页右上角都能进设置，
/// 用户不必先回到某处再找入口。
class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '设置',
      button: true,
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        ),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: AppTheme.bgInset,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderSoft),
          ),
          child: const Icon(Icons.settings_outlined,
              size: 17, color: AppTheme.accent),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) => const AppLogo(size: 28);
}

/// 统一的面板卡片
class PanelCard extends StatelessWidget {
  final String? heading;
  final Widget child;
  final EdgeInsets padding;

  const PanelCard({
    super.key,
    this.heading,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: padding,
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (heading != null) ...[
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: AppTheme.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  heading!,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textDim,
                    letterSpacing: .6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
  }
}
