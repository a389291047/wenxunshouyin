import '../core/api.dart';
import '../core/session.dart';
import '../core/theme.dart' show Fmt;

/// 云打印机（易联云协议，服务端 /shouyin/jiaoban/dayin 代理）
class CloudPrinter {
  /// 商户启用中的打印机列表
  /// [{id, machine_code, msign, name, status, print_type, is_online, has_paper}]
  static Future<List> list() => Api.printers(Session.wenxunId);

  static Future<Map<String, dynamic>> print(String content) async {
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
      sb.writeln('${g['goods_name']}');
      sb.writeln('  ¥${Fmt.money(g['unit_price'])} x${g['quantity']}   ¥${Fmt.money((double.tryParse('${g['unit_price']}') ?? 0) * (int.tryParse('${g['quantity']}') ?? 0))}');
    }
    sb.writeln('--------------------------------');
    sb.writeln('菜品合计: ¥${Fmt.money(goodsTotal)}');
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
    sb.writeln('--------------------------------');
    sb.writeln('打印时间: ${DateTime.now().toString().substring(0, 19)}');
    return sb.toString();
  }
}

// Fmt 统一使用 core/theme.dart 中的定义
