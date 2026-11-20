import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/cloud_printer.dart';

/// v3.3.246 回归：整单折扣 / 整单改价
///   1. 首打小票打「整单折扣 X折 -¥X」/「整单改价 -¥X」行，商品合计口径包含整单优惠
///   2. 补打小票从 wx_order.whole_discount_rate / whole_discount_amount 反推标签
///   3. 交班单：当天有整单优惠才打，没有不打
void main() {
  test('首打小票：整单折扣行 + 商品合计含整单优惠', () {
    final ticket = CloudPrinter.retailReceipt(
      orderNo: 'DD201',
      payMethod: '现金',
      total: 28.8, // 应收 = 32 - 3.2（8折）
      cart: [
        {'name': '菠萝包', 'price': 8, 'quantity': 4, 'unit': ''},
      ],
      activityDiscount: 0,
      wholeDiscount: 3.2,
      wholeLabel: '整单折扣 8折',
    );
    expect(ticket.contains('商品合计: ¥32.00'), isTrue, reason: '32 = 28.8 + 3.2 + 0 券 + 0 活动 + 0 抹零');
    expect(ticket.contains('整单折扣 8折: -¥3.20'), isTrue);
    expect(ticket.contains('<B>合计: ¥28.80</B>'), isTrue);
  });

  test('首打小票：整单改价行', () {
    final ticket = CloudPrinter.retailReceipt(
      orderNo: 'DD202',
      payMethod: '扫码收款',
      total: 30.0,
      cart: [
        {'name': '水果蛋糕', 'price': 68, 'quantity': 1, 'unit': ''},
      ],
      wholeDiscount: 38.0,
      wholeLabel: '整单改价',
    );
    expect(ticket.contains('商品合计: ¥68.00'), isTrue);
    expect(ticket.contains('整单改价: -¥38.00'), isTrue);
    expect(ticket.contains('<B>合计: ¥30.00</B>'), isTrue);
  });

  test('补打小票：whole_discount_rate=8.5 反推「整单折扣 8.5折」行', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD203',
      'total': 27.2,
      'original_total': 32.0,
      'whole_discount_rate': 8.5,
      'whole_discount_amount': 4.8,
      'payment_method': '现金',
      'goods_list': [
        {'name': '可乐', 'price': 8, 'quantity': 4, 'unit': ''},
      ],
    });
    expect(ticket.contains('商品合计: ¥32.00'), isTrue);
    expect(ticket.contains('整单折扣 8.5折: -¥4.80'), isTrue);
    expect(ticket.contains('合计: ¥27.20'), isTrue);
  });

  test('补打小票：rate=0 且 amount>0 反推「整单改价」行', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD204',
      'total': 30.0,
      'original_total': 68.0,
      'whole_discount_rate': 0,
      'whole_discount_amount': 38.0,
      'payment_method': '现金',
      'goods_list': [
        {'name': '水果蛋糕', 'price': 68, 'quantity': 1, 'unit': ''},
      ],
    });
    expect(ticket.contains('整单改价: -¥38.00'), isTrue);
    expect(ticket.split('\n').any((l) => l.startsWith('整单折扣')), isFalse);
    expect(ticket.contains('合计: ¥30.00'), isTrue);
  });

  test('补打小票：无整单字段时保持老格式，不打整单行', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD205',
      'total': 32.0,
      'original_total': 32.0,
      'payment_method': '现金',
      'goods_list': [
        {'name': '可乐', 'price': 8, 'quantity': 4, 'unit': ''},
      ],
    });
    expect(ticket.contains('整单折扣'), isFalse);
    expect(ticket.contains('整单改价'), isFalse);
    expect(ticket.contains('合计: ¥32.00'), isTrue);
  });

  test('交班单：当天有整单折扣/改价才打印对应行', () {
    final withWhole = CloudPrinter.shiftReceipt(
      zongyingye: 200,
      bishu: 10,
      vip: 0,
      xianjin: 200,
      saoma: 0,
      wholeRateTotal: 9.6,
      wholeRateCount: 2,
      repriceTotal: 38.0,
      repriceCount: 1,
      pettyCash: 0,
      drawerCash: 200,
    );
    expect(withWhole.contains('整单折扣: -¥9.60 (2 笔)'), isTrue);
    expect(withWhole.contains('整单改价: -¥38.00 (1 笔)'), isTrue);

    final withoutWhole = CloudPrinter.shiftReceipt(
      zongyingye: 200,
      bishu: 10,
      vip: 0,
      xianjin: 200,
      saoma: 0,
      pettyCash: 0,
      drawerCash: 200,
    );
    expect(withoutWhole.contains('整单折扣'), isFalse, reason: '当天没有整单优惠不打');
    expect(withoutWhole.contains('整单改价'), isFalse);
  });
}
