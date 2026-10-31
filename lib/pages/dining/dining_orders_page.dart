import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/order_card.dart';
import '../../ui/widgets.dart';

/// 餐饮版 · 订单页：堂食订单（分页）+ 小程序订单
class DiningOrdersPage extends StatefulWidget {
  const DiningOrdersPage({super.key});
  @override
  State<DiningOrdersPage> createState() => _DiningOrdersPageState();
}

class _DiningOrdersPageState extends State<DiningOrdersPage> {
  int tab = 0; // 0 堂食 1 小程序
  // 堂食
  List diningList = [];
  int page = 1;
  int pages = 1;
  int? statusFilter; // null 全部
  bool loading = true;
  // 小程序
  List xcxAll = []; // order_from=1 全量
  int xcxTimeTab = 0; // 0 今天 1 昨天 2 上周
  Map? xcxSelected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      if (tab == 0) {
        final r = await Api.diningOrders(Session.wenxunId, page, 20, statusFilter);
        if (!mounted) return;
        final d = r['data'] ?? {};
        setState(() {
          diningList = (d['list'] ?? []) as List;
          pages = int.tryParse('${d['pages']}') ?? 1;
          loading = false;
        });
      } else {
        final all = await Api.ordersAll(Session.wenxunId);
        if (!mounted) return;
        setState(() {
          xcxAll = all.where((o) => '${o['order_from']}' == '1').toList();
          loading = false;
        });
        _ensureXcxSelected();
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      toast(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader('订单管理'),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
        child: Row(children: [
          _seg('堂食订单', 0),
          const SizedBox(width: 10),
          _seg('小程序订单', 1),
          if (tab == 0) ...[
            const SizedBox(width: 16),
            _statusSeg(),
          ],
        ]),
      ),
      Expanded(child: tab == 0 ? _diningBody() : _xcxBody()),
    ]);
  }

  Widget _seg(String text, int v) {
    final on = tab == v;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        if (tab == v) return;
        setState(() { tab = v; loading = true; });
        _load();
      },
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

  Widget _statusSeg() {
    const opts = [
      {'v': null, 't': '全部'},
      {'v': 0, 't': '就餐中'},
      {'v': 1, 't': '已结算'},
      {'v': 3, 't': '已取消'},
    ];
    return Row(children: opts.map((o) {
      final on = statusFilter == o['v'];
      return GestureDetector(
        onTap: () { setState(() { statusFilter = o['v'] as int?; page = 1; }); _load(); },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            color: on ? PosTheme.blue.withOpacity(0.12) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: on ? PosTheme.blue : PosTheme.line),
          ),
          child: Text('${o['t']}', style: TextStyle(fontSize: 13, color: on ? PosTheme.blue : PosTheme.textSub, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
        ),
      );
    }).toList());
  }

  // ==================== 堂食 ====================
  Widget _diningBody() {
    if (loading) return const Center(child: CircularProgressIndicator(color: PosTheme.accent));
    if (diningList.isEmpty) return const EmptyView('暂无堂食订单');
    return Column(children: [
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
          itemCount: diningList.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) => _diningCard(diningList[i]),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton.outlined(onPressed: page > 1 ? () { setState(() => page--); _load(); } : null, icon: const Icon(Icons.chevron_left)),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 14),
            child: Text('$page / $pages 页', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          IconButton.outlined(onPressed: page < pages ? () { setState(() => page++); _load(); } : null, icon: const Icon(Icons.chevron_right)),
        ]),
      ),
    ]);
  }

  Widget _diningCard(Map o) {
    final st = int.tryParse('${o['order_status']}') ?? 0;
    final stColor = {0: PosTheme.accent, 1: PosTheme.green, 2: PosTheme.blue, 3: PosTheme.textHint}[st] ?? PosTheme.textHint;
    final goods = (o['goods_list'] ?? []) as List;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _detail(o),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${o['table_title'] ?? ''} · ${o['people_num'] ?? '-'}人', style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              TagChip('${o['status_text'] ?? ''}', color: stColor),
            ]),
            const SizedBox(height: 4),
            Text('单号 ${o['order_sn'] ?? '未结算'} · ${Fmt.date(o['create_time'])} · ${goods.length} 项菜品',
                style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
          ])),
          Text('¥${Fmt.money(o['final_total'] ?? o['goods_total'] ?? 0)}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.accent)),
          const SizedBox(width: 10),
          const Icon(Icons.chevron_right, color: PosTheme.textHint),
        ]),
      ),
    );
  }

  void _detail(Map o) {
    final goods = (o['goods_list'] ?? []) as List;
    showDialog(context: context, builder: (_) => AlertDialog(
      title: Text('堂食订单 · ${o['table_title'] ?? ''}'),
      content: SizedBox(width: 480, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('单号 ${o['order_sn'] ?? '-'} · ${o['status_text'] ?? ''} · 收银 ${o['operator_name'] ?? '-'}',
            style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
        const SizedBox(height: 10),
        ...goods.map((g) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Text('${g['goods_title']}', style: const TextStyle(fontSize: 14.5))),
            Text('¥${Fmt.money(g['unit_price'])} ×${g['quantity']}', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
            const SizedBox(width: 12),
            SizedBox(width: 64, child: Text('¥${Fmt.money(g['sub_total'])}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
        )),
        const Divider(color: PosTheme.line),
        Row(children: [
          const Text('实收', style: TextStyle(fontSize: 15)),
          const Spacer(),
          Text('¥${Fmt.money(o['final_total'] ?? o['goods_total'] ?? 0)}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: PosTheme.accent)),
        ]),
        if ('${o['pay1_type'] ?? ''}'.isNotEmpty)
          Text('支付方式：${o['pay1_type']}', style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
    ));
  }

  // ==================== 小程序（主从布局，与订单页一致） ====================

  static String _day(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  List get xcxFiltered {
    Iterable l = xcxAll;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (xcxTimeTab) {
      case 0:
        final s = _day(now);
        l = l.where((o) => '${o['create_time']}'.startsWith(s));
        break;
      case 1:
        final s = _day(today.subtract(const Duration(days: 1)));
        l = l.where((o) => '${o['create_time']}'.startsWith(s));
        break;
      case 2:
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

  void _ensureXcxSelected() {
    final f = xcxFiltered;
    if (f.isEmpty) {
      xcxSelected = null;
      return;
    }
    final curId = xcxSelected == null ? '' : '${xcxSelected!['id']}';
    if (!f.any((o) => '${o['id']}' == curId)) xcxSelected = f.first;
  }

  void _switchXcx(void Function() fn) {
    setState(fn);
    setState(_ensureXcxSelected);
  }

  Widget _xcxBody() {
    final f = xcxFiltered;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ---------- 左卡：时间筛选 + 订单列表 ----------
        Expanded(
          flex: 6,
          child: AppCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                child: Row(children: [
                  _timeSeg('今天', 0),
                  const SizedBox(width: 6),
                  _timeSeg('昨天', 1),
                  const SizedBox(width: 6),
                  _timeSeg('上周', 2),
                  const Spacer(),
                  Text('共 ${f.length} 单',
                      style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                ]),
              ),
              const Divider(height: 14, color: PosTheme.line),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                    : f.isEmpty
                        ? const EmptyView('暂无小程序订单')
                        : RefreshIndicator(
                            onRefresh: _load,
                            color: PosTheme.accent,
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              itemCount: f.length,
                              itemBuilder: (_, i) => _xcxRow(f[i]),
                            ),
                          ),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 16),
        // ---------- 右卡：订单详情 ----------
        Expanded(
          flex: 5,
          child: xcxSelected == null
              ? AppCard(child: EmptyView(loading ? '加载中…' : '选择订单查看详情'))
              : OrderDetailPanel(
                  key: ValueKey('${xcxSelected!['id']}'),
                  order: xcxSelected!,
                  onRefunded: _load,
                ),
        ),
      ]),
    );
  }

  Widget _xcxRow(Map o) {
    final on = xcxSelected != null && '${xcxSelected!['id']}' == '${o['id']}';
    final refundSt = int.tryParse('${o['refund_status']}') ?? 0;
    final payOk = '${o['payment_status']}' == '1';
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => xcxSelected = o),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFFF2ED) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text('${o['order_number'] ?? ''}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 6),
              if (!payOk) const TagChip('未支付', color: PosTheme.amber),
              if (refundSt == 1) const TagChip('退款中', color: PosTheme.amber),
              if (refundSt == 2) const TagChip('已退款', color: PosTheme.red),
            ]),
            const SizedBox(height: 3),
            Text('${Fmt.date(o['create_time'])} · ${o['payment_method'] ?? '其他支付'}',
                style: const TextStyle(fontSize: 12, color: PosTheme.textSub),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
          const SizedBox(width: 8),
          Text('¥${Fmt.money(o['total'])}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.accent)),
        ]),
      ),
    );
  }

  Widget _timeSeg(String text, int v) {
    final on = xcxTimeTab == v;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _switchXcx(() => xcxTimeTab = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6.5),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: on ? PosTheme.accent : PosTheme.textHint)),
      ),
    );
  }
}
