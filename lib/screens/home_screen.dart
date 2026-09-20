import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'location_screen.dart';
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
    return CustomScrollView(
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
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.text,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 内测版标识（0.1.0 内测，禁止外传）
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.accent.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppTheme.accent.withValues(alpha: .55)),
                      ),
                      child: const Text(
                        '0.1.3 内测 · 禁止外传',
                        style: TextStyle(
                            fontSize: 9, color: AppTheme.accent, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.textDim),
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
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: AppTheme.accent,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
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
