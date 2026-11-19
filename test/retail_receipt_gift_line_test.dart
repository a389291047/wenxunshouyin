import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/cloud_printer.dart';

/// 购物车单行赠送数量（v3.3.231）：买2送1 / 买0.5kg送0.25kg，随小票打 0 元行
void main() {
  test('按件赠送：本商品 x2 赠送 x1，赠送行 0 元', () {
    final s = CloudPrinter.retailReceipt(
      orderNo: 'A20261120001',
      payMethod: '现金',
      total: 26,
      cart: [
        {'name': '牛肉面', 'price': 13, 'quantity': 2, 'unit': '', 'gift_qty': 1},
      ],
    );
    expect(s, contains('牛肉面'));
    expect(s, contains('¥13.00 x2'));
    expect(s, contains('赠送 x1   ¥0.00'));
    expect(s, contains('合计: ¥26.00'));
  });

  test('称重赠送：买0.5kg送0.25kg，赠送行带单位', () {
    final s = CloudPrinter.retailReceipt(
      orderNo: 'A20261120002',
      payMethod: '扫码支付',
      total: 9,
      cart: [
        {'name': '苹果', 'price': 18, 'quantity': 0.5, 'unit': 'kg', 'gift_qty': 0.25},
      ],
    );
    expect(s, contains('0.5kg'));
    expect(s, contains('赠送 0.25kg   ¥0.00'));
    expect(s, contains('合计: ¥9.00'));
  });

  test('无赠送（gift_qty=0）不打印赠送行', () {
    final s = CloudPrinter.retailReceipt(
      orderNo: 'A20261120003',
      payMethod: '现金',
      total: 13,
      cart: [
        {'name': '牛肉面', 'price': 13, 'quantity': 1, 'unit': '', 'gift_qty': 0},
      ],
    );
    expect(s, isNot(contains('赠送')));
  });

  test('补打小票（orderTicket）也带单行赠送行', () {
    final s = CloudPrinter.orderTicket({
      'order_number': 'A20261120004',
      'create_time': '2026-11-20 10:00:00',
      'total': 26,
      'goods_list': [
        {'name': '牛肉面', 'price': 13, 'quantity': 2, 'unit': '', 'gift_qty': 1},
      ],
    });
    expect(s, contains('赠送 x1   ¥0.00'));
    expect(s, contains('合计: ¥26.00'));
  });
}
