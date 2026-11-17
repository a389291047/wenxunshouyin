import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/order_card.dart';
import '../../ui/widgets.dart';
import '../../ui/xyf_orphan_check.dart';

/// 订单页（主从布局，与会员页一致）：
/// 左卡 = 筛选（店内/小程序 · 今天/昨天/上周）+ 订单列表，默认选中当天最新一笔
/// 右卡 = 选中订单详情（购物清单 + 云打印/USB打印/退款）
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
  Map? selected;

  /// 订单数据权限（v3.3.214）：收银员/服务员只能看当天，店长/商户主账号可看全部
  bool get canSeeAll => Session.canSeeAllOrders;

  @override
  void initState() {
    super.initState();
    _load();
    // 星驿付「未落单流水」兜底检查：扫码收款成功但订单未创建（收银机中断）时提示原路退款
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) checkXyfOrphans(context);
    });
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final r = await Api.ordersAll(Session.wenxunId);
      if (!mounted) return;
      setState(() { all = r; loading = false; });
      _ensureSelected();
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
    // 收银员/服务员锁定当天：无论切到哪个时间档都只显示今天的单（v3.3.214）
    final eff = canSeeAll ? timeTab : 0;
    switch (eff) {
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

  /// 默认选中当前筛选的第一笔（后端按时间倒序 = 最新）；选中项被筛掉时自动切换
  void _ensureSelected() {
    final f = filtered;
    if (f.isEmpty) {
      selected = null;
      return;
    }
    final curId = selected == null ? '' : '${selected!['id']}';
    final stillThere = f.any((o) => '${o['id']}' == curId);
    if (!stillThere) selected = f.first;
  }

  void _switchFilter(void Function() fn) {
    setState(fn);
    setState(_ensureSelected);
  }

  @override
  Widget build(BuildContext context) {
    final f = filtered;
    return Column(children: [
      PageHeader('订单管理', actions: [
        OutlinedButton.icon(
          onPressed: _load,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16), foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('刷新'),
        ),
      ]),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ---------- 左卡：筛选 + 订单列表 ----------
            Expanded(
              flex: 6,
              child: AppCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  // 筛选行
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                    child: Row(children: [
                      _seg('店内订单', 0, tab, (v) => _switchFilter(() => tab = v)),
                      const SizedBox(width: 8),
                      _seg('小程序订单', 1, tab, (v) => _switchFilter(() => tab = v)),
                      const Spacer(),
                      // 收银员/服务员只显示「今天」档并锁定（v3.3.214）
                      if (canSeeAll) ...[
                        _timeSeg('今天', 0),
                        const SizedBox(width: 6),
                        _timeSeg('昨天', 1),
                        const SizedBox(width: 6),
                        _timeSeg('上周', 2),
                      ] else
                        const Text('收银员仅可查看当天订单',
                            style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
                    ]),
                  ),
                  const Divider(height: 14, color: PosTheme.line),
                  // 列表表头（v3.3.215 触屏优化）
                  _listHeader(),
                  Expanded(
                    child: loading
                        ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                        : error != null
                            ? Center(child: Text(error!, style: const TextStyle(color: PosTheme.red)))
                            : f.isEmpty
                                ? const EmptyView('暂无订单')
                                : RefreshIndicator(
                                    onRefresh: _load,
                                    color: PosTheme.accent,
                                    child: ListView.builder(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      itemCount: f.length,
                                      itemBuilder: (_, i) => _orderRow(f[i]),
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
              child: selected == null
                  ? AppCard(child: EmptyView(loading ? '加载中…' : '选择订单查看详情'))
                  : OrderDetailPanel(
                      key: ValueKey('${selected!['id']}'),
                      order: selected!,
                      onRefunded: _load,
                    ),
            ),
          ]),
        ),
      ),
    ]);
  }

  // ==================== 左侧列表行 ====================

  /// 表头（v3.3.215）：与行布局对齐——左「订单号 / 状态」，右「金额」
  Widget _listHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(26, 4, 26, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F8FA),
        border: Border(bottom: BorderSide(color: PosTheme.line)),
      ),
      child: Row(children: [
        const Expanded(
          child: Text('订单号 / 状态',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textSub)),
        ),
        const SizedBox(width: 96, child: Text('金额',
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textSub))),
      ]),
    );
  }

  Widget _orderRow(Map o) {
    final on = selected != null && '${selected!['id']}' == '${o['id']}';
    final refundSt = int.tryParse('${o['refund_status']}') ?? 0;
    final refundedAmt = double.tryParse('${o['refund_amount']}') ?? 0;
    final payOk = '${o['payment_status']}' == '1';
    // 触屏行高：内边距加大 + 选中态描边；Material+InkWell 提供按压墨水纹触感（v3.3.215）
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: on ? const Color(0xFFFFF2ED) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => selected = o),
          splashColor: PosTheme.accent.withOpacity(0.10),
          highlightColor: PosTheme.accent.withOpacity(0.06),
          hoverColor: PosTheme.accent.withOpacity(0.04),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: on ? PosTheme.accent.withOpacity(0.45) : Colors.transparent,
                  width: 1.2),
            ),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text('${o['order_number'] ?? ''}',
                        style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  if (!payOk) const TagChip('未支付', color: PosTheme.amber),
                  if (refundSt == 1) const TagChip('退款中', color: PosTheme.amber),
                  if (refundSt == 2) const TagChip('已退款', color: PosTheme.red),
                  if (refundSt == 0 && refundedAmt > 0) const TagChip('部分退款', color: PosTheme.red),
                ]),
                const SizedBox(height: 6),
                Text('${Fmt.date(o['create_time'])} · ${o['payment_method'] ?? '其他支付'}',
                    style: const TextStyle(fontSize: 13, color: PosTheme.textSub),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),
              const SizedBox(width: 12),
              SizedBox(
                width: 96,
                child: Text('¥${Fmt.money(o['total'])}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: PosTheme.accent)),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ==================== 筛选控件 ====================

  Widget _seg(String text, int v, int cur, ValueChanged<int> onSel) {
    final on = cur == v;
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () => onSel(v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  Widget _timeSeg(String text, int v) {
    final on = timeTab == v;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _switchFilter(() => timeTab = v),
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
