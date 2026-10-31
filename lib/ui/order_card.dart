import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api.dart';
import '../core/cloud_printer.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/usb_printer.dart';
import 'widgets.dart';

/// 订单卡片（订单管理页共用）：左侧订单信息，右侧购物清单（超出折叠），
/// 操作：云打印订单 / USB打印 / 退款
class OrderCard extends StatefulWidget {
  final Map order;
  final VoidCallback onRefunded;
  const OrderCard({super.key, required this.order, required this.onRefunded});

  @override
  State<OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<OrderCard> {
  bool expanded = false;
  bool busy = false;

  Map get o => widget.order;
  int get orderId => int.tryParse('${o['id']}') ?? 0;
  bool get payOk => '${o['payment_status']}' == '1';
  int get refundSt => int.tryParse('${o['refund_status']}') ?? 0;
  bool get canRefund => payOk && refundSt == 0 && orderId > 0;
  double get total => double.tryParse('${o['total']}') ?? 0;

  List<Map<String, dynamic>> get goods => CloudPrinter.parseGoods(o);

  String _goodsName(Map g) =>
      '${g['title'] ?? g['name'] ?? g['goods_name'] ?? ''}';
  double _goodsPrice(Map g) =>
      double.tryParse('${g['price'] ?? g['unit_price'] ?? 0}') ?? 0;
  int _goodsQty(Map g) =>
      int.tryParse('${g['quantity'] ?? g['num'] ?? 1}') ?? 1;

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
    final sp = await prefPaper();
    setState(() => busy = true);
    try {
      await UsbPrinter.printTicket(
          p, CloudPrinter.orderTicket(o), paperWidth: sp);
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

  Future<int> prefPaper() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt(UsbPrinter.prefPaper) ?? 58;
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
                  : '退款方式：${o['payment_method'] ?? '-'} 线下原路退回',
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
      Navigator.pop(context); // loading
      if ('${r['code']}' == '200') {
        toast(context, '${r['msg'] ?? '退款成功'}');
        // 退款成功自动补打退款单（失败不影响）
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
    final shown = expanded ? goods : goods.take(3).toList();
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ---------- 左：订单信息 ----------
        Expanded(
          flex: 5,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text('${o['order_number'] ?? ''}',
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (!payOk) const TagChip('未支付', color: PosTheme.amber),
              if (refundSt == 1) const TagChip('退款中', color: PosTheme.amber),
              if (refundSt == 2) const TagChip('已退款', color: PosTheme.red),
            ]),
            const SizedBox(height: 6),
            _infoRow(Icons.schedule, Fmt.date(o['create_time'])),
            const SizedBox(height: 4),
            _infoRow(Icons.payments_outlined, '${o['payment_method'] ?? '其他支付'}'),
            if (refundSt == 2) ...[
              const SizedBox(height: 4),
              _infoRow(Icons.undo, '退款 ¥${Fmt.money(o['refund_amount'] ?? total)} · ${o['refund_reason'] ?? ''}',
                  color: PosTheme.red),
            ],
            const SizedBox(height: 10),
            Text('¥${Fmt.money(total)}',
                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: PosTheme.accent)),
          ]),
        ),
        Container(width: 1, height: 96, margin: const EdgeInsets.symmetric(horizontal: 16), color: PosTheme.line),
        // ---------- 右：购物清单 ----------
        Expanded(
          flex: 6,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('购物清单',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: PosTheme.textSub)),
            const SizedBox(height: 6),
            if (goods.isEmpty)
              const Text('（无商品明细）', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint))
            else
              ...shown.map((g) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.5),
                    child: Row(children: [
                      Expanded(
                        child: Text(_goodsName(g),
                            style: const TextStyle(fontSize: 13.5),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      Text('¥${Fmt.money(_goodsPrice(g))} ×${_goodsQty(g)}',
                          style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
                    ]),
                  )),
            if (goods.length > 3)
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => expanded = !expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(expanded ? '收起' : '展开全部 ${goods.length} 项',
                        style: const TextStyle(fontSize: 12.5, color: PosTheme.accent, fontWeight: FontWeight.w600)),
                    Icon(expanded ? Icons.expand_less : Icons.expand_more,
                        size: 17, color: PosTheme.accent),
                  ]),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 8),
        // ---------- 操作按钮列 ----------
        Column(children: [
          _actBtn(Icons.print_outlined, '云打印', busy ? null : _cloudPrint),
          const SizedBox(height: 6),
          if (UsbPrinter.supported)
            _actBtn(Icons.usb_outlined, 'USB打印', busy ? null : _usbPrint),
          if (UsbPrinter.supported) const SizedBox(height: 6),
          _actBtn(Icons.undo_outlined, '退款',
              (busy || !canRefund) ? null : _refund, danger: true),
        ]),
      ]),
    );
  }

  Widget _infoRow(IconData icon, String text, {Color? color}) {
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

  Widget _actBtn(IconData icon, String label, VoidCallback? onTap, {bool danger = false}) {
    final c = danger ? PosTheme.red : PosTheme.accent;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 74,
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: onTap == null ? const Color(0xFFF7F8FA) : c.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: onTap == null ? PosTheme.line : c.withOpacity(0.35)),
        ),
        child: Column(children: [
          Icon(icon, size: 17, color: onTap == null ? PosTheme.textHint : c),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(fontSize: 10.5, color: onTap == null ? PosTheme.textHint : c)),
        ]),
      ),
    );
  }
}
