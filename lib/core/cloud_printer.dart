import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/api.dart';
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

  /// 收银/堂食结账小票（USB 优先，云打印兜底）
  /// 「手动打印」模式下直接跳过（USB + 云打印都不出票），出票只发生在补打/测试等主动操作
  static Future<Map<String, dynamic>> print(String content) async {
    if (await UsbPrinter.isManual()) return {};
    if (await UsbPrinter.tryPrint(content)) return {};
    if (!await enabled()) return {}; // 云打印开关关闭：不出票
    return printCloud(content);
  }

  /// 手动出票（补打小票等用户主动点击）：不受「手动打印模式」限制
  static Future<Map<String, dynamic>> printManual(String content) async {
    if (await UsbPrinter.tryPrint(content)) return {};
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
  static String diningReprintTicket(Map o) {
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
      extraLines: extra,
    );
  }

  /// 小票标题店铺名：登录商户名，未取到回退「稳讯收银」（v3.3.156）
  static String get shopTitle {
    final n = Session.shopName.trim();
    return n.isEmpty ? '稳讯收银' : n;
  }

  /// 组零售收银小票
  static String retailReceipt({
    required String orderNo,
    required String payMethod,
    required double total,
    required List<Map<String, dynamic>> cart,
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
    // 店铺名一行居中，「结账单」单独一行居中（v3.3.156）
    sb.writeln('<FS2><center>$shopTitle</center></FS2>');
    sb.writeln('<FS2><center>结账单</center></FS2>');
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
    sb.writeln('<FS2><center>${isRefund ? '退款单' : '订单小票'}</center></FS2>');
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
