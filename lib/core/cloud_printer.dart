import 'dart:convert';

import '../core/api.dart';
import '../core/session.dart';
import '../core/theme.dart' show Fmt;
import 'usb_printer.dart';

/// 小票打印统一入口：设置了 USB 打印机并启用时走本地 USB 直连，
/// 否则走云打印机（易联云协议，服务端 /shouyin/jiaoban/dayin 代理）。
class CloudPrinter {
  /// 商户启用中的打印机列表
  /// [{id, machine_code, msign, name, status, print_type, is_online, has_paper}]
  static Future<List> list() => Api.printers(Session.wenxunId);

  /// 强制走云打印机（不做 USB 分流，交班单「云打印」按钮等场景用）
  static Future<Map<String, dynamic>> printCloud(String content) async {
    final List all = await list();
    final usable = all.where((p) =>
        '${p['status']}' == '1' &&
        '${p['machine_code']}'.isNotEmpty).toList();
    if (usable.isEmpty) {
      throw ApiError('没有启用中的云打印机，请到「设置 → 云打印」添加');
    }
    // 收银小票优先（print_type=1），其次任意第一台
    final p = usable.firstWhere((x) => '${x['print_type']}' == '1',
        orElse: () => usable.first);
    return Api.cloudPrint(
      wenxunId: Session.wenxunId,
      machineCode: '${p['machine_code']}',
      content: content,
    );
  }

  /// 收银/堂食结账小票（USB 优先，云打印兜底）
  static Future<Map<String, dynamic>> print(String content) async {
    if (await UsbPrinter.tryPrint(content)) return {};
    return printCloud(content);
  }

  /// 后厨小票（USB 优先，云打印兜底）
  static Future<Map<String, dynamic>> printKitchen(String content) async {
    if (await UsbPrinter.tryPrint(content)) return {};
    final List all = await list();
    final usable = all.where((p) =>
        '${p['status']}' == '1' &&
        '${p['machine_code']}'.isNotEmpty).toList();
    if (usable.isEmpty) {
      throw ApiError('没有启用中的云打印机，请到「设置 → 云打印」添加');
    }
    final kitchenTypes = {'2', '3', '4', '5'};
    final p = usable.firstWhere((x) => kitchenTypes.contains('${x['print_type']}'),
        orElse: () => usable.first);
    return Api.cloudPrint(
      wenxunId: Session.wenxunId,
      machineCode: '${p['machine_code']}',
      content: content,
    );
  }

  /// 后厨小票模板（按 菜名+做法备注 聚合同名菜品；仅菜品名+数量，不带价格）
  static String kitchenTicket({
    required String tableTitle,
    required String tableQuyu,
    required List<Map<String, dynamic>> cart,
    String remark = '',
    String title = '后厨单',
    bool isAdd = false,
  }) {
    // 同名同做法合并数量（v3.3.71：做法不同不合并，分行走菜）
    final merged = <String, Map<String, dynamic>>{};
    for (final g in cart) {
      final name = '${g['goods_name'] ?? g['name'] ?? ''}';
      final note = '${g['remark'] ?? ''}'.trim();
      final qty = int.tryParse('${g['quantity']}') ?? 0;
      if (name.isEmpty || qty <= 0) continue;
      final key = '$name|$note';
      if (merged.containsKey(key)) {
        merged[key]!['quantity'] = (merged[key]!['quantity'] as int) + qty;
      } else {
        merged[key] = {'goods_name': name, 'remark': note, 'quantity': qty};
      }
    }
    final sb = StringBuffer();
    sb.writeln('<CB>${isAdd ? '加菜单' : title}</CB>');
    sb.writeln('--------------------------------');
    sb.writeln('桌台: $tableTitle${tableQuyu.isNotEmpty ? ' ($tableQuyu)' : ''}');
    if (remark.isNotEmpty) sb.writeln('备注: $remark');
    sb.writeln('时间: ${DateTime.now().toString().substring(0, 19)}');
    sb.writeln('点单: ${Session.staffName}');
    sb.writeln('--------------------------------');
    var count = 0;
    merged.forEach((_, g) {
      final qty = g['quantity'] as int;
      count += qty;
      sb.writeln('${g['goods_name']}  x$qty');
      final note = '${g['remark'] ?? ''}'.trim();
      if (note.isNotEmpty) sb.writeln('  <<$note>>');
    });
    sb.writeln('--------------------------------');
    sb.writeln('合计件数: $count');
    return sb.toString();
  }

  /// 组零售收银小票
  static String retailReceipt({
    required String orderNo,
    required String payMethod,
    required double total,
    required List<Map<String, dynamic>> cart,
  }) {
    final sb = StringBuffer();
    sb.writeln('<CB>稳讯收银</CB>');
    sb.writeln('--------------------------------');
    sb.writeln('单号: $orderNo');
    sb.writeln('时间: ${DateTime.now().toString().substring(0, 19)}');
    sb.writeln('收银: ${Session.staffName}');
    sb.writeln('--------------------------------');
    for (final g in cart) {
      final name = '${g['name']}';
      sb.writeln('$name');
      sb.writeln('  ¥${Fmt.money(g['price'])} x${g['quantity']}   ¥${Fmt.money((double.tryParse('${g['price']}') ?? 0) * (int.tryParse('${g['quantity']}') ?? 0))}');
    }
    sb.writeln('--------------------------------');
    sb.writeln('合计: ¥${Fmt.money(total)}');
    sb.writeln('支付方式: $payMethod');
    sb.writeln('谢谢惠顾，欢迎下次光临');
    return sb.toString();
  }

  /// 组堂食结账小票
  static String diningReceipt({
    required String orderSn,
    required String tableTitle,
    required int peopleNum,
    required String payMethod,
    required double goodsTotal,
    required double finalTotal,
    required List<Map<String, dynamic>> cart,
    List<String> extraLines = const [], // 费用/优惠/发票/备注明细（v3.3.71）
  }) {
    final sb = StringBuffer();
    sb.writeln('<CB>稳讯收银 · 结账单</CB>');
    sb.writeln('--------------------------------');
    sb.writeln('单号: $orderSn');
    sb.writeln('桌台: $tableTitle   人数: $peopleNum');
    sb.writeln('时间: ${DateTime.now().toString().substring(0, 19)}');
    sb.writeln('收银: ${Session.staffName}');
    sb.writeln('--------------------------------');
    for (final g in cart) {
      final note = '${g['remark'] ?? ''}'.trim();
      sb.writeln('${g['goods_name']}');
      sb.writeln('  ¥${Fmt.money(g['unit_price'])} x${g['quantity']}   ¥${Fmt.money((double.tryParse('${g['unit_price']}') ?? 0) * (int.tryParse('${g['quantity']}') ?? 0))}');
      if (note.isNotEmpty) sb.writeln('  做法: $note');
    }
    sb.writeln('--------------------------------');
    sb.writeln('菜品合计: ¥${Fmt.money(goodsTotal)}');
    for (final line in extraLines) {
      sb.writeln(line);
    }
    sb.writeln('实收: ¥${Fmt.money(finalTotal)}');
    sb.writeln('支付方式: $payMethod');
    sb.writeln('谢谢惠顾，欢迎下次光临');
    return sb.toString();
  }

  /// 交班单
  static String shiftReceipt({
    required double zongyingye,
    required double bishu,
    required double vip,
    required double xianjin,
    required double saoma,
    double refundAmount = 0,
    int refundCount = 0,
  }) {
    final sb = StringBuffer();
    sb.writeln('<CB>交班单</CB>');
    sb.writeln('--------------------------------');
    sb.writeln('收银员: ${Session.staffName}');
    sb.writeln('商户: ${Session.shopName}');
    sb.writeln('日期: ${Session.shiftStart}');
    sb.writeln('--------------------------------');
    sb.writeln('营业总额: ¥${Fmt.money(zongyingye)}');
    sb.writeln('收款笔数: ${bishu.toInt()}');
    sb.writeln('会员支付: ¥${Fmt.money(vip)}');
    sb.writeln('现金收款: ¥${Fmt.money(xianjin)}');
    sb.writeln('扫码收款: ¥${Fmt.money(saoma)}');
    if (refundCount > 0) {
      sb.writeln('退款笔数: $refundCount');
      sb.writeln('退款金额: ¥${Fmt.money(refundAmount)}');
    }
    sb.writeln('--------------------------------');
    sb.writeln('打印时间: ${DateTime.now().toString().substring(0, 19)}');
    return sb.toString();
  }

  /// 订单重打小票（订单管理页 云打印/USB打印 共用）
  static String orderTicket(Map o, {bool isRefund = false}) {
    List goods = [];
    try {
      final raw = o['goods_list'];
      goods = raw is List ? raw : ((jsonDecode('${raw ?? '[]'}') as List?) ?? []);
    } catch (_) {}
    final sb = StringBuffer();
    sb.writeln('<CB>${isRefund ? '退款单' : '订单小票'}</CB>');
    sb.writeln('--------------------------------');
    sb.writeln('商户: ${Session.shopName}');
    sb.writeln('单号: ${o['order_number'] ?? ''}');
    sb.writeln('时间: ${Fmt.date(o['create_time'])}');
    sb.writeln('收银: ${o['cashier_name'] ?? Session.staffName}');
    if (isRefund) {
      sb.writeln('操作: ${Session.staffName}');
      sb.writeln('原因: ${o['refund_reason'] ?? '-'}');
    }
    sb.writeln('--------------------------------');
    for (final g in goods) {
      final name = '${g['title'] ?? g['name'] ?? g['goods_name'] ?? ''}';
      final price = double.tryParse('${g['price'] ?? g['unit_price'] ?? 0}') ?? 0;
      final qty = int.tryParse('${g['quantity'] ?? g['num'] ?? 1}') ?? 1;
      sb.writeln(name);
      sb.writeln('  ¥${Fmt.money(price)} x$qty   ¥${Fmt.money(price * qty)}');
    }
    sb.writeln('--------------------------------');
    sb.writeln('${isRefund ? '退款金额' : '合计'}: ¥${Fmt.money(o['refund_amount'] ?? o['total'])}');
    sb.writeln('支付方式: ${o['payment_method'] ?? '-'}');
    if (isRefund) {
      sb.writeln('退款时间: ${DateTime.now().toString().substring(0, 19)}');
    }
    sb.writeln('谢谢惠顾，欢迎下次光临');
    return sb.toString();
  }

  /// 解析订单 goods_list（零售/会员支付/餐饮混合格式）
  /// 兼容三种存储形态：数组 [{...}]、对象 {"0":{...},"1":{...}}（按数字键排序）、JSON 字符串
  static List<Map<String, dynamic>> parseGoods(Map o) {
    try {
      final raw = o['goods_list'];
      List? l;
      if (raw is List) {
        l = raw;
      } else if (raw is Map) {
        l = _mapValues(raw);
      } else if ('$raw'.isNotEmpty && '$raw' != 'null') {
        final d = jsonDecode('$raw');
        if (d is List) {
          l = d;
        } else if (d is Map) {
          l = _mapValues(d);
        }
      }
      return (l ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// {"2":a,"0":c,"1":b} → [c,b,a]（按数字键升序；无数字键则保持原序）
  static List _mapValues(Map m) {
    final keys = m.keys.toList();
    final allNumeric = keys.every((k) => int.tryParse('$k') != null);
    if (allNumeric) {
      keys.sort((a, b) =>
          (int.tryParse('$a') ?? 0).compareTo(int.tryParse('$b') ?? 0));
    }
    return keys.map((k) => m[k]).toList();
  }
}

// Fmt 统一使用 core/theme.dart 中的定义
