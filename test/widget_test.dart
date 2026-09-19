import 'package:flutter_test/flutter_test.dart';

import 'package:jishiweather/main.dart';

void main() {
  testWidgets('应用可启动并显示底部导航', (WidgetTester tester) async {
    await tester.pumpWidget(const JishiWeatherApp());

    // 底部导航两个入口
    expect(find.text('地点查询'), findsWidgets);
    expect(find.text('出行路线'), findsWidgets);
  });
}
