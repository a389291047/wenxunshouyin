import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/ui/touch_keyboard.dart';

/// 触屏键盘（v3.3.221）
/// 顾客在触摸屏收银机上自助输入商品简拼 / 条码，键盘必须：
/// 1) 小窗口下不溢出；2) 字母键、退格、清空、收起回调正确。
void main() {
  Future<Map<String, dynamic>> pump(WidgetTester t, Size size) async {
    final input = <String>[];
    final c = <int>[0, 0, 0]; // 退格 / 清空 / 收起
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: TouchKeyboard(
            keyHeight: size.height < 680 ? 34 : 40,
            hintText: '已输入「pg」· 匹配 3 个商品',
            onInput: input.add,
            onBackspace: () => c[0]++,
            onClear: () => c[1]++,
            onClose: () => c[2]++,
          ),
        ),
      ),
    ));
    return {'input': input, 'c': c};
  }

  testWidgets('1366x768 渲染不溢出，字母键回调小写', (t) async {
    final r = await pump(t, const Size(1366, 768));
    expect(t.takeException(), isNull);
    // 键盘总高应能塞进 768（含顶部提示条）
    final box = t.getSize(find.byType(TouchKeyboard));
    expect(box.height, lessThan(260));

    await t.tap(find.text('Q'));
    await t.tap(find.text('P'));
    await t.tap(find.text('7'));
    expect(r['input'], ['q', 'p', '7']);
  });

  testWidgets('窄小窗口 960x600 不溢出', (t) async {
    await pump(t, const Size(960, 600));
    expect(t.takeException(), isNull);
    final box = t.getSize(find.byType(TouchKeyboard));
    expect(box.height, lessThan(230)); // 紧凑键高
  });

  testWidgets('退格 / 清空 / 收起 回调', (t) async {
    final r = await pump(t, const Size(1366, 768));
    await t.tap(find.text('⌫'));
    await t.tap(find.text('清空'));
    await t.tap(find.text('收起键盘'));
    expect(r['c'], [1, 1, 1]); // 收起由外部隐藏，组件只负责回调
  });

  testWidgets('空格键输入空格', (t) async {
    final r = await pump(t, const Size(1366, 768));
    await t.tap(find.text('空格'));
    expect(r['input'], [' ']);
  });
}
