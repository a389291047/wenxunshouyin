import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

/// 交班页（零售/餐饮共用）：当班统计 + 云打印交班单
class ShiftPage extends StatefulWidget {
  const ShiftPage({super.key});
  @override
  State<ShiftPage> createState() => _ShiftPageState();
}

class _ShiftPageState extends State<ShiftPage> {
  Map stats = {};
  List printers = [];
  double refundAmount = 0; // 当天退款金额
  int refundCount = 0; // 当天退款笔数
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
      final p = await CloudPrinter.list();
      // 当天退款统计（客户端计算，避免后端改动）
      var ra = 0.0;
      var rc = 0;
      try {
        final orders = await Api.ordersAll(Session.wenxunId);
        final now = DateTime.now();
        final today =
            '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        for (final o in orders) {
          if ('${o['refund_status']}' != '2') continue;
          if (!'${o['refund_time'] ?? o['update_time'] ?? ''}'.startsWith(today)) continue;
          rc++;
          ra += double.tryParse('${o['refund_amount']}') ?? 0;
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        stats = s;
        printers = p;
        refundAmount = ra;
        refundCount = rc;
        loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.message; });
    }
  }

  Future<void> _printShift() async {
    loadingDialog(context, '发送交班单…');
    try {
      await CloudPrinter.print(CloudPrinter.shiftReceipt(
        zongyingye: double.tryParse('${stats['zongyingye']}') ?? 0,
        bishu: double.tryParse('${stats['bishu']}') ?? 0,
        vip: double.tryParse('${stats['vip']}') ?? 0,
        xianjin: double.tryParse('${stats['xianjin']}') ?? 0,
        saoma: double.tryParse('${stats['saoma']}') ?? 0,
        refundAmount: refundAmount,
        refundCount: refundCount,
      ));
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '交班单已发送打印');
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
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
                : ListView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), children: [
                    // 当班信息
                    AppCard(child: Row(children: [
                      CircleAvatar(radius: 26, backgroundColor: PosTheme.accent.withOpacity(0.12),
                          child: const Icon(Icons.person, color: PosTheme.accent, size: 28)),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(Session.staffName, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text('${Session.roleName} · ${Session.shopName}', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                      ])),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(color: PosTheme.green.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                        child: Text('当班中 · ${Session.shiftStart}', style: const TextStyle(fontSize: 12.5, color: PosTheme.green, fontWeight: FontWeight.w600)),
                      ),
                    ])),
                    const SizedBox(height: 14),
                    // 统计
                    Row(children: [
                      Expanded(child: StatTile(label: '营业总额', value: '¥${Fmt.money(stats['zongyingye'])}', icon: Icons.storefront, color: PosTheme.accent)),
                      const SizedBox(width: 12),
                      Expanded(child: StatTile(label: '收款笔数', value: '${(double.tryParse('${stats['bishu']}') ?? 0).toInt()}', icon: Icons.receipt_long, color: PosTheme.blue)),
                      const SizedBox(width: 12),
                      Expanded(child: StatTile(label: '扫码收款', value: '¥${Fmt.money(stats['saoma'])}', icon: Icons.qr_code_scanner, color: PosTheme.green)),
                      const SizedBox(width: 12),
                      Expanded(child: StatTile(label: '会员支付', value: '¥${Fmt.money(stats['vip'])}', icon: Icons.badge_outlined, color: PosTheme.blue)),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: StatTile(label: '现金收款', value: '¥${Fmt.money(stats['xianjin'])}', icon: Icons.payments_outlined, color: PosTheme.amber)),
                      const SizedBox(width: 12),
                      Expanded(child: StatTile(label: '退款金额', value: '¥${Fmt.money(refundAmount)}', icon: Icons.undo_outlined, color: PosTheme.red)),
                      const SizedBox(width: 12),
                      Expanded(child: StatTile(label: '退款笔数', value: '$refundCount', icon: Icons.assignment_return_outlined, color: PosTheme.red)),
                      const SizedBox(width: 12),
                      const Expanded(child: SizedBox()),
                    ]),
                    const SizedBox(height: 14),
                    // 打印机
                    AppCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          const Icon(Icons.print_outlined, size: 20, color: PosTheme.textSub),
                          const SizedBox(width: 8),
                          const Text('云打印机', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                          const Spacer(),
                          Text('共 ${printers.length} 台', style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                        ]),
                        const SizedBox(height: 12),
                        if (printers.isEmpty)
                          const Text('未绑定云打印机，请到「设置 → 云打印」配置',
                              style: TextStyle(fontSize: 13, color: PosTheme.textHint))
                        else
                          ...printers.map((p) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(children: [
                              Container(width: 8, height: 8,
                                  decoration: BoxDecoration(
                                    color: '${p['is_online']}' == '1' ? PosTheme.green : PosTheme.textHint,
                                    shape: BoxShape.circle)),
                              const SizedBox(width: 10),
                              Expanded(child: Text('${p['name']}（${p['machine_code']}）',
                                  style: const TextStyle(fontSize: 13.5))),
                              TagChip('${p['is_online'] == 1 ? '在线' : '离线'}', color: '${p['is_online']}' == '1' ? PosTheme.green : PosTheme.textHint),
                            ]),
                          )),
                        const SizedBox(height: 14),
                        BigButton('打印交班单', onTap: _printShift, height: 50),
                      ]),
                    ),
                  ]),
      ),
    ]);
  }
}
