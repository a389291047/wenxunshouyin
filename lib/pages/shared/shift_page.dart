import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/print_prefs.dart';
import '../../core/session.dart';import '../../core/theme.dart';
import '../../core/usb_printer.dart';
import '../../ui/widgets.dart';
import '../dining/dining_page.dart' show DiningJiaobanDialog;

/// 交班页（零售/餐饮共用，主从布局）：
/// 左卡 = 当班信息 + 营业数据 + 云打印/USB打印交班单
/// 右卡 = 当天退款数据（退款金额/笔数 + 退款明细）
class ShiftPage extends StatefulWidget {
  const ShiftPage({super.key});
  @override
  State<ShiftPage> createState() => _ShiftPageState();
}

class _ShiftPageState extends State<ShiftPage> {
  Map stats = {};
  List refundOrders = []; // 当天已退款订单明细
  double refundAmount = 0;
  int refundCount = 0;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final s = await Api.shiftStats(Session.staffId);
      // 当天退款统计与明细（客户端计算，避免后端改动）
      var ra = 0.0;
      var rc = 0;
      final ro = <Map>[];
      try {
        final orders = await Api.ordersAll(Session.wenxunId);
        final now = DateTime.now();
        final today =
            '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        for (final o in orders) {
          if ('${o['refund_status']}' != '2') continue;
          final rt = '${o['refund_time'] ?? o['update_time'] ?? ''}';
          if (!rt.startsWith(today)) continue;
          rc++;
          ra += double.tryParse('${o['refund_amount']}') ?? 0;
          ro.add(o);
        }
        // 按退款时间倒序
        ro.sort((a, b) => ('${b['refund_time'] ?? b['update_time'] ?? ''}')
            .compareTo('${a['refund_time'] ?? a['update_time'] ?? ''}'));
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        stats = s;
        refundOrders = ro;
        refundAmount = ra;
        refundCount = rc;
        loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.message; });
    }
  }

  String get _shiftTicket => CloudPrinter.shiftReceipt(
        zongyingye: double.tryParse('${stats['zongyingye']}') ?? 0,
        bishu: double.tryParse('${stats['bishu']}') ?? 0,
        vip: double.tryParse('${stats['vip']}') ?? 0,
        xianjin: double.tryParse('${stats['xianjin']}') ?? 0,
        saoma: double.tryParse('${stats['saoma']}') ?? 0,
        refundAmount: refundAmount,
        refundCount: refundCount,
      );

  /// 云打印交班单（强制走云打印机，不做 USB 分流）
  Future<void> _cloudPrintShift() async {
    if (!await PrintPrefs.on('shift')) {
      toast(context, '交班单打印已关闭（设置 → 小票打印设置）');
      return;
    }
    loadingDialog(context, '发送交班单到云打印机…');
    try {
      await CloudPrinter.printCloud(_shiftTicket);
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '交班单已发送云打印');
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, '云打印失败：$e', error: true);
    }
  }

  /// USB 打印交班单（默认 USB 小票打印机）
  Future<void> _usbPrintShift() async {
    if (!await PrintPrefs.on('shift')) {
      toast(context, '交班单打印已关闭（设置 → 小票打印设置）');
      return;
    }
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
    loadingDialog(context, 'USB 打印交班单…');
    try {
      await UsbPrinter.printTicket(p, _shiftTicket, paperWidth: paper);
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '交班单已发送 USB 打印');
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, 'USB 打印失败：$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader('交接班', actions: [
        OutlinedButton.icon(
          onPressed: _load,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16), foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('刷新'),
        ),
      ]),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
            : error != null
                ? Center(child: Text(error!, style: const TextStyle(color: PosTheme.red)))
                : Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // ---------- 左卡：营业数据 ----------
                      Expanded(
                        flex: 7,
                        child: AppCard(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            // 当班信息头
                            Row(children: [
                              CircleAvatar(radius: 24, backgroundColor: PosTheme.accent.withOpacity(0.12),
                                  child: const Icon(Icons.person, color: PosTheme.accent, size: 26)),
                              const SizedBox(width: 13),
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(Session.staffName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 2),
                                Text('${Session.roleName} · ${Session.shopName}', style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
                              ])),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                                decoration: BoxDecoration(color: PosTheme.green.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                                child: Text('当班中 · ${Session.shiftStart}', style: const TextStyle(fontSize: 12.5, color: PosTheme.green, fontWeight: FontWeight.w600)),
                              ),
                            ]),
                            const Divider(height: 24, color: PosTheme.line),
                            // 营业总额大字
                            Row(children: [
                              const Text('营业总额', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: PosTheme.textSub)),
                              const Spacer(),
                              Text('¥${Fmt.money(stats['zongyingye'])}',
                                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: PosTheme.accent)),
                            ]),
                            const SizedBox(height: 14),
                            // 收款明细 2×2
                            Row(children: [
                              Expanded(child: StatTile(label: '收款笔数', value: '${(double.tryParse('${stats['bishu']}') ?? 0).toInt()}', icon: Icons.receipt_long, color: PosTheme.blue)),
                              const SizedBox(width: 10),
                              Expanded(child: StatTile(label: '扫码收款', value: '¥${Fmt.money(stats['saoma'])}', icon: Icons.qr_code_scanner, color: PosTheme.green)),
                            ]),
                            const SizedBox(height: 10),
                            Row(children: [
                              Expanded(child: StatTile(label: '会员支付', value: '¥${Fmt.money(stats['vip'])}', icon: Icons.badge_outlined, color: PosTheme.blue)),
                              const SizedBox(width: 10),
                              Expanded(child: StatTile(label: '现金收款', value: '¥${Fmt.money(stats['xianjin'])}', icon: Icons.payments_outlined, color: PosTheme.amber)),
                            ]),
                            const Divider(height: 24, color: PosTheme.line),
                            // 打印按钮
                            BigButton('云打印交班单', onTap: _cloudPrintShift, height: 50),
                            if (UsbPrinter.supported) ...[
                              const SizedBox(height: 9),
                              BigButton('USB打印交班单', onTap: _usbPrintShift,
                                  color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 46),
                            ],
                            // 餐饮版：餐饮交班对账（v3.3.77 从点餐页顶栏移入）
                            if (Session.hangye == 2) ...[
                              const SizedBox(height: 9),
                              BigButton('餐饮交班对账（今日堂食）', onTap: () => showDialog(context: context, builder: (_) => const DiningJiaobanDialog()),
                                  color: const Color(0xFFEDFFF5), textColor: PosTheme.green, height: 46),
                            ],
                          ]),
                        ),
                      ),
                      const SizedBox(width: 16),
                      // ---------- 右卡：退款数据 ----------
                      Expanded(
                        flex: 5,
                        child: AppCard(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Row(children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: PosTheme.red.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(Icons.assignment_return_outlined, color: PosTheme.red, size: 20),
                              ),
                              const SizedBox(width: 10),
                              const Text('当天退款', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                            ]),
                            const SizedBox(height: 16),
                            // 退款金额大字
                            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Text('¥${Fmt.money(refundAmount)}',
                                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: PosTheme.red)),
                              const SizedBox(width: 10),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text('$refundCount 笔',
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: PosTheme.textSub)),
                              ),
                            ]),
                            const Divider(height: 24, color: PosTheme.line),
                            Row(children: [
                              const Text('退款明细', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: PosTheme.textSub)),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: PosTheme.red.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Text('$refundCount 笔',
                                    style: const TextStyle(fontSize: 11, color: PosTheme.red, fontWeight: FontWeight.w600)),
                              ),
                            ]),
                            const SizedBox(height: 6),
                            Expanded(
                              child: refundOrders.isEmpty
                                  ? Center(
                                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                                        Icon(Icons.check_circle_outline, size: 40, color: PosTheme.textHint.withOpacity(0.5)),
                                        const SizedBox(height: 8),
                                        const Text('今天没有退款记录', style: TextStyle(fontSize: 13.5, color: PosTheme.textHint)),
                                      ]),
                                    )
                                  : ListView.separated(
                                      padding: const EdgeInsets.symmetric(vertical: 4),
                                      itemCount: refundOrders.length,
                                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                                      itemBuilder: (_, i) => _refundRow(refundOrders[i]),
                                    ),
                            ),
                          ]),
                        ),
                      ),
                    ]),
                  ),
      ),
    ]);
  }

  Widget _refundRow(Map o) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: PosTheme.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosTheme.line),
      ),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${o['order_number'] ?? ''}',
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(
            '${_refundTime(o)}${('${o['refund_reason'] ?? ''}').isNotEmpty ? ' · ${o['refund_reason']}' : ''}',
            style: const TextStyle(fontSize: 12, color: PosTheme.textSub),
            maxLines: 1, overflow: TextOverflow.ellipsis,
          ),
        ])),
        const SizedBox(width: 8),
        Text('-¥${Fmt.money(o['refund_amount'] ?? o['total'])}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.red)),
      ]),
    );
  }

  String _refundTime(Map o) {
    final t = '${o['refund_time'] ?? o['update_time'] ?? ''}';
    return t.length >= 16 ? t.substring(11, 16) : t;
  }
}
