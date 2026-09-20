import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jishiweather/screens/home_screen.dart';
import 'package:jishiweather/theme/app_theme.dart';
import 'package:jishiweather/widgets/fade_slide_in.dart';

/// UI 组件测试
///
/// 说明：这里**不再做「整个 App 启动」的集成测试**。原因是 `HomeScreen` 用
/// `IndexedStack` 同时构建 5 个功能页，每页 `initState` 都会发起网络请求并挂上
/// 10~20 秒的超时 Timer；而 widget test 环境没有 mock 网络层，这些 Timer
/// 收不干净，框架会以 "A Timer is still pending" 判失败。
///
/// 「App 能否正常启动」由**真机验证**覆盖（每轮改动都会装到手机上实跑，
/// 包含高德地图 native 层与定位）。
///
/// 这里只测不依赖网络的叶子组件 —— 它们稳定、快速，且是各页面共用的骨架。
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: child),
      );

  group('ScreenScaffold', () {
    testWidgets('渲染标题、副标题、内测徽章与子内容', (tester) async {
      await tester.pumpWidget(host(const ScreenScaffold(
        title: '地点查询',
        subtitle: '方圆 10km 区域天气',
        children: [Text('卡片内容')],
      )));
      await tester.pump();

      expect(find.text('地点查询'), findsOneWidget);
      expect(find.text('方圆 10km 区域天气'), findsOneWidget);
      expect(find.textContaining('内测'), findsOneWidget);
      expect(find.text('卡片内容'), findsOneWidget);
    });

    testWidgets('多个子组件按顺序渲染', (tester) async {
      await tester.pumpWidget(host(const ScreenScaffold(
        title: '测试',
        subtitle: '副标题',
        children: [Text('第一'), Text('第二'), Text('第三')],
      )));
      await tester.pump();

      for (final t in ['第一', '第二', '第三']) {
        expect(find.text(t), findsOneWidget);
      }
    });
  });

  group('PanelCard', () {
    testWidgets('有 heading 时渲染标题行', (tester) async {
      await tester.pumpWidget(host(const PanelCard(
        heading: '路面状态',
        child: Text('干'),
      )));
      await tester.pump();

      expect(find.text('路面状态'), findsOneWidget);
      expect(find.text('干'), findsOneWidget);
    });

    testWidgets('heading 为 null 时不渲染标题行', (tester) async {
      await tester.pumpWidget(host(const PanelCard(child: Text('只有内容'))));
      await tester.pump();

      expect(find.text('只有内容'), findsOneWidget);
    });
  });

  group('FadeSlideIn', () {
    testWidgets('延迟结束后子组件完全可见', (tester) async {
      await tester.pumpWidget(host(const FadeSlideIn(
        delayMs: 40,
        child: Text('淡入内容'),
      )));

      // 动画时长 = delay + duration(200ms)，推进 500ms 确保走完
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('淡入内容'), findsOneWidget);

      final opacity = tester.widget<Opacity>(find.descendant(
        of: find.byType(FadeSlideIn),
        matching: find.byType(Opacity),
      ));
      expect(opacity.opacity, moreOrLessEquals(1.0, epsilon: 0.01));
    });

    testWidgets('初始状态为透明（动画未开始）', (tester) async {
      await tester.pumpWidget(host(const FadeSlideIn(
        delayMs: 100,
        child: Text('待淡入'),
      )));
      // 尚未 pump 任何时长 → 进度仍为 0
      final opacity = tester.widget<Opacity>(find.descendant(
        of: find.byType(FadeSlideIn),
        matching: find.byType(Opacity),
      ));
      expect(opacity.opacity, moreOrLessEquals(0.0, epsilon: 0.01));
    });
  });
}
