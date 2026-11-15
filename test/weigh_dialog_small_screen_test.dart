import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/ui/weigh_dialog.dart';

/// v3.3.209 回归：1366×768 与 1024×768 收银机上，称重弹窗必须完整显示、
/// 不出现底部溢出（数字键盘和「确认」不能被切掉）。
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
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) => const WeighDialog(title: '红富士苹果', price: 12.5, unit: 'kg'),
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

  for (final s in const [Size(1366, 768), Size(1024, 768), Size(1280, 800)]) {
    testWidgets('称重弹窗在 ${s.width.toInt()}×${s.height.toInt()} 不溢出', (tester) async {
      await openAt(tester, s);
      expect(tester.takeException(), isNull);
      // 数字键盘最后一行与确认键都必须完整落在屏幕内
      final back = tester.getRect(find.byIcon(Icons.backspace_outlined));
      expect(back.bottom <= s.height, isTrue, reason: '数字键盘最后一行超出屏幕底部');
      final ok = tester.getRect(find.textContaining('请输入'));
      expect(ok.bottom <= s.height, isTrue, reason: '确认键超出屏幕底部');
      expect(ok.top >= 0, isTrue);
    });
  }
}
