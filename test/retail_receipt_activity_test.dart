import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/cloud_printer.dart';

/// 零售小票：活动优惠 + 赠品（v3.3.222）
void main() {
  test('小票打印赠品区、活动优惠行与商品合计', () {
    final s = CloudPrinter.retailReceipt(
      orderNo: 'A20261119001',
      payMethod: '现金',
      total: 45, // 实收 = 55 - 满减5 - 券5
      coupon: 5,
      activityDiscount: 5,
      activityLines: ['满50减5 -¥5.00', '赠 可乐 ×1'],
      gifts: [
        {'name': '可乐', 'quantity': 1, 'unit': '', 'byWeight': false},
      ],
      cart: [
        {'name': '苹果', 'price': 10, 'quantity': 5.5, 'unit': 'kg', 'note': ''},
      ],
    );

    expect(s, contains('赠品:'));
    expect(s, contains('可乐（赠品）'));
    expect(s, contains('赠送 x1'));
    expect(s, contains('¥0.00'));
    expect(s, contains('商品合计: ¥55.00'));
    expect(s, contains('满50减5: -¥5.00'));
    expect(s, contains('优惠券: -¥5.00'));
    expect(s, contains('合计: ¥45.00'));
    // 称重行仍按重量打印
    expect(s, contains('5.5kg'));
  });

  test('买1kg送0.5kg：赠品按重量打印', () {
    final s = CloudPrinter.retailReceipt(
      orderNo: 'A2',
      payMethod: '会员支付',
      total: 10,
      gifts: [
        {'name': '苹果', 'quantity': 0.5, 'unit': 'kg', 'byWeight': true},
      ],
      cart: [
        {'name': '苹果', 'price': 10, 'quantity': 1, 'unit': 'kg', 'note': ''},
      ],
    );
    expect(s, contains('苹果（赠品）'));
    expect(s, contains('赠送 0.5kg'));
  });

  test('无活动无赠品：小票格式保持原样', () {
    final s = CloudPrinter.retailReceipt(
      orderNo: 'A3',
      payMethod: '现金',
      total: 20,
      cart: [
        {'name': '矿泉水', 'price': 2, 'quantity': 10, 'unit': '', 'note': ''},
      ],
    );
    expect(s, contains('合计: ¥20.00'));
    expect(s, isNot(contains('赠品')));
    expect(s, isNot(contains('优惠券')));
    expect(s, isNot(contains('商品合计')));
  });
}
