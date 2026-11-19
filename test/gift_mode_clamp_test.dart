import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/cart_prefs.dart';

/// 赠送数量钳制（v3.3.237）：含赠送模式下赠送不能顶满数量，防 0 元购
void main() {
  test('称重：数量1kg 赠送555kg → 钳到 0.999kg（留 0.001 收钱）', () {
    expect(GiftMode.clampGift(1, 555, true), 0.999);
  });

  test('称重：数量0.5kg 赠送0.25kg → 合法不动', () {
    expect(GiftMode.clampGift(0.5, 0.25, true), 0.25);
  });

  test('称重：数量1kg 赠送1kg → 钳到 0.999kg（留 0.001 收钱）', () {
    expect(GiftMode.clampGift(1, 1, true), 0.999);
  });

  test('按件：数量3 赠送1 → 合法不动', () {
    expect(GiftMode.clampGift(3, 1, false), 1);
  });

  test('按件：数量1 赠送1 → 0（至少留1件收钱）', () {
    expect(GiftMode.clampGift(1, 1, false), 0);
  });

  test('数量即付钱模式不钳制（赠送额外拿走不影响收钱）', () {
    GiftMode.value.value = GiftMode.keepMode;
    expect(GiftMode.clampGift(1, 555, true), 555);
    expect(GiftMode.giftOverflow(1, 555, true), false);
    GiftMode.value.value = GiftMode.deductMode; // 还原默认
  });

  test('giftOverflow：按件 数量2 赠送2 → 超出', () {
    expect(GiftMode.giftOverflow(2, 2, false), true);
    expect(GiftMode.giftOverflow(2, 1, false), false);
  });
}
