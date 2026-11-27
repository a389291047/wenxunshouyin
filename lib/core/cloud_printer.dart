import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/api.dart';
import '../core/bt_printer.dart';
import '../core/session.dart';
import '../core/theme.dart' show Fmt;
import 'printer_route.dart';
import 'usb_printer.dart';

/// 小票打印统一入口：设置了 USB 打印机并启用时走本地 USB 直连，
/// 否则走云打印机（易联云协议，服务端 /shouyin/jiaoban/dayin 代理）。
class CloudPrinter {
  /// 云打印总开关（设置 → 云打印机；默认开，v3.3.157）
  static const prefEnabled = 'cloud_print_enabled';

  static Future<bool> enabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(prefEnabled) ?? true;
  }

  /// 商户启用中的打印机列表
  /// [{id, machine_code, msign, name, status, is_online, has_paper}]
  static Future<List> list() => Api.printers(Session.wenxunId);

  /// 强制走云打印机（不做 USB 分流，交班单「云打印」按钮等场景用）
  static Future<Map<String, dynamic>> printCloud(String content) async {
    if (!await enabled()) {
      throw ApiError('云打印已关闭（设置 → 云打印机 → 启用云打印）');
    }
    final List all = await list();
    final usable = all.where((p) =>
        '${p['status']}' == '1' &&
        '${p['machine_code']}'.isNotEmpty).toList();
    if (usable.isEmpty) {
      throw ApiError('没有启用中的云打印机，请到「设置 → 云打印」添加');
    }
    // 绑定的前台机优先（v3.3.130 起 print_type 已废弃），其次第一台
    final frontCodes = await PrinterRoute.roleCodes('${Session.wenxunId}', 'front');
    final p = usable.firstWhere((x) => frontCodes.contains('${x['machine_code']}'),
        orElse: () => usable.first);
    return Api.cloudPrint(
      wenxunId: Session.wenxunId,
      machineCode: '${p['machine_code']}',
      content: content,
    );
  }

  /// 收银/堂食结账小票（USB 优先 → 蓝牙 → 云打印兜底）
  /// 「手动打印」模式下直接跳过（本地 + 云打印都不出票），出票只发生在补打/测试等主动操作
  static Future<Map<String, dynamic>> print(String content) async {
    if (await UsbPrinter.isManual()) return {};
    if (await UsbPrinter.tryPrint(content)) return {};
    if (await BtPrinter.tryPrint(content)) return {}; // 蓝牙兜底（v3.3.185）
    if (!await enabled()) return {}; // 云打印开关关闭：不出票
    return printCloud(content);
  }

  /// 零售收银小票（v3.3.214）：本地（USB/蓝牙）出票后，[alsoCloud]=true 时
  /// 云打印机同步出一份（称重订单要求本地 + 云端都见票）；本地未出票时维持
  /// 原兜底行为（云打印开关开着就发云打印机）。云打印失败静默，不影响收银。
  static Future<Map<String, dynamic>> printRetail(String content, {bool alsoCloud = false}) async {
    if (await UsbPrinter.isManual()) return {};
    final local = await UsbPrinter.tryPrint(content) || await BtPrinter.tryPrint(content);
    if (local && !alsoCloud) return {};
    if (!await enabled()) return {};
    try {
      return await printCloud(content);
    } catch (_) {
      return {}; // 云端失败不影响本地已出的票
    }
  }

  /// 手动出票（补打小票等用户主动点击）：不受「手动打印模式」限制
  static Future<Map<String, dynamic>> printManual(String content) async {
    if (await UsbPrinter.tryPrint(content)) return {};
    if (await BtPrinter.tryPrint(content)) return {};
    return printCloud(content);
  }

  /// 后厨小票（USB 优先，云打印兜底）
  static Future<Map<String, dynamic>> printKitchen(String content) async {
    if (await UsbPrinter.isManual()) return {};
    if (!await enabled()) return {};
    final List all = await list();
    final usable = all.where((p) =>
        '${p['status']}' == '1' &&
        '${p['machine_code']}'.isNotEmpty).toList();
    if (usable.isEmpty) {
      throw ApiError('没有启用中的云打印机，请到「设置 → 云打印」添加');
    }
    // 绑定的后厨机优先（v3.3.130 起 print_type 已废弃），其次第一台
    final kitchenCodes = await PrinterRoute.roleCodes('${Session.wenxunId}', 'kitchen');
    final p = usable.firstWhere((x) => kitchenCodes.contains('${x['machine_code']}'),
        orElse: () => usable.first);
    return Api.cloudPrint(
      wenxunId: Session.wenxunId,
      machineCode: '${p['machine_code']}',
      content: content,
    );
  }

  /// 指定云打印机打印（v3.3.82：前台单/后厨分单按商户配置路由）
  /// 云打印开关关闭时静默跳过（v3.3.157）
  static Future<Map<String, dynamic>> printTo(String machineCode, String content) async {
    if (!await enabled()) return {};
    return Api.cloudPrint(
      wenxunId: Session.wenxunId,
      machineCode: machineCode,
      content: content,
    );
  }

  /// 前台单打印（v3.3.82）：指定了前台打印机走指定机，否则自动选收银小票类型
  static Future<Map<String, dynamic>> printFront(String content, {String? machineCode}) async {
    final code = (machineCode == null || machineCode.isEmpty) ? '' : machineCode;
    if (code.isNotEmpty) return printTo(code, content);
    return printCloud(content); // printCloud 内部已按绑定的前台机优先
  }

  /// 预约单模板（v3.3.139）：顾客扫码提交预约后出单备菜核对（默认发前台/收银机）。
  /// items 行字段：goods_name / goods_title、unit_price、quantity、sub_total（preorderList 下发结构）
  static String preorderTicket({
    required String name,
    required String phone,
    required int peopleNum,
    required String arriveTime,
    required String createTime,
    required List<Map<String, dynamic>> items,
    double total = 0,
    String remark = '',
  }) {
    final sb = StringBuffer();
    sb.writeln('<FS2><center>预约单</center></FS2>');
    sb.writeln('--------------------------------');
    if (name.isNotEmpty) sb.writeln('顾客: $name');
    if (phone.isNotEmpty) sb.writeln('手机: $phone');
    if (peopleNum > 0) sb.writeln('人数: $peopleNum 人');
    if (arriveTime.isNotEmpty) sb.writeln('到店: $arriveTime');
    if (createTime.isNotEmpty) sb.writeln('提交: $createTime');
    if (items.isNotEmpty) sb.writeln('--------------------------------');
    var count = 0;
    var sum = 0.0;
    for (final g in items) {
      final title = '${g['goods_name'] ?? g['goods_title'] ?? ''}';
      final qty = int.tryParse('${g['quantity'] ?? 0}') ?? 0;
      final price = double.tryParse('${g['unit_price'] ?? 0}') ?? 0;
      final sub = double.tryParse('${g['sub_total'] ?? 0}') ?? (price * qty);
      if (title.isEmpty || qty <= 0) continue;
      count += qty;
      sum += sub;
      sb.writeln('$title');
      sb.writeln('  ¥${Fmt.money(price)} x$qty   ¥${Fmt.money(sub)}');
    }
    if (items.isNotEmpty) sb.writeln('--------------------------------');
    sb.writeln('共 $count 项  合计: ¥${Fmt.money(total > 0 ? total : sum)}');
    if (remark.isNotEmpty) sb.writeln('备注: $remark');
    sb.writeln('※ 预约单仅供备菜核对 ※');
    sb.writeln('※ 安排开台后请到该桌点「传后厨」出票 ※');
    return sb.toString();
  }

  /// 后厨小票模板（按 菜名+做法备注 聚合同名菜品；仅菜品名+数量，不带价格）
  /// [font] 字体大小（v3.3.126）：''=标准 / 'fs'=加大(中文32高) / 'fs2'=特大(中文48高)，
  /// 只放大菜品行/做法行/合计行；标题本就是 FS2 大字。标签云打印/USB（ESC/POS）通用。
  /// [showTable/showTime/showStaff/showCount] 明细行开关（v3.3.135，商户自定义，
  /// 存云端 cfg.ticket；菜品行/做法行/备注无开关必打）。
  static String kitchenTicket({
    required String tableTitle,
    required String tableQuyu,
    required List<Map<String, dynamic>> cart,
    String remark = '',
    String title = '后厨单',
    bool isAdd = false,
    String font = '',
    bool showTable = true,
    bool showTime = true,
    bool showStaff = true,
    bool showCount = true,
  }) {
    // 同名同做法合并数量（v3.3.71：做法不同不合并，分行走菜）
    final merged = <String, Map<String, dynamic>>{};
    for (final g in cart) {
      final name = '${g['goods_name'] ?? g['goods_title'] ?? g['name'] ?? ''}';
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
    String f(String line) => font.isEmpty ? line : '<${font.toUpperCase()}>$line</${font.toUpperCase()}>';
    final sb = StringBuffer();
    sb.writeln('<FS2><center>${isAdd ? '加菜单' : title}</center></FS2>');
    sb.writeln('--------------------------------');
    if (showTable) sb.writeln('桌台: $tableTitle${tableQuyu.isNotEmpty ? ' ($tableQuyu)' : ''}');
    if (remark.isNotEmpty) sb.writeln('备注: $remark');
    if (showTime) sb.writeln('时间: ${DateTime.now().toString().substring(0, 19)}');
    if (showStaff) sb.writeln('点单: ${Session.staffName}');
    sb.writeln('--------------------------------');
    var count = 0;
    merged.forEach((_, g) {
      final qty = g['quantity'] as int;
      count += qty;
      sb.writeln(f('${g['goods_name']}  x$qty'));
      final note = '${g['remark'] ?? ''}'.trim();
      if (note.isNotEmpty) sb.writeln(f('  <<$note>>'));
    });
    sb.writeln('--------------------------------');
    if (showCount) sb.writeln(f('合计件数: $count'));
    return sb.toString();
  }

  /// 预结单模板（v3.3.82）：先出单给顾客核对，非正式结算凭证
  /// [font] 前台机字体（v3.3.127）：''=标准 / 'fs'=加大 / 'fs2'=特大，放大菜名与合计行
  static String prebillTicket({
    required String tableTitle,
    required int peopleNum,
    required double goodsTotal,
    required List<Map<String, dynamic>> cart,
    List<String> extraLines = const [],
    String font = '',
  }) {
    String f(String line) => font.isEmpty ? line : '<${font.toUpperCase()}>$line</${font.toUpperCase()}>';
    final sb = StringBuffer();
    sb.writeln('<FS2><center>预结单</center></FS2>');
    sb.writeln('--------------------------------');
    sb.writeln('桌台: $tableTitle   人数: $peopleNum');
    sb.writeln('时间: ${DateTime.now().toString().substring(0, 19)}');
    sb.writeln('收银: ${Session.staffName}');
    sb.writeln('--------------------------------');
    var count = 0;
    for (final g in cart) {
      final note = '${g['remark'] ?? ''}'.trim();
      final qty = int.tryParse('${g['quantity']}') ?? 0;
      count += qty;
      sb.writeln(f('${g['goods_name']}'));
      sb.writeln('  ¥${Fmt.money(g['unit_price'])} x$qty   ¥${Fmt.money((double.tryParse('${g['unit_price']}') ?? 0) * qty)}');
      if (note.isNotEmpty) sb.writeln('  做法: $note');
    }
    sb.writeln('--------------------------------');
    sb.writeln(f('共 $count 项  菜品合计: ¥${Fmt.money(goodsTotal)}'));
    for (final line in extraLines) {
      sb.writeln(line);
    }
    sb.writeln('※ 预结单仅供核对，非结算凭证 ※');
    return sb.toString();
  }

  /// 订单补打小票（v3.3.87）：USB 直连优先，云打印按绑定的前台机优先（无绑定取第一台）
  /// 补打是收银员主动操作，不受「手动打印模式」限制（v3.3.156）
  static Future<Map<String, dynamic>> printReorder(String content) => printManual(content);

  /// 堂食订单补打小票模板（v3.3.87）：从订单行重组结账单，含附加费/优惠明细
  /// v3.3.281：标题统一「结账单」；printNo 传重打次序时小票加「第N次打印」行
  static String diningReprintTicket(Map o, {int? printNo}) {
    final cart = parseGoods(o).map((g) => {
          'goods_name': '${g['goods_title'] ?? g['goods_name'] ?? g['title'] ?? g['name'] ?? ''}',
          'unit_price': double.tryParse('${g['unit_price'] ?? g['price'] ?? 0}') ?? 0,
          'quantity': int.tryParse('${g['quantity'] ?? g['num'] ?? 1}') ?? 1,
          'remark': '${g['remark'] ?? ''}',
        }).toList();
    double f(String k) => double.tryParse('${o[k] ?? 0}') ?? 0;
    final extra = <String>[];
    if (f('kaitai_fee') > 0) extra.add('开台费: ¥${Fmt.money(f('kaitai_fee'))}');
    if (f('tea_fee') > 0) extra.add('茶位费: ¥${Fmt.money(f('tea_fee'))}');
    if (f('service_fee') > 0) extra.add('服务费: ¥${Fmt.money(f('service_fee'))}');
    if (f('box_fee') > 0) extra.add('餐盒费: ¥${Fmt.money(f('box_fee'))}');
    if (f('discount_amount') > 0) extra.add('整单优惠: -¥${Fmt.money(f('discount_amount'))}');
    if (f('vip_reduce') > 0) extra.add('会员优惠: -¥${Fmt.money(f('vip_reduce'))}');
    if (f('manual_prefer') > 0) extra.add('手动优惠: -¥${Fmt.money(f('manual_prefer'))}');
    if (f('quiling') > 0) extra.add('抹零: -¥${Fmt.money(f('quiling'))}');
    if ((int.tryParse('${o['jifen_num'] ?? 0}') ?? 0) > 0) {
      extra.add('积分抵扣: ${o['jifen_num']}分 (-¥${Fmt.money(f('jifen_deduct'))})');
    }
    if (f('refund_total') > 0) extra.add('累计退款: -¥${Fmt.money(f('refund_total'))}');
    final remark = '${o['order_remark'] ?? ''}';
    if (remark.isNotEmpty) extra.add('整单备注: $remark');
    final invoice = '${o['invoice_title'] ?? ''}';
    if (invoice.isNotEmpty) extra.add('发票: $invoice');
    // 挂账人信息（v3.3.156：后端 getList/detail 返回）
    final gzName = '${o['guazhang_name'] ?? ''}'.trim();
    final gzPhone = '${o['guazhang_phone'] ?? ''}'.trim();
    if (gzName.isNotEmpty) {
      extra.add('挂账人: $gzName${gzPhone.isNotEmpty ? '　电话: $gzPhone' : ''}');
    }
    final pays = ['${o['pay1_type'] ?? ''}', '${o['pay2_type'] ?? ''}', '${o['pay3_type'] ?? ''}']
        .where((p) => p.isNotEmpty && p != 'null')
        .toList();
    return diningReceipt(
      orderSn: '${o['order_sn'] ?? ''}',
      tableTitle: '${o['table_title'] ?? ''}',
      peopleNum: int.tryParse('${o['people_num'] ?? 1}') ?? 1,
      payMethod: pays.isEmpty ? '其他' : pays.join(' / '),
      goodsTotal: f('goods_total'),
      finalTotal: f('final_total'),
      cart: cart,
      extraLines: [
        '补打时间: ${DateTime.now().toString().substring(0, 19)}',
        if (printNo != null) '第$printNo次打印', // 原单=第1次，重打从第2次起（v3.3.281）
        ...extra,
      ],
      title: '结账单', // v3.3.281：重打不再显示「补打小票」，统一「结账单」+ 第N次打印
    );
  }

  /// 重打次数计数（v3.3.281，本地按单号累计）：返回本次是第几次打印（原单算第 1 次）
  static Future<int> bumpReprintCount(String orderSn) async {
    final sp = await SharedPreferences.getInstance();
    if (orderSn.isEmpty) return 2;
    final k = 'reprint_cnt_$orderSn';
    final n = (sp.getInt(k) ?? 1) + 1;
    await sp.setInt(k, n);
    return n;
  }

  /// 小票标题店铺名：登录商户名，未取到回退「稳讯收银」（v3.3.156）
  static String get shopTitle {
    final n = Session.shopName.trim();
    return n.isEmpty ? '稳讯收银' : n;
  }

  /// 组零售收银小票
  /// 数量文本：整数原样，小数去尾零（0.525 / 1.2 / 2）
  static String _qtyStr(double q) {
    if (q == q.roundToDouble()) return '${q.round()}';
    var s = q.toStringAsFixed(3);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return s;
  }

  static String retailReceipt({
    required String orderNo,
    required String payMethod,
    required double total, // 应收合计（活动优惠 + 优惠券抵扣后）
    required List<Map<String, dynamic>> cart,
    double coupon = 0, // 优惠券抵扣金额（v3.3.219，>0 时小票打优惠券行）
    double activityDiscount = 0, // 活动优惠金额（满减/折扣，v3.3.222）
    double mollen = 0, // 现金抹零金额（v3.3.238，>0 时打「抹零优惠」行）
    double wholeDiscount = 0, // 整单优惠总额（折扣优惠额或改价差额，v3.3.246）
    String wholeLabel = '', // 整单优惠标签（「整单折扣 8.5折」/「整单改价」，v3.3.246）
    List<String> activityLines = const [], // 活动说明（含赠品），首条为金额活动
    List<Map<String, dynamic>> gifts = const [], // 赠品行（0 元，v3.3.222）
    String vipName = '', // 会员昵称（v3.3.249，选中会员时打「会员」行）
    String vipPhone = '', // 会员手机号
    double? vipBalance, // 会员支付后剩余金额（v3.3.249，仅会员支付传，后端 balance）
  }) {
    final sb = StringBuffer();
    sb.writeln('<FS2><center>$shopTitle</center></FS2>');
    sb.writeln('--------------------------------');
    sb.writeln('单号: $orderNo');
    sb.writeln('时间: ${DateTime.now().toString().substring(0, 19)}');
    sb.writeln('收银: ${Session.staffName}');
    sb.writeln('--------------------------------');
    for (final g in cart) {
      final name = '${g['name']}';
      final price = double.tryParse('${g['price']}') ?? 0;
      final qty = double.tryParse('${g['quantity']}') ?? 0;
      final unit = '${g['unit'] ?? ''}'.trim();
      final sub = price * qty;
      // 称重行：0.525kg × 18.00；按件行：x2
      final qtyTxt = unit.isNotEmpty ? '${_qtyStr(qty)}$unit' : 'x${qty.round()}';
      sb.writeln('$name');
      sb.writeln('  ¥${Fmt.money(price)} $qtyTxt   ¥${Fmt.money(sub)}');
      // 单行赠送数量（v3.3.231）：买2送1 / 买0.5kg送0.25kg，0 元行
      final gift = double.tryParse('${g['gift_qty'] ?? 0}') ?? 0;
      if (gift > 0) {
        final giftTxt = unit.isNotEmpty ? '${_qtyStr(gift)}$unit' : 'x${gift.round()}';
        sb.writeln('  赠送 $giftTxt   ¥0.00');
      }
    }
    // 赠品区（v3.3.222）：买一送一 / 买1kg送0.5kg / 满赠，0 元行，明确标「赠品」
    if (gifts.isNotEmpty) {
      sb.writeln('--------------------------------');
      sb.writeln('赠品:');
      for (final g in gifts) {
        final name = '${g['name']}';
        final qty = double.tryParse('${g['quantity']}') ?? 0;
        final unit = '${g['unit'] ?? ''}'.trim();
        final qtyTxt = unit.isNotEmpty ? '${_qtyStr(qty)}$unit' : 'x${qty.round()}';
        sb.writeln('$name（赠品）');
        sb.writeln('  赠送 $qtyTxt   ¥0.00');
      }
    }
    sb.writeln('--------------------------------');
    final hasCut = coupon > 0 || activityDiscount > 0 || mollen > 0 || wholeDiscount > 0;
    if (hasCut) {
      // 商品合计 → 活动优惠 → 整单折扣/改价 → 优惠券 → 抹零 → 实收合计
      sb.writeln('商品合计: ¥${Fmt.money(total + coupon + activityDiscount + wholeDiscount + mollen)}');
      if (activityDiscount > 0) {
        final label = activityLines.isNotEmpty
            ? activityLines.first.split(' -¥').first
            : '活动优惠';
        sb.writeln('$label: -¥${Fmt.money(activityDiscount)}');
      }
      if (wholeDiscount > 0 && wholeLabel.isNotEmpty) {
        sb.writeln('$wholeLabel: -¥${Fmt.money(wholeDiscount)}');
      }
      if (coupon > 0) sb.writeln('优惠券: -¥${Fmt.money(coupon)}');
      if (mollen > 0) sb.writeln('抹零优惠: -¥${Fmt.money(mollen)}');
      sb.writeln('<B>合计: ¥${Fmt.money(total)}</B>');
    } else {
      sb.writeln('合计: ¥${Fmt.money(total)}');
    }
    sb.writeln('支付方式: $payMethod');
    // 会员信息（v3.3.249）：昵称 + 手机号；会员支付时再打扣款后剩余金额
    final vName = vipName.trim();
    final vPhone = vipPhone.trim();
    if (vName.isNotEmpty || vPhone.isNotEmpty) {
      sb.writeln('会员: ${vName.isEmpty ? vPhone : vName}${(vName.isNotEmpty && vPhone.isNotEmpty) ? ' ($vPhone)' : ''}');
    }
    if (vipBalance != null) sb.writeln('卡内余额: ¥${Fmt.money(vipBalance)}');
    sb.writeln('谢谢惠顾，欢迎下次光临');
    return sb.toString();
  }

  /// 组会员充值小票 / 退款充值小票（v3.3.174）
  /// [refund]=false 充值小票（充值成功自动打）；true 退款充值小票（退款成功自动打）
  static String vipRechargeTicket({
    required String vipName,
    required String phone,
    required String orderSn,
    required double amount, // 本金
    required double gift, // 赠送
    required String payMethod, // 现金 / 扫码支付
    double? balance, // 充值/退款后余额（后端返回）
    bool refund = false,
    String reason = '',
  }) {
    final sb = StringBuffer();
    sb.writeln('<FS2><center>$shopTitle</center></FS2>');
    sb.writeln('<FS2><center>${refund ? '退款充值小票' : '充值小票'}</center></FS2>');
    sb.writeln('--------------------------------');
    sb.writeln('${refund ? '退回' : '充值'}单号: $orderSn');
    sb.writeln('会员: $vipName${phone.isNotEmpty ? '  ($phone)' : ''}');
    sb.writeln('时间: ${DateTime.now().toString().substring(0, 19)}');
    sb.writeln('收银: ${Session.staffName}');
    sb.writeln('--------------------------------');
    if (refund) {
      sb.writeln('退回金额: ¥${Fmt.money(amount)}');
      if (gift > 0) sb.writeln('扣除赠送: ¥${Fmt.money(gift)}');
      if (reason.isNotEmpty) sb.writeln('原因: $reason');
    } else {
      sb.writeln('充值金额: ¥${Fmt.money(amount)}');
      if (gift > 0) sb.writeln('赠送金额: ¥${Fmt.money(gift)}');
    }
    sb.writeln('${refund ? '退款' : '支付'}方式: $payMethod');
    if (balance != null) sb.writeln('当前余额: ¥${Fmt.money(balance)}');
    sb.writeln('--------------------------------');
    sb.writeln(refund ? '退款已受理，感谢您的理解' : '充值到账，谢谢惠顾');
    return sb.toString();
  }

  /// 组挂账消费单小票（v3.3.275）：挂账结算时打印，商户留存联（可带签字栏）+ 可选客户联
  /// copy='shop' 商户留存联（签字栏按 opts）/ copy='customer' 客户联（不带签字栏）
  static String guazhangTicket({
    required String orderSn,
    required String tableTitle,
    required int peopleNum,
    required String gzName,
    String gzPhone = '',
    String gzUnit = '',
    required double goodsTotal,
    required double finalTotal,
    required List<Map<String, dynamic>> cart,
    List<String> extraLines = const [],
    double balance = 0, // 该挂账人当前累计未结清余额（含本单）
    Map<String, bool> opts = const {}, // signature/upper/balance/qr
    String copy = 'shop',
  }) {
    final sb = StringBuffer();
    final shopCopy = copy == 'shop';
    sb.writeln('<FS2><center>$shopTitle</center></FS2>');
    sb.writeln('门店编号: ${Session.wenxunId}${Session.shopPhone.trim().isNotEmpty ? '   电话: ${Session.shopPhone.trim()}' : ''}');
    sb.writeln('<FS2><center>【挂账消费单】</center></FS2>');
    sb.writeln('<center>${shopCopy ? '—— 商户留存联 ——' : '—— 客户留存联 ——'}</center>');
    sb.writeln('--------------------------------');
    sb.writeln('单号: $orderSn');
    if (tableTitle.isNotEmpty) sb.writeln('桌台: $tableTitle   人数: $peopleNum');
    sb.writeln('时间: ${DateTime.now().toString().substring(0, 19)}');
    sb.writeln('收银: ${Session.staffName}');
    sb.writeln('--------------------------------');
    sb.writeln('挂账人: $gzName');
    if (gzPhone.isNotEmpty) sb.writeln('电话: $gzPhone');
    if (gzUnit.isNotEmpty) sb.writeln('单位: $gzUnit');
    sb.writeln('--------------------------------');
    for (final g in cart) {
      final note = '${g['remark'] ?? ''}'.trim();
      final name = '${g['goods_name'] ?? g['goods_title'] ?? ''}';
      sb.writeln('$name');
      sb.writeln('  ¥${Fmt.money(g['unit_price'])} x${g['quantity']}   ¥${Fmt.money((double.tryParse('${g['unit_price']}') ?? 0) * (double.tryParse('${g['quantity']}') ?? 1))}');
      if (note.isNotEmpty) sb.writeln('  做法: $note');
    }
    sb.writeln('--------------------------------');
    sb.writeln('商品合计: ¥${Fmt.money(goodsTotal)}');
    for (final line in extraLines) {
      sb.writeln(line);
    }
    sb.writeln('<FS>本次挂账: ¥${Fmt.money(finalTotal)}</FS>');
    if (opts['upper'] == true) sb.writeln('大写: ${rmbUpper(finalTotal)}');
    if (opts['balance'] == true && balance > 0) {
      sb.writeln('该账户累计未结: ¥${Fmt.money(balance)}');
    }
    sb.writeln('支付方式: 挂账（未付款）');
    sb.writeln('--------------------------------');
    sb.writeln('备注: 本单据为挂账消费凭证，顾客确认');
    sb.writeln('上述商品及欠款金额无误，承诺按期');
    sb.writeln('结清款项。消费未付款。');
    if (shopCopy && opts['signature'] == true) {
      sb.writeln('--------------------------------');
      sb.writeln('欠款人签字: ______________');
      sb.writeln('');
      sb.writeln('签字日期: ____年__月__日');
      sb.writeln('');
      sb.writeln('收银员签字: ______________');
    }
    sb.writeln('--------------------------------');
    if (opts['qr'] == true && orderSn.isNotEmpty) sb.writeln('<QR>$orderSn</QR>');
    sb.writeln('打印时间: ${DateTime.now().toString().substring(0, 19)}');
    return sb.toString();
  }

  /// 组挂账结清单小票（v3.3.275）：核销收款后打印，注明原单号/还款金额/剩余未结
  static String guazhangSettleTicket({
    required String orderSn,
    required String gzName,
    String gzPhone = '',
    required double amount,
    required String payMethod,
    double remainUnsettled = 0,
    Map<String, bool> opts = const {},
  }) {
    final sb = StringBuffer();
    sb.writeln('<FS2><center>$shopTitle</center></FS2>');
    sb.writeln('<FS2><center>【挂账结清单】</center></FS2>');
    sb.writeln('<center>—— 原欠款已结清 ——</center>');
    sb.writeln('--------------------------------');
    sb.writeln('原挂账单号: $orderSn');
    sb.writeln('结清时间: ${DateTime.now().toString().substring(0, 19)}');
    sb.writeln('收银: ${Session.staffName}');
    sb.writeln('--------------------------------');
    sb.writeln('挂账人: $gzName');
    if (gzPhone.isNotEmpty) sb.writeln('电话: $gzPhone');
    sb.writeln('--------------------------------');
    sb.writeln('<FS>本次结清: ¥${Fmt.money(amount)}</FS>');
    if (opts['upper'] == true) sb.writeln('大写: ${rmbUpper(amount)}');
    sb.writeln('支付方式: $payMethod');
    if (remainUnsettled > 0) sb.writeln('该账户剩余未结: ¥${Fmt.money(remainUnsettled)}');
    sb.writeln('--------------------------------');
    sb.writeln('上述挂账欠款已全部结清，特此为凭。');
    sb.writeln('--------------------------------');
    sb.writeln('打印时间: ${DateTime.now().toString().substring(0, 19)}');
    return sb.toString();
  }

  /// 人民币大写（v3.3.275）：268 → 人民币贰佰陆拾捌元整；0.53 → 人民币伍角叁分
  static const _rmbDigits = ['零', '壹', '贰', '叁', '肆', '伍', '陆', '柒', '捌', '玖'];
  static const _rmbUnits = ['', '拾', '佰', '仟'];
  static const _rmbGroups = ['', '万', '亿'];

  /// 4 位组内部转大写（组内压零：1005→壹仟零伍，1050→壹仟零伍拾，1100→壹仟壹佰）
  static String _rmbFour(int g) {
    var s = '', zero = false, started = false, u = 0, x = g;
    while (x > 0) {
      final d = x % 10;
      if (d == 0) {
        if (started) zero = true;
      } else {
        if (zero) { s = '${_rmbDigits[0]}$s'; zero = false; }
        s = '${_rmbDigits[d]}${_rmbUnits[u]}$s';
        started = true;
      }
      x ~/= 10;
      u++;
    }
    return s;
  }

  static String rmbUpper(double v) {
    var n = ((v.abs() * 100).round()); // 转成分，避免浮点误差
    final neg = v < 0;
    if (n == 0) return '人民币零元整';
    final fen = n % 10;
    n ~/= 10;
    final jiao = n % 10;
    n ~/= 10;
    // 整数部分：按 4 位分组，从高位向低位拼
    final groups = <int>[];
    while (n > 0) {
      groups.add(n % 10000);
      n ~/= 10000;
    }
    var yuan = '';
    var needZero = false; // 上方组整组为零时需要补零
    for (int gi = groups.length - 1; gi >= 0; gi--) {
      final g = groups[gi];
      if (g == 0) {
        if (yuan.isNotEmpty) needZero = true;
        continue;
      }
      var gs = _rmbFour(g);
      if (yuan.isNotEmpty && (needZero || g < 1000)) gs = '零$gs';
      yuan += gs + _rmbGroups[gi];
      needZero = false;
    }
    if (yuan.isNotEmpty) yuan = '$yuan元';
    // 小数部分
    var dec = '';
    if (jiao > 0) dec = '${_rmbDigits[jiao]}角';
    if (fen > 0) {
      if (jiao == 0 && yuan.isNotEmpty) dec += '${_rmbDigits[0]}';
      dec += '${_rmbDigits[fen]}分';
    }
    if (yuan.isEmpty && dec.isEmpty) return '人民币零元整';
    final tail = (jiao == 0 && fen == 0 && yuan.isNotEmpty) ? '整' : '';
    return '人民币${neg ? '负' : ''}$yuan$dec$tail';
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
    String title = '结账单', // 补打时传「补打小票」区分（v3.3.236）
  }) {
    final sb = StringBuffer();
    // 店铺名一行居中，标题单独一行居中（v3.3.156）
    sb.writeln('<FS2><center>$shopTitle</center></FS2>');
    sb.writeln('<FS2><center>$title</center></FS2>');
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
    // 挂账统计（v3.3.157）：未核销 = 待收挂账；已核销 = 今日核销收款
    double gzUnsettled = 0,
    int gzUnsettledCount = 0,
    double gzSettled = 0,
    int gzSettledCount = 0,
    // 今日充值统计（v3.3.173）：有充值才打印充值段
    int czCount = 0,
    double czCash = 0,
    double czScan = 0,
    // 当天现金抹零 / 钱箱（v3.3.239）
    double mollenTotal = 0,
    int mollenCount = 0,
    // 当天整单折扣 / 整单改价（v3.3.246）：当天没有就不打印
    double wholeRateTotal = 0,
    int wholeRateCount = 0,
    double repriceTotal = 0,
    int repriceCount = 0,
    double pettyCash = 0,
    double drawerCash = 0,
  }) {
    final sb = StringBuffer();
    sb.writeln('<FS2><center>交班单</center></FS2>');
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
    if (mollenTotal > 0) {
      sb.writeln('现金抹零: -¥${Fmt.money(mollenTotal)} ($mollenCount 笔)');
    }
    // 整单折扣 / 整单改价（v3.3.246）：当天有才打印
    if (wholeRateCount > 0) {
      sb.writeln('整单折扣: -¥${Fmt.money(wholeRateTotal)} ($wholeRateCount 笔)');
    }
    if (repriceCount > 0) {
      sb.writeln('整单改价: -¥${Fmt.money(repriceTotal)} ($repriceCount 笔)');
    }
    if (refundCount > 0) {
      sb.writeln('退款笔数: $refundCount');
      sb.writeln('退款金额: ¥${Fmt.money(refundAmount)}');
    }
    if (gzUnsettledCount > 0 || gzSettledCount > 0) {
      sb.writeln('--------------------------------');
      sb.writeln('挂账未核销: ¥${Fmt.money(gzUnsettled)} ($gzUnsettledCount 笔)');
      sb.writeln('今日已核销: ¥${Fmt.money(gzSettled)} ($gzSettledCount 笔)');
    }
    // 会员充值（v3.3.173）：当天没有充值就不打印这段
    if (czCount > 0) {
      sb.writeln('--------------------------------');
      sb.writeln('会员充值: $czCount 笔');
      sb.writeln('现金充值: ¥${Fmt.money(czCash)}');
      sb.writeln('扫码充值: ¥${Fmt.money(czScan)}');
    }
    // 钱箱（v3.3.239）：备付金可改，钱箱现金 = 备付金 + 现金收款 - 现金退款
    sb.writeln('--------------------------------');
    sb.writeln('备付金: ¥${Fmt.money(pettyCash)}');
    sb.writeln('钱箱现金: ¥${Fmt.money(drawerCash)}');
    sb.writeln('--------------------------------');
    sb.writeln('打印时间: ${DateTime.now().toString().substring(0, 19)}');
    return sb.toString();
  }

  /// 订单重打小票（订单管理页 云打印/USB打印 共用）
  /// v3.3.213 修复称重商品打印：
  ///   1. 商品明细统一走 parseGoods（兼容数组/对象/JSON字符串三种存储形态），
  ///      旧代码只认 List 形态，解析失败被 catch 吞掉 → 整张小票无商品行
  ///   2. 称重行 quantity 是小数（0.534），旧代码 int.tryParse 失败按 x1 打；
  ///      现按小数打印并带单位（0.534kg），按件行仍打 xN
  ///   3. 合计旧代码取 refund_amount ?? total，未退款时 refund_amount=0 顶着 → 合计 0.00；
  ///      现仅退款单取 refund_amount，普通单固定取 total
  static String orderTicket(Map o, {bool isRefund = false}) {
    final goods = parseGoods(o);
    final sb = StringBuffer();
    sb.writeln('<FS2><center>${isRefund ? '退款单' : '补打小票'}</center></FS2>');
    sb.writeln('--------------------------------');
    sb.writeln('商户: ${Session.shopName}');
    sb.writeln('单号: ${o['order_number'] ?? ''}');
    sb.writeln('时间: ${Fmt.date(o['create_time'])}');
    sb.writeln('收银: ${o['cashier_name'] ?? Session.staffName}');
    // 会员信息（v3.3.249）：vip_name 为后端列表接口回填的会员昵称；phone 会员支付单落库
    final rkVipName = '${o['vip_name'] ?? ''}'.trim();
    final rkVipPhone = '${o['phone'] ?? ''}'.trim();
    if (rkVipName.isNotEmpty || rkVipPhone.isNotEmpty) {
      sb.writeln('会员: ${rkVipName.isEmpty ? rkVipPhone : rkVipName}${(rkVipName.isNotEmpty && rkVipPhone.isNotEmpty) ? ' ($rkVipPhone)' : ''}');
    }
    if (!isRefund) sb.writeln('补打时间: ${DateTime.now().toString().substring(0, 19)}');
    if (isRefund) {
      sb.writeln('操作: ${Session.staffName}');
      sb.writeln('原因: ${o['refund_reason'] ?? '-'}');
    }
    sb.writeln('--------------------------------');
    for (final g in goods) {
      final name = '${g['title'] ?? g['name'] ?? g['goods_name'] ?? ''}';
      final price = double.tryParse('${g['price'] ?? g['unit_price'] ?? 0}') ?? 0;
      final unit = '${g['unit'] ?? ''}'.trim();
      final qty = double.tryParse('${g['quantity'] ?? g['num'] ?? 1}') ?? 1;
      // 称重行：0.534kg × 18.00（与零售收银小票口径一致）；按件行：xN
      final qtyTxt = unit.isNotEmpty ? '${_qtyStr(qty)}$unit' : 'x${qty.round()}';
      sb.writeln(name);
      // 赠品行（v3.3.222）：订单明细里存的是「商品名（赠品）」0 元行
      final isGift = name.contains('（赠品）') || (price == 0 && '${g['note'] ?? ''}'.contains('赠品'));
      if (isGift) {
        sb.writeln('  赠送 $qtyTxt   ¥0.00');
      } else {
        sb.writeln('  ¥${Fmt.money(price)} $qtyTxt   ¥${Fmt.money(price * qty)}');
        // 单行赠送数量（v3.3.231）：买2送1 / 买0.5kg送0.25kg，0 元行
        final gift = double.tryParse('${g['gift_qty'] ?? 0}') ?? 0;
        if (gift > 0) {
          final giftTxt = unit.isNotEmpty ? '${_qtyStr(gift)}$unit' : 'x${gift.round()}';
          sb.writeln('  赠送 $giftTxt   ¥0.00');
        }
      }
    }
    sb.writeln('--------------------------------');
    final totalV = double.tryParse('${isRefund ? (o['refund_amount'] ?? o['total']) : o['total']}') ?? 0;
    final origV = double.tryParse('${o['original_total'] ?? 0}') ?? 0;
    final molV = double.tryParse('${o['quiling'] ?? 0}') ?? 0; // 现金抹零（v3.3.239 落库）
    // 整单折扣/改价（v3.3.246）：rate>0 折扣，rate=0 且 amount>0 改价；无则不打印
    final wAmt = double.tryParse('${o['whole_discount_amount'] ?? 0}') ?? 0;
    final wRate = double.tryParse('${o['whole_discount_rate'] ?? 0}') ?? 0;
    String? wLabel;
    if (!isRefund && wAmt > 0.001) {
      if (wRate > 0) {
        var r = wRate.toStringAsFixed(1);
        if (r.endsWith('.0')) r = r.substring(0, r.length - 2);
        wLabel = '整单折扣 ${r}折';
      } else {
        wLabel = '整单改价';
      }
    }
    if (!isRefund && origV > totalV + 0.001) {
      // 有活动/整单/优惠券/抹零：商品合计 → 优惠 → 抹零 → 实收（口径与首次打印一致）
      sb.writeln('商品合计: ¥${Fmt.money(origV)}');
      final actCut = origV - totalV - molV - (wLabel != null ? wAmt : 0); // 活动/优惠券部分（整单/抹零单独一行）
      if (wLabel != null) sb.writeln('$wLabel: -¥${Fmt.money(wAmt)}');
      if (actCut > 0.001) sb.writeln('优惠: -¥${Fmt.money(actCut)}');
      if (molV > 0.001) sb.writeln('抹零优惠: -¥${Fmt.money(molV)}');
      sb.writeln('<B>合计: ¥${Fmt.money(totalV)}</B>');
    } else if (!isRefund && (molV > 0.001 || wLabel != null)) {
      // 仅抹零/整单优惠：商品合计 → 折扣行 → 抹零 → 实收
      sb.writeln('商品合计: ¥${Fmt.money(totalV + molV + (wLabel != null ? wAmt : 0))}');
      if (wLabel != null) sb.writeln('$wLabel: -¥${Fmt.money(wAmt)}');
      if (molV > 0.001) sb.writeln('抹零优惠: -¥${Fmt.money(molV)}');
      sb.writeln('<B>合计: ¥${Fmt.money(totalV)}</B>');
    } else {
      sb.writeln('${isRefund ? '退款金额' : '合计'}: ¥${Fmt.money(totalV)}');
    }
    sb.writeln('支付方式: ${o['payment_method'] ?? '-'}');
    if (isRefund) {
      sb.writeln('退款时间: ${DateTime.now().toString().substring(0, 19)}');
    }
    sb.writeln('谢谢惠顾，欢迎下次光临');
    return sb.toString();
  }

  /// 解析订单 goods_list（零售/会员支付/餐饮混合格式）
  /// 兼容四种存储形态：数组 [{...}]、对象 {"0":{...},"1":{...}}（按数字键排序）、JSON 字符串、
  /// 双重编码字符串 "\"[{...}]\""（v3.3.214 会员支付旧落单 huiyuanzhifu 未解 cart 字符串导致，
  /// 解一层得到 JSON 字符串时再解一层）
  static List<Map<String, dynamic>> parseGoods(Map o) {
    try {
      final raw = o['goods_list'];
      List? l;
      var cur = raw;
      // 双重编码：解出来还是字符串就再解一层（最多两层，防脏数据死循环）
      for (var i = 0; i < 2 && cur is String && cur.isNotEmpty && cur != 'null'; i++) {
        final d = jsonDecode(cur);
        cur = d;
      }
      if (cur is List) {
        l = cur;
      } else if (cur is Map) {
        l = _mapValues(cur);
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
