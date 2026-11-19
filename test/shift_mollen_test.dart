import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxun/core/cloud_printer.dart';

/// v3.3.239 回归：
///   1. 补打小票打「抹零优惠」行（wx_order.quiling，v3.3.239 落库）与「赠送 xN / 重量」0 元行
///   2. 交班单打印当天现金抹零 / 备付金 / 钱箱现金
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('补打小票：仅抹零时打 商品合计/抹零优惠/合计 三行', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD101',
      'total': 7.0,
      'quiling': 0.36, // 现金抹角
      'original_total': 7.36,
      'payment_method': '现金',
      'goods_list': [
        {'name': '蔬菜', 'price': 28, 'quantity': 0.263, 'unit': 'kg'},
      ],
    });
    expect(ticket.contains('商品合计: ¥7.36'), isTrue);
    expect(ticket.contains('抹零优惠: -¥0.36'), isTrue, reason: '抹零应单独成行');
    expect(ticket.contains('合计: ¥7.00'), isTrue);
    // 不应再把抹零混进「优惠」行（「优惠:」行首才算，抹零优惠行不算）
    expect(ticket.split('\n').any((l) => l.startsWith('优惠: ')), isFalse,
        reason: '无活动时不应出现普通「优惠」行');
  });

  test('补打小票：活动优惠 + 抹零分开两行', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD102',
      'total': 8.0,
      'quiling': 0.5,
      'original_total': 10.5, // 商品原价合计
      'payment_method': '现金',
      'goods_list': [
        {'name': '可乐', 'price': 3.5, 'quantity': 3, 'unit': ''},
      ],
    });
    expect(ticket.contains('优惠: -¥2.00'), isTrue, reason: '活动/券部分 = 10.5-8-0.5');
    expect(ticket.contains('抹零优惠: -¥0.50'), isTrue);
    expect(ticket.contains('合计: ¥8.00'), isTrue);
  });

  test('补打小票：单行赠送数量打 0 元赠送行（件数与重量两种口径）', () {
    final ticket = CloudPrinter.orderTicket({
      'order_number': 'DD103',
      'total': 14.0,
      'payment_method': '现金',
      'goods_list': [
        {'name': '可乐', 'price': 7, 'quantity': 2, 'unit': '', 'gift_qty': 1},
        {'name': '牛肉', 'price': 28, 'quantity': 0.5, 'unit': 'kg', 'gift_qty': 0.25},
      ],
    });
    expect(ticket.contains('赠送 x1   ¥0.00'), isTrue, reason: '按件赠送');
    expect(ticket.contains('赠送 0.25kg   ¥0.00'), isTrue, reason: '称重赠送带单位');
  });

  test('交班单：抹零 / 备付金 / 钱箱现金段落', () {
    final ticket = CloudPrinter.shiftReceipt(
      zongyingye: 182.41,
      bishu: 8,
      vip: 0,
      xianjin: 182.41,
      saoma: 0,
      mollenTotal: 1.23,
      mollenCount: 2,
      pettyCash: 200,
      drawerCash: 381.18,
    );
    expect(ticket.contains('现金抹零: -¥1.23 (2 笔)'), isTrue);
    expect(ticket.contains('备付金: ¥200.00'), isTrue);
    expect(ticket.contains('钱箱现金: ¥381.18'), isTrue);
  });

  test('交班单：当天无抹零不打抹零行，备付金/钱箱始终打印', () {
    final ticket = CloudPrinter.shiftReceipt(
      zongyingye: 100,
      bishu: 1,
      vip: 0,
      xianjin: 100,
      saoma: 0,
      pettyCash: 0,
      drawerCash: 100,
    );
    expect(ticket.contains('现金抹零'), isFalse);
    expect(ticket.contains('备付金: ¥0.00'), isTrue);
    expect(ticket.contains('钱箱现金: ¥100.00'), isTrue);
  });

  test('SharedPreferences 备付金 key 按商户隔离（冒烟）', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferences.getInstance();
    final p = await prefs;
    await p.setDouble('shift_petty_cash_546', 300);
    expect(p.getDouble('shift_petty_cash_546'), 300);
    expect(p.getDouble('shift_petty_cash_537'), isNull, reason: '不同商户互不影响');
  });
}
