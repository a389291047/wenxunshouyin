import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/pages/retail/cashier_page.dart';

/// v3.3.210 回归：收款弹窗在竖屏 POS 与小屏收银机上必须完整显示，
/// 「确认收款」按钮不能被切掉（v3.3.209 只修了称重弹窗，收款弹窗漏了）。
void main() {
  Future<void> openAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () => showDialog<dynamic>(
                context: ctx,
                builder: (_) => RetailPayDialog(
                  total: 8.91,
                  methods: const ['现金', '扫码收款', '微信支付', '支付宝'],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // 竖屏收银机 + 常见小屏 + 1366×768 横屏
  for (final s in const [
    Size(600, 1024), // 竖屏
    Size(720, 1280), // 竖屏
    Size(1024, 768),
    Size(1366, 768),
  ]) {
    testWidgets('收款弹窗在 ${s.width.toInt()}×${s.height.toInt()} 不溢出', (tester) async {
      await openAt(tester, s);
      expect(tester.takeException(), isNull);
      // 默认状态：确认收款按钮完整在屏幕内
      final ok = tester.getRect(find.textContaining('确认收款'));
      expect(ok.bottom <= s.height, isTrue, reason: '确认收款按钮超出屏幕底部');
      expect(ok.right <= s.width, isTrue, reason: '确认收款按钮超出屏幕右侧');
      // 4 种支付方式都可见
      expect(find.text('现金'), findsOneWidget);
      expect(find.text('微信支付'), findsOneWidget);
      // 选现金后：数字键盘最后一行 + 清空 也在屏幕内
      await tester.tap(find.text('现金'));
      await tester.pumpAndSettle();
      final clear = tester.getRect(find.text('清空'));
      expect(clear.bottom <= s.height, isTrue, reason: '数字键盘最后一行超出屏幕底部');
      final ok2 = tester.getRect(find.textContaining('确认收款'));
      expect(ok2.bottom <= s.height, isTrue, reason: '选现金后确认收款按钮超出屏幕底部');
    });
  }
}
