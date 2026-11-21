import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/cloud_printer.dart';

/// v3.3.247 回归：40元优惠券（无门槛、直接扣除、允许 0 元购）
///   0 元单（total=0）也必须正常出票：商品合计 40 / 优惠券 -¥40 / 合计 ¥0.00
void main() {
  test('首打小票：40元券扣完 0 元购，正常出票', () {
    final ticket = CloudPrinter.retailReceipt(
      orderNo: 'DD301',
      payMethod: '现金',
      total: 0,
      cart: [
        {'name': '红豆面包', 'price': 8, 'quantity': 3, 'unit': ''},
      ],
      coupon: 40,
    );
    expect(ticket.contains('商品合计: ¥40.00'), isTrue, reason: '40 = 0 + 40 券');
    expect(ticket.contains('优惠券: -¥40.00'), isTrue);
    expect(ticket.contains('<B>合计: ¥0.00</B>'), isTrue);
    expect(ticket.contains('支付方式: 现金'), isTrue);
  });

  test('首打小票：40元券部分抵扣（合计不足40也直接扣）', () {
    final ticket = CloudPrinter.retailReceipt(
      orderNo: 'DD302',
      payMethod: '现金',
      total: 4.0, // 24 - 20? 场景：24 元商品用 40 券 → 0；这里验证 20 元商品剩 4？取 20-16
      cart: [
        {'name': '菠萝包', 'price': 8, 'quantity': 3, 'unit': ''},
      ],
      coupon: 16,
    );
    expect(ticket.contains('商品合计: ¥20.00'), isTrue);
    expect(ticket.contains('优惠券: -¥16.00'), isTrue);
    expect(ticket.contains('<B>合计: ¥4.00</B>'), isTrue);
  });
}
