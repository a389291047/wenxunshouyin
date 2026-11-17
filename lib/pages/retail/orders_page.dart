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
  String kw = ''; // 订单号 / 支付方式 / 金额 搜索（本页内过滤）

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
    // 搜索过滤（不区分大小写，匹配订单号 / 支付方式 / 金额）
    final k = kw.trim().toLowerCase();
    if (k.isNotEmpty) {
      l = l.where((o) {
        final no = '${o['order_number'] ?? ''}'.toLowerCase();
        final pm = '${o['payment_method'] ?? ''}'.toLowerCase();
        final amt = Fmt.money(o['total']);
        return no.contains(k) || pm.contains(k) || amt.contains(k);
      });
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
                  // 搜索行（v3.3.216）：订单号 / 支付方式 / 金额
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                    child: TextField(
                      onChanged: (v) => setState(() { kw = v; _ensureSelected(); }),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索订单号 / 支付方式 / 金额',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: kw.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 17),
                                onPressed: () => setState(() { kw = ''; _ensureSelected(); }),
                              ),
                      ),
                    ),
                  ),
                  const Divider(height: 14, color: PosTheme.line),
                  // 列表表头：与单行布局对齐（订单号 / 时间 / 支付方式 / 金额）
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

  /// 表头（v3.3.216）：与单行布局对齐——圆点+订单号 / 时间 / 支付方式 / 金额，四段等分
  Widget _listHeader() {
    const segStyle = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textSub);
    return Container(
      padding: const EdgeInsets.fromLTRB(26, 6, 26, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F8FA),
        border: Border(bottom: BorderSide(color: PosTheme.line)),
      ),
      child: Row(children: [
        const Expanded(
          flex: 3,
          child: Text('订单号 / 状态', style: segStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 10),
        const Expanded(
          flex: 2,
          child: Text('时间', style: segStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 10),
        const Expanded(
          flex: 2,
          child: Text('支付方式', style: segStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 88,
          child: Text('金额', textAlign: TextAlign.right, style: segStyle),
        ),
      ]),
    );
  }

  /// 状态圆点：绿=正常已支付，橙=未支付/退款中，红=已退款/部分退款
  Color _statusColor(Map o) {
    final refundSt = int.tryParse('${o['refund_status']}') ?? 0;
    final refundedAmt = double.tryParse('${o['refund_amount']}') ?? 0;
    if (refundSt == 2 || (refundSt == 0 && refundedAmt > 0)) return PosTheme.red;
    if (refundSt == 1) return PosTheme.amber;
    if ('${o['payment_status']}' != '1') return PosTheme.amber;
    return const Color(0xFF34A853);
  }

  String _statusText(Map o) {
    final refundSt = int.tryParse('${o['refund_status']}') ?? 0;
    final refundedAmt = double.tryParse('${o['refund_amount']}') ?? 0;
    if (refundSt == 2) return '已退款';
    if (refundSt == 1) return '退款中';
    if (refundSt == 0 && refundedAmt > 0) return '部分退款';
    if ('${o['payment_status']}' != '1') return '未支付';
    return '';
  }

  /// 单行布局（v3.3.216）：订单号 / 时间 / 支付方式 / 金额 一行等分平均分配，
  /// 超长一律省略号截断，谁也不挤压谁；Material+InkWell 保留按压墨水纹触感
  Widget _orderRow(Map o) {
    final on = selected != null && '${selected!['id']}' == '${o['id']}';
    final st = _statusText(o);
    final t = Fmt.date(o['create_time']);
    final time = t.length >= 16 ? t.substring(5, 16) : t; // MM-dd HH:mm
    Widget seg(int flex, String text, TextStyle style, {bool right = false}) => Expanded(
          flex: flex,
          child: Text(text,
              textAlign: right ? TextAlign.right : TextAlign.left,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style),
        );
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
              // 状态圆点（固定宽，不参与挤压）：绿=正常，橙=未支付/退款中，红=已退款
              Container(
                width: 9, height: 9,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: _statusColor(o), shape: BoxShape.circle),
              ),
              seg(3, '${o['order_number'] ?? ''}',
                  const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              seg(2, time, const TextStyle(fontSize: 13, color: PosTheme.textSub)),
              const SizedBox(width: 10),
              seg(2, st.isEmpty ? '${o['payment_method'] ?? '其他支付'}' : '$st · ${o['payment_method'] ?? ''}',
                  TextStyle(
                      fontSize: 13,
                      color: st.isEmpty ? PosTheme.textSub : (st == '未支付' ? PosTheme.amber : PosTheme.red))),
              const SizedBox(width: 10),
              SizedBox(
                width: 88,
                child: Text('¥${Fmt.money(o['total'])}',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: PosTheme.accent)),
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
