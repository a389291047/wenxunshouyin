import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/cloud_printer.dart';

/// 单行赠送数量（v3.3.232）：赠送不计价，价行打应付数量，赠送行 0 元
void main() {
  test('按件赠送：买5送1 → 价行 x4 + 赠送 x1', () {
    final s = CloudPrinter.retailReceipt(
      orderNo: 'A20261120001',
      payMethod: '现金',
      total: 32,
      cart: [
        {'name': '菠萝包', 'price': 8, 'quantity': 4, 'unit': '', 'gift_qty': 1},
      ],
    );
    expect(s, contains('¥8.00 x4'));
    expect(s, contains('赠送 x1   ¥0.00'));
    expect(s, contains('合计: ¥32.00'));
    expect(s, isNot(contains('x5')));
  });

  test('称重赠送：买0.5kg送0.25kg → 价行 0.25kg + 赠送 0.25kg', () {
    final s = CloudPrinter.retailReceipt(
      orderNo: 'A20261120002',
      payMethod: '扫码支付',
      total: 1.25,
      cart: [
        {'name': '可乐', 'price': 5, 'quantity': 0.25, 'unit': 'kg', 'gift_qty': 0.25},
      ],
    );
    expect(s, contains('¥5.00 0.25kg'));
    expect(s, contains('赠送 0.25kg   ¥0.00'));
    expect(s, contains('合计: ¥1.25'));
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
      'total': 32,
      'goods_list': [
        {'name': '菠萝包', 'price': 8, 'quantity': 4, 'unit': '', 'gift_qty': 1},
      ],
    });
    expect(s, contains('赠送 x1   ¥0.00'));
    expect(s, contains('合计: ¥32.00'));
  });
}
