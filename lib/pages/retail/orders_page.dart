import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

/// 订单页：店内订单（POS）+ 小程序订单（order_from 区分）
class RetailOrdersPage extends StatefulWidget {
  const RetailOrdersPage({super.key});
  @override
  State<RetailOrdersPage> createState() => _RetailOrdersPageState();
}

class _RetailOrdersPageState extends State<RetailOrdersPage> {
  int tab = 0; // 0 店内 1 小程序
  List all = [];
  bool loading = true;
  String? error;
  String dateFilter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final r = await Api.ordersAll(Session.wenxunId);
      if (!mounted) return;
      setState(() { all = r; loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.message; });
    }
  }

  List get filtered {
    Iterable l = all;
    // 店内=order_from 2 或空（老数据）；小程序=1
    l = l.where((o) {
      final from = int.tryParse('${o['order_from']}') ?? 2;
      return tab == 0 ? from == 2 : from == 1;
    });
    if (dateFilter.isNotEmpty) {
      l = l.where((o) => '${o['create_time']}'.startsWith(dateFilter));
    }
    return l.toList();
  }

  double get _sumTab => filtered.fold(0, (s, o) => s + (double.tryParse('${o['total']}') ?? 0));

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader('订单管理', actions: [
        SizedBox(
          width: 170,
          child: TextField(
            controller: TextEditingController(text: dateFilter),
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'yyyy-mm-dd 筛选',
              prefixIcon: const Icon(Icons.calendar_today, size: 16),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: PosTheme.line)),
            ),
            onSubmitted: (v) => setState(() => dateFilter = v.trim()),
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: _load,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16), foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('刷新'),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
        child: Row(children: [
          _seg('店内订单', 0),
          const SizedBox(width: 10),
          _seg('小程序订单', 1),
          const Spacer(),
          Text('${filtered.length} 单 · 合计 ¥${Fmt.money(_sumTab)}',
              style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
        ]),
      ),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
            : error != null
                ? Center(child: Text(error!, style: const TextStyle(color: PosTheme.red)))
                : filtered.isEmpty
                    ? const EmptyView('暂无订单')
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _orderCard(filtered[i]),
                      ),
      ),
    ]);
  }

  Widget _seg(String text, int v) {
    final on = tab == v;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => tab = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Text(text, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  Widget _orderCard(Map o) {
    final payMethod = '${o['payment_method'] ?? '其他支付'}';
    final payOk = '${o['payment_status']}' == '1';
    final refundSt = int.tryParse('${o['refund_status']}') ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _detail(o),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${o['order_number'] ?? ''}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              if (!payOk) const TagChip('未支付', color: PosTheme.amber),
              if (refundSt == 1) const TagChip('退款中', color: PosTheme.amber),
              if (refundSt == 2) const TagChip('已退款', color: PosTheme.red),
            ]),
            const SizedBox(height: 4),
            Text('${Fmt.date(o['create_time'])} · ${_goodsBrief(o)}',
                style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('¥${Fmt.money(o['total'])}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.accent)),
            const SizedBox(height: 3),
            Text(payMethod, style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
          ]),
          const SizedBox(width: 10),
          const Icon(Icons.chevron_right, color: PosTheme.textHint),
        ]),
      ),
    );
  }

  String _goodsBrief(Map o) {
    try {
      final raw = o['goods_list'];
      List l;
      if (raw is List) {
        l = raw;
      } else {
        l = (jsonDecode('${o['goods_list'] ?? '[]'}') as List?) ?? [];
      }
      if (l.isEmpty) return '${o['total_count'] ?? 0} 件商品';
      final first = '${l.first['title'] ?? l.first['name'] ?? ''}';
      return l.length > 1 ? '$first 等${l.length}种' : first;
    } catch (_) {
      return '${o['total_count'] ?? 0} 件商品';
    }
  }

  void _detail(Map o) {
    List goods = [];
    try {
      final raw = o['goods_list'];
      goods = raw is List ? raw : ((jsonDecode('${raw ?? '[]'}') as List?) ?? []);
    } catch (_) {}
    showDialog(context: context, builder: (_) => AlertDialog(
      title: Row(children: [
        const Text('订单详情', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('${o['order_number'] ?? ''}', style: const TextStyle(fontSize: 13, color: PosTheme.textHint)),
      ]),
      content: SizedBox(width: 480, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          _kv('支付方式', '${o['payment_method'] ?? '-'}'),
          const SizedBox(width: 10),
          _kv('下单时间', Fmt.date(o['create_time'])),
        ]),
        const SizedBox(height: 10),
        ...goods.map((g) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Text('${g['title'] ?? g['name'] ?? ''}', style: const TextStyle(fontSize: 14.5))),
            Text('¥${Fmt.money(g['price'])} ×${g['num'] ?? g['quantity'] ?? 1}', style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
          ]),
        )),
        const Divider(color: PosTheme.line),
        Row(children: [
          const Text('合计', style: TextStyle(fontSize: 15)),
          const Spacer(),
          Text('¥${Fmt.money(o['total'])}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: PosTheme.accent)),
        ]),
        if ('${o['renyuan_id'] ?? ''}' == '${Session.staffId}') ...[
          const SizedBox(height: 4),
          const Text('本店员订单', style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
        ],
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
    ));
  }

  Widget _kv(String k, String v) {
    return Expanded(child: Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(9)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(fontSize: 11.5, color: PosTheme.textSub)),
        const SizedBox(height: 2),
        Text(v, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      ]),
    ));
  }
}
