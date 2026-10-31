import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/order_card.dart';
import '../../ui/widgets.dart';

/// 订单页：店内订单（POS）+ 小程序订单（order_from 区分）
/// 卡片为左右布局：左侧订单信息，右侧购物清单（可折叠），支持 云打印/USB打印/退款
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
                    : RefreshIndicator(
                        onRefresh: _load,
                        color: PosTheme.accent,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (_, i) => OrderCard(
                            order: filtered[i],
                            onRefunded: _load,
                          ),
                        ),
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
}
