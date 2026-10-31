import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/order_card.dart';
import '../../ui/widgets.dart';

/// 订单页：店内订单（POS）+ 小程序订单（order_from 区分）
/// 时间筛选：今天 / 昨天 / 上周（上一个自然周）
/// 卡片为双卡片布局：左侧订单信息卡，右侧购物清单卡（含打印/退款操作）
class RetailOrdersPage extends StatefulWidget {
  const RetailOrdersPage({super.key});
  @override
  State<RetailOrdersPage> createState() => _RetailOrdersPageState();
}

class _RetailOrdersPageState extends State<RetailOrdersPage> {
  int tab = 0; // 0 店内 1 小程序
  int timeTab = 0; // 0 今天 1 昨天 2 上周
  List all = [];
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
      final r = await Api.ordersAll(Session.wenxunId);
      if (!mounted) return;
      setState(() { all = r; loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.message; });
    }
  }

  static String _day(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  List get filtered {
    Iterable l = all.where((o) {
      final from = int.tryParse('${o['order_from']}') ?? 2;
      return tab == 0 ? from == 2 : from == 1;
    });
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (timeTab) {
      case 0: // 今天
        final s = _day(now);
        l = l.where((o) => '${o['create_time']}'.startsWith(s));
        break;
      case 1: // 昨天
        final s = _day(today.subtract(const Duration(days: 1)));
        l = l.where((o) => '${o['create_time']}'.startsWith(s));
        break;
      case 2: // 上周（上一个自然周 周一 ~ 周日）
        final thisMonday = today.subtract(Duration(days: now.weekday - 1));
        final ss = _day(thisMonday.subtract(const Duration(days: 7)));
        final ee = _day(thisMonday.subtract(const Duration(days: 1)));
        l = l.where((o) {
          final t = '${o['create_time']}';
          final dd = t.length >= 10 ? t.substring(0, 10) : t;
          return dd.compareTo(ss) >= 0 && dd.compareTo(ee) <= 0;
        });
        break;
    }
    return l.toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader('订单管理', actions: [
        OutlinedButton.icon(
          onPressed: _load,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16), foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('刷新'),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Row(children: [
          _seg('店内订单', 0, tab, (v) => tab = v),
          const SizedBox(width: 10),
          _seg('小程序订单', 1, tab, (v) => tab = v),
          const SizedBox(width: 18),
          Container(width: 1, height: 22, color: PosTheme.line),
          const SizedBox(width: 18),
          _timeSeg('今天', 0),
          const SizedBox(width: 8),
          _timeSeg('昨天', 1),
          const SizedBox(width: 8),
          _timeSeg('上周', 2),
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

  Widget _seg(String text, int v, int cur, ValueChanged<int> onSel) {
    final on = cur == v;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => onSel(v)),
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

  Widget _timeSeg(String text, int v) {
    final on = timeTab == v;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => setState(() => timeTab = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(on ? Icons.event_available : Icons.event_outlined,
              size: 15, color: on ? PosTheme.accent : PosTheme.textHint),
          const SizedBox(width: 5),
          Text(text,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? PosTheme.accent : PosTheme.textSub)),
        ]),
      ),
    );
  }
}
