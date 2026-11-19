import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/cloud_printer.dart';

/// 补打小票：活动优惠 + 赠品（v3.3.222，配合后端 1119v4 保存 original_total）
void main() {
  test('补打：商品合计 / 优惠 / 合计，赠品行打「赠送」', () {
    final t = CloudPrinter.orderTicket({
      'order_number': 'A20261119002',
      'total': 45,
      'original_total': 55,
      'payment_method': '现金',
      'create_time': '2026-11-19 20:10:00',
      'goods_list': [
        {'name': '苹果', 'price': 10, 'quantity': 5.5, 'unit': 'kg'},
        {'name': '可乐（赠品）', 'price': 0, 'quantity': 1},
      ],
    });
    expect(t, contains('商品合计: ¥55.00'));
    expect(t, contains('优惠: -¥10.00'));
    expect(t, contains('合计: ¥45.00'));
    expect(t, contains('赠送 x1'));
    expect(t, contains('¥0.00'));
  });

  test('补打：无原价时保持老格式（合计一行）', () {
    final t = CloudPrinter.orderTicket({
      'order_number': 'A3',
      'total': 20,
      'payment_method': '现金',
      'create_time': '2026-11-19 20:10:00',
      'goods_list': [
        {'name': '矿泉水', 'price': 2, 'quantity': 10},
      ],
    });
    expect(t, contains('合计: ¥20.00'));
    expect(t, isNot(contains('商品合计')));
    expect(t, isNot(contains('优惠:')));
  });

  test('退款单不受原价影响', () {
    final t = CloudPrinter.orderTicket({
      'order_number': 'A4',
      'total': 45,
      'original_total': 55,
      'refund_amount': 45,
      'payment_method': '现金',
      'create_time': '2026-11-19 20:10:00',
      'goods_list': [
        {'name': '苹果', 'price': 10, 'quantity': 5.5, 'unit': 'kg'},
      ],
    }, isRefund: true);
    expect(t, contains('退款金额: ¥45.00'));
    expect(t, isNot(contains('商品合计')));
  });
}
