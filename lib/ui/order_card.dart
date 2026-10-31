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
  bool get canRefund => payOk && refundSt == 0 && orderId > 0;
  double get total => double.tryParse('${o['total']}') ?? 0;

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

  // ==================== 退款 ====================

  Future<void> _refund() async {
    if (!canRefund) return;
    final reasonCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('订单退款 · ¥${Fmt.money(total)}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('单号 ${o['order_number'] ?? ''} · ${o['payment_method'] ?? '-'}',
                style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
            const SizedBox(height: 6),
            Text(
              (('${o['payment_method'] ?? ''}').contains('会员'))
                  ? '退款将自动回补会员余额 ¥${Fmt.money(total)}'
                  : (('${o['payment_method'] ?? ''}') == '现金')
                      ? '现金收款，线下原路退回并登记'
                      : '将通过星驿付原路退回顾客支付账户',
              style: const TextStyle(fontSize: 13, color: PosTheme.amber),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtl,
              maxLines: 2,
              maxLength: 120,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                hintText: '退款原因（必填，如：顾客退货）',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: PosTheme.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认退款'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final reason = reasonCtl.text.trim();
    if (reason.isEmpty) {
      toast(context, '请填写退款原因', error: true);
      return;
    }
    setState(() => busy = true);
    loadingDialog(context, '正在退款…');
    try {
      final r = await Api.orderRefund(
        wenxunId: Session.wenxunId,
        orderId: orderId,
        reason: reason,
        operator: Session.staffName,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        toast(context, '${r['msg'] ?? '退款成功'}');
        try {
          final oo = Map<String, dynamic>.from(o);
          oo['refund_reason'] = reason;
          oo['refund_amount'] = total;
          await CloudPrinter.print(CloudPrinter.orderTicket(oo, isRefund: true));
        } catch (_) {}
        widget.onRefunded();
      } else {
        toast(context, '${r['msg'] ?? '退款失败'}', error: true);
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
          if (refundSt == 2) const TagChip('已退款', color: PosTheme.red),
        ]),
        const SizedBox(height: 8),
        _kvRow(Icons.schedule, Fmt.date(o['create_time'])),
        const SizedBox(height: 5),
        _kvRow(Icons.payments_outlined, '${o['payment_method'] ?? '其他支付'}'),
        if (refundSt == 2) ...[
          const SizedBox(height: 5),
          _kvRow(Icons.undo, '退款 ¥${Fmt.money(o['refund_amount'] ?? total)} · ${o['refund_reason'] ?? ''}',
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
        BigButton(canRefund ? '退款 ¥${Fmt.money(total)}' : (refundSt == 2 ? '已退款' : '不可退款'),
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
