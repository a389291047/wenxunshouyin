import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/cloud_printer.dart';

/// v3.3.213 订单补打小票称重商品回归：
/// 症状：零售订单（含称重商品）在订单管理页补打 USB 小票，
/// 商品行全部丢失、合计打成 0.00。
/// 根因（均在 CloudPrinter.orderTicket）：
///   1. goods_list 只认 List 形态，对象 {"0":{...}} 形态 jsonDecode 后 as List 失败
///      被 catch 吞掉 → 商品行为空
///   2. 称重行 quantity 是小数（0.534），int.tryParse 失败按 x1 打
///   3. 合计取 refund_amount ?? total，未退款时 refund_amount=0 顶着 → 合计 0.00
void main() {
  test('goods_list 为对象形态（数字键对象）时不丢商品行', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD001',
      'total': 44,
      'refund_amount': 0,
      'payment_method': '现金',
      'goods_list': {
        '0': {'name': '面包', 'price': 8.8, 'quantity': 2, 'unit': ''},
        '1': {'name': '牛肉', 'price': 18, 'quantity': 0.534, 'unit': 'kg'},
      },
    });
    expect(ticket.contains('面包'), isTrue, reason: '商品行不应丢失');
    expect(ticket.contains('牛肉'), isTrue, reason: '商品行不应丢失');
  });

  test('goods_list 为 JSON 字符串（对象形态）时不丢商品行', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD002',
      'total': 27.61,
      'goods_list': '{"0":{"name":"牛肉","price":18,"quantity":0.534,"unit":"kg"}}',
    });
    expect(ticket.contains('牛肉'), isTrue);
  });

  test('称重行按小数+单位打印，按件行打 xN', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD003',
      'total': 27.61,
      'goods_list': [
        {'name': '牛肉', 'price': 18, 'quantity': 0.534, 'unit': 'kg'},
        {'name': '可乐', 'price': 4, 'quantity': 2, 'unit': ''},
      ],
    });
    expect(ticket.contains('0.534kg'), isTrue, reason: '称重行应打重量带单位');
    expect(ticket.contains('x2'), isTrue, reason: '按件行仍打 xN');
    expect(ticket.contains('¥9.61'), isTrue, reason: '行小计=18×0.534');
  });

  test('普通订单合计取 total（不被 refund_amount=0 顶掉）', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD004',
      'total': 44,
      'refund_amount': 0,
      'goods_list': [
        {'name': '可乐', 'price': 4, 'quantity': 2, 'unit': ''},
      ],
    });
    expect(ticket.contains('合计: ¥44.00'), isTrue, reason: '未退款订单合计应是订单总额');
    expect(ticket.contains('合计: ¥0.00'), isFalse);
  });

  test('退款单合计取 refund_amount', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD005',
      'total': 44,
      'refund_amount': 9.61,
      'goods_list': [],
    }, isRefund: true);
    expect(ticket.contains('退款金额: ¥9.61'), isTrue);
  });

  test('餐饮旧格式（goods_name/num，整数数量）输出不变', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD006',
      'total': 38,
      'goods_list': [
        {'goods_name': '湖南小炒肉', 'unit_price': 38, 'num': 1},
      ],
    });
    expect(ticket.contains('湖南小炒肉'), isTrue);
    expect(ticket.contains('x1'), isTrue);
    expect(ticket.contains('¥38.00'), isTrue);
  });
}
