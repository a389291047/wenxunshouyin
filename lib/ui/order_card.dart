import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/bt_printer.dart';
import '../core/cloud_printer.dart';
import '../core/print_prefs.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/usb_printer.dart';
import 'widgets.dart';

/// 订单卡片（订单管理页共用）：左侧订单信息卡，右侧购物清单卡（默认5项，超出折叠）
/// 操作（右侧卡内）：云打印订单 / USB打印 / 退款
/// + 云打印 / USB打印 / 退款，选中订单变化时外层用 Key 重建
class OrderDetailPanel extends StatefulWidget {
  final Map order;
  final VoidCallback onRefunded;
  const OrderDetailPanel({super.key, required this.order, required this.onRefunded});

  @override
  State<OrderDetailPanel> createState() => _OrderDetailPanelState();
}

class _OrderDetailPanelState extends State<OrderDetailPanel> {
  /// 折叠阈值（v3.3.215：超过 10 项折叠，按钮加大适配触屏）
  static const int _collapseCount = 10;
  bool showAll = false;
  bool busy = false;

  Map get o => widget.order;
  int get orderId => int.tryParse('${o['id']}') ?? 0;
  bool get payOk => '${o['payment_status']}' == '1';
  int get refundSt => int.tryParse('${o['refund_status']}') ?? 0;
  double get total => double.tryParse('${o['total']}') ?? 0;
  double get refunded => double.tryParse('${o['refund_amount']}') ?? 0;
  /// 剩余可退（部分退款可多次发起，直到退完）
  double get refundable {
    final v = double.tryParse((total - refunded).toStringAsFixed(2)) ?? 0;
    return v < 0 ? 0 : v;
  }

  /// 已部分退款（退过一部分但未退完，refund_status 保持 0）
  bool get partialRefunded => refunded > 0 && refundable > 0;

  /// 退款中（refund_status=1）不可操作；其余只要还有剩余可退就能退
  bool get canRefund => payOk && refundSt != 1 && refundable > 0 && orderId > 0;

  /// 已退商品明细：{行索引: 已退件数}（wx_order.refund_goods JSON）
  Map<int, int> get refundedGoods {
    final raw = o['refund_goods'];
    if (raw == null) return const {};
    final s = '$raw';
    if (s.isEmpty || s == 'null' || s == '{}') return const {};
    try {
      final d = raw is Map ? raw : jsonDecode(s);
      final m = <int, int>{};
      if (d is Map) {
        // 对象形态 {"0":1,"2":1}
        d.forEach((k, v) {
          final i = int.tryParse('$k');
          final q = int.tryParse('$v') ?? 0;
          if (i != null && q > 0) m[i] = q;
        });
      } else if (d is List) {
        // 列表形态 [1,1]（历史数据：PHP json_encode 连续整数键产出），下标即行索引
        for (var i = 0; i < d.length; i++) {
          final q = int.tryParse('${d[i]}') ?? 0;
          if (q > 0) m[i] = q;
        }
      }
      return m;
    } catch (_) {
      return const {};
    }
  }

  /// 现金抹零金额（v3.3.239，wx_order.quiling 落库后订单详情可显示）
  double get mollen => double.tryParse('${o['quiling'] ?? 0}') ?? 0;

  /// 整单折扣/改价（v3.3.246）：rate>0 折扣，rate=0 且 amount>0 改价；无则不显示
  double get wholeAmount => double.tryParse('${o['whole_discount_amount'] ?? 0}') ?? 0;
  double get wholeRate => double.tryParse('${o['whole_discount_rate'] ?? 0}') ?? 0;
  String? get wholeLabel {
    if (wholeAmount <= 0.001) return null;
    if (wholeRate > 0) {
      var r = wholeRate.toStringAsFixed(1);
      if (r.endsWith('.0')) r = r.substring(0, r.length - 2);
      return '整单折扣 ${r}折';
    }
    return '整单改价';
  }

  List<Map<String, dynamic>> get goods => CloudPrinter.parseGoods(o);
  int get goodsCount => goods.fold(0, (s, g) => s + _qty(g));

  String _name(Map g) => '${g['title'] ?? g['name'] ?? g['goods_name'] ?? ''}';
  double _price(Map g) => double.tryParse('${g['price'] ?? g['unit_price'] ?? 0}') ?? 0;
  int _qty(Map g) => int.tryParse('${g['quantity'] ?? g['num'] ?? 1}') ?? 1;
  /// 称重行真实数量（0.534）：仅用于展示/小计；退款按行计仍走 _qty（称重行算 1 件）
  double _qtyNum(Map g) => double.tryParse('${g['quantity'] ?? g['num'] ?? 1}') ?? 1;
  String _unit(Map g) => '${g['unit'] ?? ''}'.trim();
  /// 数量文本：称重行 ×0.534kg，按件行 ×2
  String _qtyTxt(Map g) {
    final unit = _unit(g);
    if (unit.isEmpty) return '×${_qty(g)}';
    final q = _qtyNum(g);
    var s = q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(3);
    if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return '×$s$unit';
  }

  /// 单行赠送数量文本（v3.3.236）：x1 / 0.25kg，与商品行同单位的赠送口径
  String _giftTxt(Map g) {
    final gift = double.tryParse('${g['gift_qty'] ?? 0}') ?? 0;
    if (gift <= 0) return '';
    final unit = _unit(g);
    if (unit.isEmpty) return 'x${gift.round()}';
    var s = gift == gift.roundToDouble() ? gift.toStringAsFixed(0) : gift.toStringAsFixed(3);
    if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return '$s$unit';
  }

  // ==================== 打印 ====================

  /// 补打小票：弹窗选择云打印机 / USB 打印机
  Future<void> _pickPrint() async {
    if (!await PrintPrefs.on('order')) {
      toast(context, '订单小票打印已关闭（设置 → 小票打印设置）');
      return;
    }
    Map<String, dynamic>? usbSel;
    String usbLabel = '';
    if (UsbPrinter.supported && await UsbPrinter.enabled()) {
      usbSel = await UsbPrinter.selectedPrinter();
      if (usbSel != null) {
        final spec = await UsbPrinter.currentSpec();
        usbLabel = '${spec['label']}';
      }
    }
    final cloudOn = await CloudPrinter.enabled();
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('补打小票 · 选择打印方式', style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        children: [
          SimpleDialogOption(
            onPressed: cloudOn ? () => Navigator.pop(ctx, 'cloud') : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              decoration: BoxDecoration(
                  color: cloudOn ? const Color(0xFFF5F7FF) : const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(Icons.cloud_outlined, size: 22, color: cloudOn ? PosTheme.blue : PosTheme.textHint),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('云打印机', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600,
                      color: cloudOn ? null : PosTheme.textHint)),
                  Text(cloudOn ? '默认前台收银小票机（云打印机设置）' : '云打印已关闭（设置 → 云打印机）',
                      style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                ])),
              ]),
            ),
          ),
          if (UsbPrinter.supported) ...[
            const SizedBox(height: 6),
            SimpleDialogOption(
              onPressed: usbSel == null ? null : () => Navigator.pop(ctx, 'usb'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                decoration: BoxDecoration(
                    color: usbSel != null ? const Color(0xFFF2FBF5) : const Color(0xFFF7F8FA),
                    borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Icon(Icons.usb_outlined, size: 22, color: usbSel != null ? PosTheme.accent : PosTheme.textHint),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('USB打印机',
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600,
                            color: usbSel != null ? null : PosTheme.textHint)),
                    Text(usbSel != null ? '${usbSel['name']} · $usbLabel' : '未启用（设置 → USB小票打印机）',
                        style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                  ])),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
    if (choice == 'cloud') {
      await _cloudPrint();
    } else if (choice == 'usb') {
      await _usbPrint();
    }
  }

  Future<void> _cloudPrint() async {
    if (!await PrintPrefs.on('order')) {
      toast(context, '订单小票打印已关闭（设置 → 小票打印设置）');
      return;
    }
    setState(() => busy = true);
    loadingDialog(context, '发送云打印…');
    try {
      // 补打是主动操作，不受 USB「手动打印模式」限制（v3.3.156）
      await CloudPrinter.printManual(CloudPrinter.orderTicket(o));
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '云打印已发送');
    } on ApiError catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '打印失败：$e', error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _usbPrint() async {
    // USB 未启用时自动走蓝牙（v3.3.185），两者都没启用才提示去设置
    if (UsbPrinter.supported && await UsbPrinter.enabled()) {
      final p = await UsbPrinter.selectedPrinter();
      if (p == null) {
        toast(context, '请先到「设置 → USB小票打印机」选择打印机', error: true);
        return;
      }
      final spec = await UsbPrinter.currentSpec();
      setState(() => busy = true);
      try {
        await UsbPrinter.printTicket(p, CloudPrinter.orderTicket(o),
            paperWidth: spec['width'] as int,
            mode: spec['mode'] as String,
            textW: spec['textW'] as int?,
            offsetCols: spec['offsetCols'] as int? ?? 0);
        if (!mounted) return;
        toast(context, 'USB 打印已发送（${spec['label']}）');
      } on ApiError catch (e) {
        if (mounted) toast(context, e.message, error: true);
      } catch (e) {
        if (mounted) toast(context, 'USB 打印失败：$e', error: true);
      } finally {
        if (mounted) setState(() => busy = false);
      }
      return;
    }
    // 蓝牙兜底
    if (await BtPrinter.tryPrint(CloudPrinter.orderTicket(o))) {
      if (mounted) toast(context, '蓝牙打印已发送');
      return;
    }
    toast(context, '请先到「设置 → USB打印」或「设置 → 蓝牙打印」启用打印机', error: true);
  }

  // ==================== 退款（支持部分退款 + 退款密码） ====================

  Future<void> _refund() async {
    if (!canRefund) return;
    final r = await showDialog<Map>(
      context: context,
      builder: (_) => _RefundDialog(
        order: o,
        goods: goods,
        total: total,
        refundable: refundable,
        refundedGoods: refundedGoods,
      ),
    );
    if (r == null || !mounted) return;
    setState(() => busy = true);
    loadingDialog(context, '正在退款…');
    try {
      final r2 = await Api.orderRefund(
        wenxunId: Session.wenxunId,
        orderId: orderId,
        reason: '${r['reason']}',
        operatorId: Session.staffId,
        operator: Session.staffName,
        password: '${r['password']}',
        amount: double.tryParse('${r['amount']}') ?? 0,
        refundGoods: (r['goods'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [],
      );
      if (!mounted) return;
      if ('${r2['code']}' == '200') {
        final msg = '${r2['msg'] ?? '退款成功'}';
        // 「退款申请已受理」= 星驿付退款中：轮询终态（最长约 40 秒），防误报成功
        if (msg.contains('受理')) {
          final st = await Api.pollRefundStatus(dining: false, orderId: orderId);
          if (!mounted) return;
          if (st == 'success') {
            Navigator.pop(context); // loading
            toast(context, '退款成功，资金将原路退回');
          } else if (st == 'fail') {
            Navigator.pop(context); // loading
            toast(context, '退款失败：渠道未完成退款，款项未退出', error: true);
            widget.onRefunded();
            return;
          } else {
            Navigator.pop(context); // loading
            toast(context, '退款处理中，资金将原路退回（1-3 个工作日到账）');
            widget.onRefunded();
            return;
          }
        } else {
          Navigator.pop(context); // loading
          toast(context, msg);
        }
        // 本地同步：累计退款金额 + 已退商品明细（父级列表随后会刷新覆盖）
        setState(() {
          final newRefunded = double.tryParse((refunded + (double.tryParse('${r['amount']}') ?? 0)).toStringAsFixed(2)) ?? 0;
          o['refund_amount'] = newRefunded;
          o['refund_reason'] = r['reason'];
          final merged = Map<int, int>.from(refundedGoods);
          for (final e in (r['goods'] as List? ?? const [])) {
            if (e is! Map) continue;
            final i = int.tryParse('${e['index']}');
            final q = int.tryParse('${e['qty']}') ?? 0;
            if (i != null && q > 0) merged[i] = (merged[i] ?? 0) + q;
          }
          if (merged.isNotEmpty) {
            o['refund_goods'] = jsonEncode(merged.map((k, v) => MapEntry('$k', v)));
          }
          if (newRefunded >= total - 0.001) o['refund_status'] = 2;
        });
        try {
          final oo = Map<String, dynamic>.from(o);
          if (await PrintPrefs.on('refund')) {
            await CloudPrinter.printManual(CloudPrinter.orderTicket(oo, isRefund: true));
          }
        } catch (_) {}
        widget.onRefunded();
      } else {
        Navigator.pop(context); // loading
        toast(context, '${r2['msg'] ?? '退款失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, '退款失败：$e', error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final shown = showAll ? goods : goods.take(_collapseCount).toList();
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ---- 订单信息头 ----
        Row(children: [
          Expanded(
            child: Text('${o['order_number'] ?? ''}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (!payOk) const TagChip('未支付', color: PosTheme.amber),
          if (refundSt == 1) const TagChip('退款中', color: PosTheme.amber),
          if (refundSt == 2) TagChip(refundable > 0 ? '部分退款' : '已退款', color: PosTheme.red),
          if (refundSt == 0 && partialRefunded) const TagChip('部分退款', color: PosTheme.red),
        ]),
        const SizedBox(height: 8),
        _kvRow(Icons.schedule, Fmt.date(o['create_time'])),
        const SizedBox(height: 5),
        _kvRow(Icons.payments_outlined, '${o['payment_method'] ?? '其他支付'}'),
        // 会员信息（v3.3.249）：vip_name 后端列表接口回填；phone 会员支付单落库
        if (('${o['vip_name'] ?? ''}'.trim()).isNotEmpty ||
            ('${o['phone'] ?? ''}'.trim()).isNotEmpty) ...[
          const SizedBox(height: 5),
          Builder(builder: (_) {
            final vn = '${o['vip_name'] ?? ''}'.trim();
            final vp = '${o['phone'] ?? ''}'.trim();
            return _kvRow(Icons.person_outline,
                '会员 ${vn.isEmpty ? vp : vn}${(vn.isNotEmpty && vp.isNotEmpty) ? ' · $vp' : ''}');
          }),
        ],
        if (mollen > 0) ...[
          const SizedBox(height: 5),
          _kvRow(Icons.savings_outlined, '现金抹零 -¥${Fmt.money(mollen)}', color: Colors.green),
        ],
        if (wholeLabel != null) ...[
          const SizedBox(height: 5),
          _kvRow(Icons.percent, '$wholeLabel -¥${Fmt.money(wholeAmount)}', color: Colors.green),
        ],
        if (refunded > 0) ...[
          const SizedBox(height: 5),
          _kvRow(Icons.undo, '已退 ¥${Fmt.money(refunded)} · ${o['refund_reason'] ?? ''}',
              color: PosTheme.red),
        ],
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('¥${Fmt.money(total)}',
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: PosTheme.accent)),
          const Spacer(),
          Text('共 ${goodsCount} 件 / ${goods.length} 项',
              style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
        ]),
        const Divider(height: 22, color: PosTheme.line),
        // ---- 购物清单 ----
        Row(children: [
          const Text('购物清单',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: PosTheme.textSub)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: PosTheme.accent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text('${goods.length} 项',
                style: const TextStyle(fontSize: 12, color: PosTheme.accent, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 6),
        Expanded(
          child: goods.isEmpty
              ? const Center(child: Text('（无商品明细）', style: TextStyle(fontSize: 13, color: PosTheme.textHint)))
              : ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    // 清单表头（v3.3.215 触屏优化）
                    _goodsHeader(),
                    ...shown.asMap().entries.map((e) => _goodsRow(e.key + 1, e.value)),
                    if (goods.length > _collapseCount) ...[
                      const SizedBox(height: 4),
                      Center(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          splashColor: PosTheme.accent.withOpacity(0.10),
                          highlightColor: PosTheme.accent.withOpacity(0.06),
                          onTap: () => setState(() => showAll = !showAll),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                            decoration: BoxDecoration(
                              color: PosTheme.bg,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: PosTheme.line),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(showAll ? '收起' : '展开其余 ${goods.length - _collapseCount} 项',
                                  style: const TextStyle(fontSize: 14, color: PosTheme.textSub, fontWeight: FontWeight.w600)),
                              Icon(showAll ? Icons.expand_less : Icons.expand_more,
                                  size: 20, color: PosTheme.textSub),
                            ]),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 12),
        // ---- 操作按钮（补打：弹窗选择云打印 / USB 直连） ----
        BigButton('补打小票', onTap: busy ? null : _pickPrint, height: 48),
        const SizedBox(height: 9),
        BigButton(
          canRefund
              ? (refunded > 0
                  ? '继续退款 · 剩余可退 ¥${Fmt.money(refundable)}'
                  : '退款 ¥${Fmt.money(total)}')
              : (refundSt == 1 ? '退款中…' : '已退款'),
          onTap: (busy || !canRefund) ? null : _refund,
          color: const Color(0xFFFDEEEE), textColor: PosTheme.red, height: 46),
      ]),
    );
  }

  Widget _kvRow(IconData icon, String text, {Color? color}) {
    return Row(children: [
      Icon(icon, size: 14, color: color ?? PosTheme.textHint),
      const SizedBox(width: 5),
      Expanded(
        child: Text(text,
            style: TextStyle(fontSize: 12.5, color: color ?? PosTheme.textSub),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ]);
  }

  /// 购物清单表头（v3.3.215）：序号 · 商品 · 单价×数量 · 小计
  Widget _goodsHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F8FA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      child: const Row(children: [
        SizedBox(width: 26, child: Text('#',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textHint))),
        SizedBox(width: 8),
        Expanded(child: Text('商品',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textSub))),
        SizedBox(width: 8),
        SizedBox(width: 132, child: Text('单价 × 数量', textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textSub))),
        SizedBox(width: 10),
        SizedBox(width: 72, child: Text('小计', textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textSub))),
      ]),
    );
  }

  Widget _goodsRow(int idx, Map g) {
    final totalQty = _qty(g);
    final lineSub = _unit(g).isNotEmpty ? _price(g) * _qtyNum(g) : _price(g) * totalQty;
    final refundedQty = refundedGoods[idx] ?? 0;
    final fully = refundedQty >= totalQty && totalQty > 0;
    final partly = refundedQty > 0 && !fully;
    // 触屏行高：内边距加大，行与行细分隔线（v3.3.215）
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: PosTheme.line.withOpacity(0.6))),
      ),
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(children: [
        Container(
          width: 26, height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fully ? const Color(0xFFFDEEEE) : PosTheme.bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text('$idx', style: TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w700,
              color: fully ? PosTheme.red : PosTheme.textHint)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(_name(g),
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: fully ? PosTheme.textHint : null,
                        decoration: fully ? TextDecoration.lineThrough : null,
                        decorationColor: PosTheme.red,
                        decorationThickness: 2),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (fully) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDEEEE),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text('已退款',
                      style: TextStyle(fontSize: 11, color: PosTheme.red)),
                ),
              ] else if (partly) ...[
                const SizedBox(width: 6),
                Text('已退$refundedQty件',
                    style: const TextStyle(fontSize: 11.5, color: PosTheme.red)),
              ],
            ]),
            // 单行赠送数量（v3.3.236）：与收银小票口径一致，0 元
            if (!fully && _giftTxt(g).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('赠送 ${_giftTxt(g)} · ¥0.00',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.green, fontWeight: FontWeight.w600)),
              ),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 132,
          child: Text('¥${Fmt.money(_price(g))} ${_qtyTxt(g)}',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 13.5,
                  color: fully ? PosTheme.textHint : PosTheme.textSub,
                  decoration: fully ? TextDecoration.lineThrough : null,
                  decorationColor: PosTheme.red)),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 72,
          child: Text('¥${Fmt.money(lineSub)}',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: fully ? PosTheme.textHint : null,
                  decoration: fully ? TextDecoration.lineThrough : null,
                  decorationColor: PosTheme.red)),
        ),
      ]),
    );
  }
}

/// 退款弹窗：整单 / 部分退款（按商品行选数量）+ 退款密码
/// 返回 {'reason': String, 'amount': double, 'password': String}
class _RefundDialog extends StatefulWidget {
  final Map order;
  final List<Map<String, dynamic>> goods;
  final double total;
  final double refundable;
  final Map<int, int> refundedGoods; // {行索引: 已退件数}
  const _RefundDialog({required this.order, required this.goods, required this.total, required this.refundable, this.refundedGoods = const {}});
  @override
  State<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<_RefundDialog> {
  late final List<int> refundQty; // 部分退款时每行退几件（上限=剩余件数）
  bool partial = false; // false=整单退款（默认退剩余可退全部）
  String reason = ''; // 退款原因（触摸屏选项）
  String pwd = ''; // 权限密码（9宫格数字键盘输入）
  static const List<String> _reasons = ['反结账', '顾客退款', '其他'];

  String _name(Map g) => '${g['title'] ?? g['name'] ?? g['goods_name'] ?? ''}';
  double _price(Map g) => double.tryParse('${g['price'] ?? g['unit_price'] ?? 0}') ?? 0;
  int _qty(Map g) => int.tryParse('${g['quantity'] ?? g['num'] ?? 1}') ?? 1;

  /// 第 i 行剩余可退件数（已退的不能选）
  int _remaining(int i) {
    final v = _qty(widget.goods[i]) - (widget.refundedGoods[i] ?? 0);
    return v < 0 ? 0 : v;
  }

  double get pickAmount {
    var s = 0.0;
    for (var i = 0; i < widget.goods.length; i++) {
      final g = widget.goods[i];
      final price = double.tryParse('${g['price'] ?? g['unit_price'] ?? 0}') ?? 0;
      s += price * (refundQty[i]);
    }
    return double.tryParse(s.toStringAsFixed(2)) ?? 0;
  }

  double get amount => partial ? pickAmount : widget.refundable;
  bool get amountValid => partial ? (pickAmount > 0 && pickAmount <= widget.refundable + 0.001) : true;

  /// 本次退款商品明细：整单=全部剩余件数；部分=勾选行
  List<Map<String, dynamic>> get goodsPayload {
    final l = <Map<String, dynamic>>[];
    for (var i = 0; i < widget.goods.length; i++) {
      final q = partial ? refundQty[i] : _remaining(i);
      if (q > 0) l.add({'index': i, 'qty': q});
    }
    return l;
  }

  @override
  void initState() {
    super.initState();
    refundQty = List.filled(widget.goods.length, 0);
  }

  void _confirm() {
    if (reason.isEmpty) {
      toast(context, '请选择退款原因', error: true);
      return;
    }
    if (!amountValid || amount <= 0) {
      toast(context, partial ? '请选择要退的商品数量' : '退款金额无效', error: true);
      return;
    }
    if (pwd.length != 6) {
      toast(context, '请输入6位数字权限密码（由商户在设置页分配）', error: true);
      return;
    }
    Navigator.pop(context, {'reason': reason, 'amount': amount, 'password': pwd, 'goods': goodsPayload});
  }

  /// 数字键盘按键：数字 / C 清空 / ⌫ 退格
  void _key(String k) {
    setState(() {
      if (k == 'C') {
        pwd = '';
      } else if (k == '<') {
        if (pwd.isNotEmpty) pwd = pwd.substring(0, pwd.length - 1);
      } else if (pwd.length < 6) {
        pwd += k;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = '${widget.order['payment_method'] ?? ''}';
    final hint = m.contains('会员')
        ? '退款将自动回补会员余额'
        : (m == '现金' ? '现金收款，线下原路退回并登记' : '将通过支付渠道原路退回顾客支付账户');
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 560,
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 头部
          Row(children: [
            const Text('订单退款', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(width: 10),
            Expanded(
              child: Text('单号 ${widget.order['order_number'] ?? ''} · $m · ${hint}',
                  style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            InkWell(
              onTap: () => Navigator.pop(context),
              child: const Icon(Icons.close, size: 24, color: PosTheme.textHint),
            ),
          ]),
          const SizedBox(height: 16),
          // 模式切换
          Row(children: [
            _modeChip('整单退款 ¥${Fmt.money(widget.refundable)}', !partial, () => setState(() => partial = false)),
            const SizedBox(width: 10),
            _modeChip('部分退款（按商品）', partial, widget.goods.isEmpty ? null : () => setState(() => partial = true)),
          ]),
          const SizedBox(height: 14),
          // 主体
          Flexible(
            child: SingleChildScrollView(
              child: partial ? _partialList() : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _infoRow('退款金额', '¥${Fmt.money(widget.refundable)}', big: true),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          // 退款原因（触摸屏选择）
          Row(children: [
            const Text('退款原因', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
            const SizedBox(width: 10),
            Expanded(
              child: Row(children: [
                for (var i = 0; i < _reasons.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: _reasonChip(_reasons[i])),
                ],
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          // 权限密码（显示框 + 9宫格数字键盘）
          _pwdBox(),
          const SizedBox(height: 10),
          _pwdPad(),
          const SizedBox(height: 16),
          BigButton(
            '确认退款 ¥${Fmt.money(amount)}',
            onTap: _confirm,
            color: PosTheme.red,
            height: 52,
          ),
        ]),
      ),
    );
  }

  /// 退款原因选项（触摸屏大按钮）
  Widget _reasonChip(String text) {
    final on = reason == text;
    return InkWell(
      onTap: () => setState(() => reason = text),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFDEEEE) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? PosTheme.red.withOpacity(0.5) : PosTheme.line, width: on ? 1.5 : 1),
        ),
        child: Text(text, style: TextStyle(
          fontSize: 14.5, fontWeight: on ? FontWeight.w700 : FontWeight.w400,
          color: on ? PosTheme.red : PosTheme.textSub,
        )),
      ),
    );
  }

  /// 权限密码显示框：6 位圆点
  Widget _pwdBox() {
    return Container(
      height: 54,
      decoration: BoxDecoration(
        color: PosTheme.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosTheme.line),
      ),
      child: Row(children: [
        const SizedBox(width: 12),
        const Icon(Icons.lock_outline, size: 20, color: PosTheme.textHint),
        const SizedBox(width: 12),
        Expanded(
          child: pwd.isEmpty
              ? const Text('请输入权限密码（6位数字，由商户分配）',
                  style: TextStyle(fontSize: 13, color: PosTheme.textHint))
              : Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    for (var i = 0; i < 6; i++) ...[
                      if (i > 0) const SizedBox(width: 10),
                      Container(
                        width: 12, height: 12,
                        decoration: BoxDecoration(
                          color: i < pwd.length ? PosTheme.textMain : Colors.transparent,
                          shape: BoxShape.circle,
                          border: Border.all(color: PosTheme.textHint, width: 1.2),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        if (pwd.isNotEmpty)
          InkWell(
            onTap: () => _key('C'),
            borderRadius: BorderRadius.circular(8),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text('清空', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
            ),
          ),
        const SizedBox(width: 8),
      ]),
    );
  }

  /// 9宫格数字键盘（触摸屏）：1-9 / 清空 0 退格
  Widget _pwdPad() {
    Widget keyBtn(String label, {VoidCallback? onTap, Color? color, IconData? icon}) {
      final enabled = onTap != null;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 58,
          decoration: BoxDecoration(
            color: enabled ? (color ?? Colors.white) : PosTheme.bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: PosTheme.line),
          ),
          alignment: Alignment.center,
          child: icon != null
              ? Icon(icon, size: 24, color: enabled ? PosTheme.textMain : PosTheme.textHint)
              : Text(label, style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w700,
                  color: enabled ? (color ?? PosTheme.textMain) : PosTheme.textHint)),
        ),
      );
    }

    return Column(children: [
      for (var row = 0; row < 4; row++) ...[
        if (row > 0) const SizedBox(height: 8),
        Row(children: [
          for (var col = 0; col < 3; col++) ...[
            if (col > 0) const SizedBox(width: 8),
            Expanded(
              child: row < 3
                  ? keyBtn('${row * 3 + col + 1}', onTap: () => _key('${row * 3 + col + 1}'))
                  : (col == 0
                      ? keyBtn('清空', onTap: pwd.isEmpty ? null : () => _key('C'), color: const Color(0xFFF2F3F7))
                      : (col == 1
                          ? keyBtn('0', onTap: () => _key('0'))
                          : keyBtn('退格', onTap: pwd.isEmpty ? null : () => _key('<'),
                              icon: Icons.backspace_outlined))),
            ),
          ],
        ]),
      ],
    ]);
  }

  Widget _modeChip(String text, bool on, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFDEEEE) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? PosTheme.red.withOpacity(0.5) : PosTheme.line, width: on ? 1.5 : 1),
        ),
        child: Text(text, style: TextStyle(
          fontSize: 14.5, fontWeight: on ? FontWeight.w700 : FontWeight.w400,
          color: on ? PosTheme.red : PosTheme.textSub,
        )),
      ),
    );
  }

  Widget _infoRow(String label, String value, {bool big = false}) {
    return Row(children: [
      Text(label, style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
      const Spacer(),
      Text(value, style: TextStyle(
        fontSize: big ? 24 : 14, fontWeight: FontWeight.w800, color: PosTheme.red)),
    ]);
  }

  /// 部分退款：商品行步进选数量（触屏大按钮，点击区 ≥ 48px）
  /// 已退完的行禁用置灰并打「已退款」标，不可再选
  Widget _partialList() {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: PosTheme.line), borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        for (var i = 0; i < widget.goods.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: PosTheme.line),
          _partialRow(i),
        ],
        if (!amountValid)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(color: Color(0xFFFFF7F4)),
            child: Text('所选商品合计 ¥${Fmt.money(pickAmount)} 超出剩余可退 ¥${Fmt.money(widget.refundable)}，请调整',
                style: const TextStyle(fontSize: 12, color: PosTheme.red)),
          ),
      ]),
    );
  }

  Widget _partialRow(int i) {
    final g = widget.goods[i];
    final remaining = _remaining(i);
    final disabled = remaining <= 0;
    return Container(
      color: disabled ? const Color(0xFFFAFAFA) : null,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(_name(g),
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: disabled ? PosTheme.textHint : null,
                        decoration: disabled ? TextDecoration.lineThrough : null,
                        decorationColor: PosTheme.red,
                        decorationThickness: 2),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (disabled) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDEEEE),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text('已退款',
                      style: TextStyle(fontSize: 11, color: PosTheme.red)),
                ),
              ],
            ]),
            const SizedBox(height: 2),
            Text(
                disabled
                    ? '¥${Fmt.money(_price(g))} ×${_qty(g)} · 已全部退款'
                    : '¥${Fmt.money(_price(g))} ×${_qty(g)}${(widget.refundedGoods[i] ?? 0) > 0 ? ' · 已退${widget.refundedGoods[i]}件' : ''}',
                style: TextStyle(fontSize: 12.5, color: disabled ? PosTheme.textHint : PosTheme.textSub)),
          ]),
        ),
        const SizedBox(width: 10),
        if (disabled) ...[
          const SizedBox(width: 88 + 52 + 8), // 与步进器占位对齐
          SizedBox(
            width: 78,
            child: Text('¥${Fmt.money(_price(g) * _qty(g))}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w700, color: PosTheme.textHint)),
          ),
        ] else ...[
          // 步进器：0 .. 剩余件数
          InkWell(
            onTap: refundQty[i] > 0 ? () => setState(() => refundQty[i]--) : null,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: refundQty[i] > 0 ? const Color(0xFFFDEEEE) : PosTheme.bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.remove, size: 24,
                  color: refundQty[i] > 0 ? PosTheme.red : PosTheme.textHint),
            ),
          ),
          Container(
            width: 52, alignment: Alignment.center,
            child: Text('${refundQty[i]}/${remaining}',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800,
                    color: refundQty[i] > 0 ? PosTheme.red : PosTheme.textHint)),
          ),
          InkWell(
            onTap: refundQty[i] < remaining ? () => setState(() => refundQty[i]++) : null,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: refundQty[i] < remaining ? const Color(0xFFFDEEEE) : PosTheme.bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.add, size: 24,
                  color: refundQty[i] < remaining ? PosTheme.red : PosTheme.textHint),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 78,
            child: Text('¥${Fmt.money(_price(g) * refundQty[i])}',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w700,
                    color: refundQty[i] > 0 ? PosTheme.red : PosTheme.textHint)),
          ),
        ],
      ]),
    );
  }
}
