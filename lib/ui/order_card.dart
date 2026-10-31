import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api.dart';
import '../core/cloud_printer.dart';
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
  static const int _collapseCount = 5;
  bool showAll = false;
  bool busy = false;

  Map get o => widget.order;
  int get orderId => int.tryParse('${o['id']}') ?? 0;
  bool get payOk => '${o['payment_status']}' == '1';
  int get refundSt => int.tryParse('${o['refund_status']}') ?? 0;
  double get total => double.tryParse('${o['total']}') ?? 0;
  double get refunded => double.tryParse('${o['refund_amount']}') ?? 0;
  /// 剩余可退（支持多次部分退款）
  double get refundable {
    final v = double.tryParse((total - refunded).toStringAsFixed(2)) ?? 0;
    return v < 0 ? 0 : v;
  }
  bool get canRefund => payOk && refundSt != 1 && refundable > 0 && orderId > 0;

  List<Map<String, dynamic>> get goods => CloudPrinter.parseGoods(o);
  int get goodsCount => goods.fold(0, (s, g) => s + _qty(g));

  String _name(Map g) => '${g['title'] ?? g['name'] ?? g['goods_name'] ?? ''}';
  double _price(Map g) => double.tryParse('${g['price'] ?? g['unit_price'] ?? 0}') ?? 0;
  int _qty(Map g) => int.tryParse('${g['quantity'] ?? g['num'] ?? 1}') ?? 1;

  // ==================== 打印 ====================

  Future<void> _cloudPrint() async {
    setState(() => busy = true);
    loadingDialog(context, '发送云打印…');
    try {
      await CloudPrinter.print(CloudPrinter.orderTicket(o));
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
    if (!UsbPrinter.supported) {
      toast(context, '当前平台不支持 USB 打印', error: true);
      return;
    }
    if (!await UsbPrinter.enabled()) {
      toast(context, '请先到「设置 → USB小票打印机」启用并选择打印机', error: true);
      return;
    }
    final p = await UsbPrinter.selectedPrinter();
    if (p == null) {
      toast(context, '请先到「设置 → USB小票打印机」选择打印机', error: true);
      return;
    }
    final sp = await SharedPreferences.getInstance();
    final paper = sp.getInt(UsbPrinter.prefPaper) ?? 58;
    setState(() => busy = true);
    try {
      await UsbPrinter.printTicket(p, CloudPrinter.orderTicket(o), paperWidth: paper);
      if (!mounted) return;
      toast(context, 'USB 打印已发送');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) toast(context, 'USB 打印失败：$e', error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
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
        operator: Session.staffName,
        password: '${r['password']}',
        amount: double.tryParse('${r['amount']}') ?? 0,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r2['code']}' == '200') {
        toast(context, '${r2['msg'] ?? '退款成功'}');
        try {
          final oo = Map<String, dynamic>.from(o);
          oo['refund_reason'] = r['reason'];
          oo['refund_amount'] = r['amount'];
          await CloudPrinter.print(CloudPrinter.orderTicket(oo, isRefund: true));
        } catch (_) {}
        widget.onRefunded();
      } else {
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
        ]),
        const SizedBox(height: 8),
        _kvRow(Icons.schedule, Fmt.date(o['create_time'])),
        const SizedBox(height: 5),
        _kvRow(Icons.payments_outlined, '${o['payment_method'] ?? '其他支付'}'),
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
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: PosTheme.textSub)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
            decoration: BoxDecoration(
              color: PosTheme.accent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text('${goods.length} 项',
                style: const TextStyle(fontSize: 11, color: PosTheme.accent, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 6),
        Expanded(
          child: goods.isEmpty
              ? const Center(child: Text('（无商品明细）', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)))
              : ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    ...shown.asMap().entries.map((e) => _goodsRow(e.key + 1, e.value)),
                    if (goods.length > _collapseCount) ...[
                      const SizedBox(height: 4),
                      Center(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => setState(() => showAll = !showAll),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                            decoration: BoxDecoration(
                              color: PosTheme.bg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: PosTheme.line),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(showAll ? '收起' : '展开其余 ${goods.length - _collapseCount} 项',
                                  style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub, fontWeight: FontWeight.w600)),
                              Icon(showAll ? Icons.expand_less : Icons.expand_more,
                                  size: 16, color: PosTheme.textSub),
                            ]),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 12),
        // ---- 操作按钮 ----
        BigButton('云打印订单', onTap: busy ? null : _cloudPrint, height: 48),
        if (UsbPrinter.supported) ...[
          const SizedBox(height: 9),
          BigButton('USB打印订单', onTap: busy ? null : _usbPrint,
              color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 46),
        ],
        const SizedBox(height: 9),
        BigButton(
          canRefund
              ? (refundable < total - 0.001
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

  Widget _goodsRow(int idx, Map g) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(children: [
        Container(
          width: 18, height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: PosTheme.bg,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('$idx', style: const TextStyle(fontSize: 10.5, color: PosTheme.textHint)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(_name(g),
              style: const TextStyle(fontSize: 13.5),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 8),
        Text('¥${Fmt.money(_price(g))} ×${_qty(g)}',
            style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
        const SizedBox(width: 10),
        SizedBox(
          width: 66,
          child: Text('¥${Fmt.money(_price(g) * _qty(g))}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
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
  const _RefundDialog({required this.order, required this.goods, required this.total, required this.refundable});
  @override
  State<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<_RefundDialog> {
  late final List<int> refundQty; // 部分退款时每行退几件
  bool partial = false; // false=整单退款（默认退剩余可退全部）
  final reasonCtl = TextEditingController();
  final pwdCtl = TextEditingController();

  String _name(Map g) => '${g['title'] ?? g['name'] ?? g['goods_name'] ?? ''}';
  double _price(Map g) => double.tryParse('${g['price'] ?? g['unit_price'] ?? 0}') ?? 0;
  int _qty(Map g) => int.tryParse('${g['quantity'] ?? g['num'] ?? 1}') ?? 1;

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

  @override
  void initState() {
    super.initState();
    refundQty = List.filled(widget.goods.length, 0);
  }

  void _confirm() {
    final reason = reasonCtl.text.trim();
    final pwd = pwdCtl.text.trim();
    if (reason.isEmpty) {
      toast(context, '请填写退款原因', error: true);
      return;
    }
    if (!amountValid || amount <= 0) {
      toast(context, partial ? '请选择要退的商品数量' : '退款金额无效', error: true);
      return;
    }
    if (pwd.length != 6 || int.tryParse(pwd) == null) {
      toast(context, '请输入6位数字退款密码（默认商户手机号后6位）', error: true);
      return;
    }
    Navigator.pop(context, {'reason': reason, 'amount': amount, 'password': pwd});
  }

  @override
  Widget build(BuildContext context) {
    final m = '${widget.order['payment_method'] ?? ''}';
    final hint = m.contains('会员')
        ? '退款将自动回补会员余额'
        : (m == '现金' ? '现金收款，线下原路退回并登记' : '将通过星驿付原路退回顾客支付账户');
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
          // 退款原因
          TextField(
            controller: reasonCtl,
            maxLines: 2,
            maxLength: 120,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              counterText: '',
              hintText: '退款原因（必填，如：顾客退货）',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(height: 12),
          // 退款密码
          TextField(
            controller: pwdCtl,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            style: const TextStyle(fontSize: 18, letterSpacing: 6, fontWeight: FontWeight.w700),
            decoration: const InputDecoration(
              counterText: '',
              hintText: '退款密码（6位数字）',
              helperText: '默认为商户手机号后6位，可在设置页修改',
              helperStyle: TextStyle(fontSize: 11.5),
              prefixIcon: Icon(Icons.lock_outline, size: 20),
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          const SizedBox(height: 18),
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

  Widget _modeChip(String text, bool on, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFDEEEE) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: on ? PosTheme.red.withOpacity(0.5) : PosTheme.line),
        ),
        child: Text(text, style: TextStyle(
          fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w400,
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

  /// 部分退款：商品行步进选数量
  Widget _partialList() {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: PosTheme.line), borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        for (var i = 0; i < widget.goods.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: PosTheme.line),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(children: [
              Expanded(
                child: Text(_name(widget.goods[i]),
                    style: const TextStyle(fontSize: 13.5),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              Text('¥${Fmt.money(_price(widget.goods[i]))} ×${_qty(widget.goods[i])}',
                  style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
              const SizedBox(width: 10),
              // 步进器：0 .. 购买数量
              InkWell(
                onTap: refundQty[i] > 0 ? () => setState(() => refundQty[i]--) : null,
                borderRadius: BorderRadius.circular(7),
                child: Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: refundQty[i] > 0 ? const Color(0xFFFDEEEE) : PosTheme.bg,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(Icons.remove, size: 16,
                      color: refundQty[i] > 0 ? PosTheme.red : PosTheme.textHint),
                ),
              ),
              Container(
                width: 40, alignment: Alignment.center,
                child: Text('${refundQty[i]}',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800,
                        color: refundQty[i] > 0 ? PosTheme.red : PosTheme.textHint)),
              ),
              InkWell(
                onTap: refundQty[i] < _qty(widget.goods[i]) ? () => setState(() => refundQty[i]++) : null,
                borderRadius: BorderRadius.circular(7),
                child: Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: refundQty[i] < _qty(widget.goods[i]) ? const Color(0xFFFDEEEE) : PosTheme.bg,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(Icons.add, size: 16,
                      color: refundQty[i] < _qty(widget.goods[i]) ? PosTheme.red : PosTheme.textHint),
                ),
              ),
            ]),
          ),
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
}
