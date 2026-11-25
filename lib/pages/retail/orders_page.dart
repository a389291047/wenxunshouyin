import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/print_prefs.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/order_card.dart';
import '../../ui/touch_keyboard.dart';
import '../../ui/widgets.dart';
import '../../ui/xyf_orphan_check.dart';

/// 订单页（主从布局，与会员页一致）：
/// 左卡 = 筛选（店内/小程序/充值订单 · 今天/昨天/上周）+ 订单列表，默认选中当天最新一笔
/// 右卡 = 选中订单详情（购物清单 + 云打印/USB打印/退款）；充值页签 = 充值单详情 + 补打充值小票/充值退款
class RetailOrdersPage extends StatefulWidget {
  const RetailOrdersPage({super.key});
  @override
  State<RetailOrdersPage> createState() => _RetailOrdersPageState();
}

class _RetailOrdersPageState extends State<RetailOrdersPage> {
  int tab = 0; // 0 店内 1 小程序 2 充值订单（v3.3.218）
  int timeTab = 0; // 0 今天 1 昨天 2 本周 3 上周
  List all = [];
  List czAll = []; // 会员充值流水（wx_vip_chongzhika 近300条，切到充值页签时加载）
  bool loading = true;
  String? error;
  Map? selected;
  String kw = ''; // 订单号 / 支付方式 / 金额 搜索（本页内过滤）
  final kwCtrl = TextEditingController(); // 搜索框控制器（数字键盘写入用，v3.3.276b）
  bool kbOpen = false; // 搜索数字键盘开合

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
      if (tab == 2) {
        final r = await Api.chongzhikaList(Session.wenxunId);
        if (!mounted) return;
        setState(() { czAll = r; loading = false; });
      } else {
        final r = await Api.ordersAll(Session.wenxunId);
        if (!mounted) return;
        setState(() { all = r; loading = false; });
      }
      _ensureSelected();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.message; });
    }
  }

  static String _day(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  List get filtered {
    if (tab == 2) return czFiltered;
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
      case 2: // 本周（本周一 ~ 今天）
        final thisMonday = today.subtract(Duration(days: now.weekday - 1));
        final ss = _day(thisMonday);
        l = l.where((o) {
          final t = '${o['create_time']}';
          final dd = t.length >= 10 ? t.substring(0, 10) : t;
          return dd.compareTo(ss) >= 0;
        });
        break;
      case 3: // 上周（上一个自然周 周一 ~ 周日）
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
        final pm = _payMethods(o).toLowerCase(); // 含组合支付 _2/_3（v3.3.260）
        final amt = Fmt.money(o['total']);
        return no.contains(k) || pm.contains(k) || amt.contains(k);
      });
    }
    return l.toList();
  }

  /// 充值流水过滤（tab==2）：按 pay_time 时间档 + 搜索（充值单号/会员/手机号/金额）
  List get czFiltered {
    Iterable l = czAll.where((r) => true);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // 收银员/服务员锁定当天（与订单一致）
    final eff = canSeeAll ? timeTab : 0;
    String dayOf(dynamic t) { final s = '$t'; return s.length >= 10 ? s.substring(0, 10) : s; }
    switch (eff) {
      case 0:
        final s = _day(now);
        l = l.where((r) => dayOf(r['pay_time']) == s);
        break;
      case 1:
        final s = _day(today.subtract(const Duration(days: 1)));
        l = l.where((r) => dayOf(r['pay_time']) == s);
        break;
      case 2: // 本周（本周一 ~ 今天，按 pay_time）
        final thisMonday = today.subtract(Duration(days: now.weekday - 1));
        final ss = _day(thisMonday);
        l = l.where((r) => dayOf(r['pay_time']).compareTo(ss) >= 0);
        break;
      case 3: // 上周（上一个自然周 周一 ~ 周日）
        final thisMonday = today.subtract(Duration(days: now.weekday - 1));
        final ss = _day(thisMonday.subtract(const Duration(days: 7)));
        final ee = _day(thisMonday.subtract(const Duration(days: 1)));
        l = l.where((r) {
          final dd = dayOf(r['pay_time']);
          return dd.compareTo(ss) >= 0 && dd.compareTo(ee) <= 0;
        });
        break;
    }
    final k = kw.trim().toLowerCase();
    if (k.isNotEmpty) {
      l = l.where((r) {
        final sn = '${r['order_sn'] ?? ''}'.toLowerCase();
        final nm = '${r['vip_name'] ?? ''}'.toLowerCase();
        final ph = '${r['phone'] ?? ''}';
        final amt = Fmt.money(r['total']);
        return sn.contains(k) || nm.contains(k) || ph.contains(k) || amt.contains(k);
      });
    }
    return l.toList();
  }

  /// 切换页签时清空选中，避免上一页签的行数据被下一页签的面板误用
  void _switchTab(int v) {
    setState(() { tab = v; selected = null; kw = ''; kwCtrl.clear(); kbOpen = false; });
    _load();
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
                      _seg('店内订单', 0, tab, _switchTab),
                      const SizedBox(width: 8),
                      _seg('小程序订单', 1, tab, _switchTab),
                      const SizedBox(width: 8),
                      _seg('充值订单', 2, tab, _switchTab),
                      const Spacer(),
                      // 收银员/服务员只显示「今天」档并锁定（v3.3.214）
                      if (canSeeAll) ...[
                        _timeSeg('今天', 0),
                        const SizedBox(width: 6),
                        _timeSeg('昨天', 1),
                        const SizedBox(width: 6),
                        _timeSeg('本周', 2),
                        const SizedBox(width: 6),
                        _timeSeg('上周', 3),
                      ] else
                        const Text('收银员仅可查看当天订单',
                            style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
                    ]),
                  ),
                  // 搜索行（v3.3.216）：订单号 / 支付方式 / 金额；右侧数字键盘开关（v3.3.276b）
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                    child: Row(children: [
                      Expanded(
                        child: PosField(
                          controller: kwCtrl,
                          compact: true,
                          cleanScan: true, // 支持扫码枪扫订单号搜索
                          hint: '搜索订单号 / 支付方式 / 金额',
                          icon: Icons.search,
                          onChanged: (v) => setState(() { kw = v; _ensureSelected(); }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _kbBtn(),
                    ]),
                  ),
                  const Divider(height: 14, color: PosTheme.line),
                  // 列表表头：与单行布局对齐（订单号 / 时间 / 支付方式 / 金额）
                  _listHeader(),                  Expanded(
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
            // ---------- 右卡：订单详情 / 充值单详情 ----------
            Expanded(
              flex: 5,
              child: selected == null
                  ? AppCard(child: EmptyView(loading ? '加载中…' : '选择${tab == 2 ? '充值单' : '订单'}查看详情'))
                  : tab == 2
                      ? _czPanel()
                      : OrderDetailPanel(
                          key: ValueKey('${selected!['id']}'),
                          order: selected!,
                          onRefunded: _load,
                          // v3.3.276b：店内订单退款时限与充值口径一致（扫码仅当天 / 现金·会员余额 7 天）；小程序订单不限制
                          alignRecharge: tab == 0,
                        ),
            ),
          ]),
        ),
      ),
      // 搜索虚拟键盘（v3.3.276b）：会员管理同款 TouchKeyboard，展开时贴页面底部
      if (kbOpen)
        TouchKeyboard(
          hintText: kwCtrl.text.isEmpty
              ? '输入订单号 / 金额搜索'
              : '已输入「${kwCtrl.text}」· 匹配 ${f.length} 单',
          onInput: _kbInput,
          onBackspace: _kbBackspace,
          onClear: _kbClear,
          onClose: () => setState(() => kbOpen = false),
        ),
    ]);
  }

  // ==================== 左侧列表行 ====================

  /// 表头（v3.3.216）：与单行布局对齐——圆点+单号 / 时间 / 支付方式 / 优惠 / 金额
  /// tab==2 充值订单：充值单号/会员 · 时间 · 支付方式 · 金额（无优惠列，v3.3.250）
  Widget _listHeader() {
    const segStyle = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textSub);
    final first = tab == 2 ? '充值单号 / 会员' : '订单号 / 状态';
    return Container(
      padding: const EdgeInsets.fromLTRB(26, 6, 26, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F8FA),
        border: Border(bottom: BorderSide(color: PosTheme.line)),
      ),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Text(first, style: segStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
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
        if (tab != 2) ...[
          const SizedBox(width: 10),
          const SizedBox(
            width: 76,
            child: Text('优惠', textAlign: TextAlign.right, style: segStyle),
          ),
        ],
        const SizedBox(width: 10),
        SizedBox(
          width: 88,
          child: Text('金额', textAlign: TextAlign.right, style: segStyle),
        ),
      ]),
    );
  }

  /// 支付方式显示（v3.3.260）：组合支付单把 _2/_3 一并显示（微信支付+现金+会员支付）
  String _payMethods(Map o) {
    final parts = <String>['${o['payment_method'] ?? ''}'];
    for (final k2 in ['payment_method_2', 'payment_method_3']) {
      final m = '${o[k2] ?? ''}';
      if (m.isNotEmpty && m != 'null') parts.add(m);
    }
    final out = parts.where((p) => p.isNotEmpty && p != 'null').toList();
    return out.isEmpty ? '其他支付' : out.join('+');
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
    if (tab == 2) return _czRow(o);
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
              seg(2, st.isEmpty ? _payMethods(o) : '$st · ${_payMethods(o)}',
                  TextStyle(
                      fontSize: 13,
                      color: st.isEmpty ? PosTheme.textSub : (st == '未支付' ? PosTheme.amber : PosTheme.red))),
              // 整单折扣/改价徽标已移除（v3.3.268）：右侧详情已有「※ 整单折扣 8折 -¥3.20」，左侧不再重复
              // 优惠列（v3.3.250）：preferential_amount = 商品合计 − 实收（活动/券/整单折扣/抹零全含）
              // v3.3.269：整单折扣/改价的订单直接显示这笔优惠金额（preferential_amount 未落时兜底）
              if (tab != 2) ...[
                const SizedBox(width: 10),
                SizedBox(
                  width: 76,
                  child: Builder(builder: (_) {
                    final whole = double.tryParse('${o['whole_discount_amount'] ?? 0}') ?? 0;
                    final pref = whole > 0.001
                        ? whole
                        : (double.tryParse('${o['preferential_amount'] ?? 0}') ??
                            ((double.tryParse('${o['original_total'] ?? 0}') ?? 0) -
                                (double.tryParse('${o['total'] ?? 0}') ?? 0)));
                    final has = pref > 0.001 && '${o['payment_status']}' == '1';
                    return Text(has ? '-¥${Fmt.money(pref)}' : '—',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: has ? Colors.green : PosTheme.textHint));
                  }),
                ),
              ],
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

  // ==================== 充值订单（tab==2，v3.3.218） ====================

  static String _czPayText(Map r) {
    final scan = '${r['pay_type'] ?? ''}' != 'cash';
    final refunded = int.tryParse('${r['pay_status']}') == 2;
    return refunded ? (scan ? '已退款 · 扫码' : '已退款 · 现金') : (scan ? '扫码支付' : '现金');
  }

  /// 充值流水行：单号+会员 / 时间 / 支付方式 / 金额（等分省略号）
  Widget _czRow(Map r) {
    final on = selected != null && '${selected!['id']}' == '${r['id']}';
    final refunded = int.tryParse('${r['pay_status']}') == 2;
    final t = Fmt.date(r['pay_time']);
    final time = t.length >= 16 ? t.substring(5, 16) : t;
    final member = '${r['vip_name'] ?? ''}'.trim().isEmpty
        ? '${r['phone'] ?? ''}'
        : '${r['vip_name']} ${r['phone'] ?? ''}';
    Widget seg(int flex, String text, TextStyle style, {bool right = false}) => Expanded(
          flex: flex,
          child: Text(text,
              textAlign: right ? TextAlign.right : TextAlign.left,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: on ? const Color(0xFFFFF2ED) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => selected = r),
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
              // 状态圆点：绿=有效，红=已退款
              Container(
                width: 9, height: 9,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                    color: refunded ? PosTheme.red : const Color(0xFF34A853),
                    shape: BoxShape.circle),
              ),
              seg(3, '${r['order_sn'] ?? ''} · $member',
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              seg(2, time, const TextStyle(fontSize: 13, color: PosTheme.textSub)),
              const SizedBox(width: 10),
              seg(2, _czPayText(r), TextStyle(
                  fontSize: 13,
                  color: refunded ? PosTheme.red : PosTheme.textSub)),
              const SizedBox(width: 10),
              SizedBox(
                width: 88,
                child: Text('¥${Fmt.money(r['total'])}',
                    textAlign: TextAlign.right,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800,
                        color: refunded ? PosTheme.textHint : PosTheme.accent)),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// 充值单详情面板：会员信息 + 金额 + 补打充值小票 / 充值退款（权限码）
  Widget _czPanel() {
    final r = selected!;
    final refunded = int.tryParse('${r['pay_status']}') == 2;
    final scan = '${r['pay_type'] ?? ''}' != 'cash';
    final amount = double.tryParse('${r['czamount']}') ?? 0;
    final gift = double.tryParse('${r['zengsong']}') ?? 0;
    final canRefund = !refunded && (r['can_refund'] == true || '${r['can_refund']}' == '1' || '${r['can_refund']}' == 'true');
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 52, height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: PosTheme.accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              ('${r['vip_name'] ?? ''}'.trim().isNotEmpty
                      ? '${r['vip_name']}'.trim()
                      : '${r['phone'] ?? ''}'.trim())
                  .characters
                  .first,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: PosTheme.accent)),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r['vip_name'] ?? ''}'.trim().isEmpty ? '会员 ${r['phone'] ?? ''}' : '${r['vip_name']}',
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('${r['phone'] ?? ''}　${refunded ? '已退款' : '充值成功'}',
                style: TextStyle(fontSize: 13.5, color: refunded ? PosTheme.red : PosTheme.textSub)),
          ])),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: _czKv('充值金额', '¥${Fmt.money(amount)}', PosTheme.accent)),
          const SizedBox(width: 12),
          Expanded(child: _czKv('赠送金额', '¥${Fmt.money(gift)}', PosTheme.green)),
        ]),
        const SizedBox(height: 12),
        _czKv('合计入账', '¥${Fmt.money(r['total'])}', const Color(0xFF7C3AED)),
        const SizedBox(height: 12),
        _infoLine('支付方式', scan ? '扫码支付（星驿付原路）' : '现金'),
        _infoLine('充值单号', '${r['order_sn'] ?? ''}'),
        _infoLine('充值时间', '${Fmt.date(r['pay_time'])}'),
        if ('${r['operator_name'] ?? ''}'.isNotEmpty) _infoLine('操作员', '${r['operator_name']}'),
        if (refunded && '${r['refund_time'] ?? ''}'.isNotEmpty)
          _infoLine('退款时间', '${Fmt.date(r['refund_time'])}'),
        const Spacer(),
        BigButton('补打充值小票', onTap: () => _reprintCz(r), height: 50),
        if (canRefund) ...[
          const SizedBox(height: 10),
          BigButton('充值退款 ¥${Fmt.money(r['total'])}', onTap: () => _czRefund(r),
              color: PosTheme.red, height: 50),
        ] else if (!refunded && '${r['cannot_reason'] ?? ''}'.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('该笔暂不支持退款：${r['cannot_reason']}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
        ],
      ]),
    );
  }

  Widget _czKv(String k, String v, Color c) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [c.withOpacity(0.12), c.withOpacity(0.04)]),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withOpacity(0.18)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
        const SizedBox(height: 4),
        Text(v, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c)),
      ]),
    );
  }

  Widget _infoLine(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(width: 76, child: Text(k, style: const TextStyle(fontSize: 13, color: PosTheme.textSub))),
        const SizedBox(width: 8),
        Expanded(child: Text(v, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  /// 补打充值小票（USB/蓝牙优先，无本地打印机自动走云打印）
  Future<void> _reprintCz(Map r) async {
    final scan = '${r['pay_type'] ?? ''}' != 'cash';
    await CloudPrinter.print(CloudPrinter.vipRechargeTicket(
      vipName: '${r['vip_name'] ?? ''}',
      phone: '${r['phone'] ?? ''}',
      orderSn: '${r['order_sn'] ?? ''}',
      amount: double.tryParse('${r['czamount']}') ?? 0,
      gift: double.tryParse('${r['zengsong']}') ?? 0,
      payMethod: scan ? '扫码支付' : '现金',
    ));
    if (mounted) toast(context, '小票已送打印');
  }

  /// 充值退款（v3.3.218）：退款原因 + 权限码（后端 chongzhikaRefund 校验）；
  /// 现金退余额扣回，扫码走星驿付原路退回
  Future<void> _czRefund(Map r) async {
    final res = await showDialog<Map>(
      context: context,
      builder: (_) => _CzRefundDialog(
        sn: '${r['order_sn'] ?? ''}',
        amount: double.tryParse('${r['total']}') ?? 0,
        scan: '${r['pay_type'] ?? ''}' != 'cash',
      ),
    );
    if (res == null || !mounted) return;
    loadingDialog(context, '退款中…');
    try {
      final r2 = await Api.chongzhikaRefund(
        wenxunId: Session.wenxunId,
        id: int.tryParse('${r['id']}') ?? 0,
        operatorId: Session.staffId,
        password: '${res['password'] ?? ''}',
        reason: '${res['reason'] ?? ''}',
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r2['code']}' == '200') {
        toast(context, '充值退款成功');
        if (await PrintPrefs.on('vipcz')) {
          CloudPrinter.print(CloudPrinter.vipRechargeTicket(
            vipName: '${r['vip_name'] ?? ''}',
            phone: '${r['phone'] ?? ''}',
            orderSn: '${r['order_sn'] ?? ''}',
            amount: double.tryParse('${r['czamount']}') ?? 0,
            gift: double.tryParse('${r['zengsong']}') ?? 0,
            payMethod: '${r['pay_type'] ?? ''}' != 'cash' ? '扫码支付' : '现金',
            refund: true,
            reason: '${res['reason'] ?? ''}',
          )).catchError((_) => <String, dynamic>{});
        }
        _load();
      } else {
        toast(context, '${r2['msg'] ?? '退款失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, '退款失败：$e', error: true);
    }
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

  // ==================== 搜索虚拟键盘（v3.3.276b，会员管理同款 TouchKeyboard） ====================
  /// 键盘写入：统一走 kwCtrl，保持光标在末尾并同步过滤
  void _kbWrite(String text) {
    kwCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() { kw = text; _ensureSelected(); });
  }

  void _kbInput(String ch) => _kbWrite(kwCtrl.text + ch);

  void _kbBackspace() {
    final t = kwCtrl.text;
    if (t.isNotEmpty) _kbWrite(t.substring(0, t.length - 1));
  }

  void _kbClear() => _kbWrite('');

  /// 键盘开合按钮（同点餐弹窗/会员管理样式 44×44）
  Widget _kbBtn() {
    return SizedBox(
      width: 44, height: 44,
      child: Material(
        color: kbOpen ? PosTheme.accentLive : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: kbOpen ? Colors.transparent : PosTheme.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => kbOpen = !kbOpen),
          child: Icon(Icons.keyboard_alt_outlined,
              size: 22, color: kbOpen ? Colors.white : PosTheme.textSub),
        ),
      ),
    );
  }
}

// ==================== 充值退款弹窗（v3.3.218） ====================
/// 退款原因（触屏大按钮）+ 6 位权限码数字键盘；提交后由后端
/// shouyin/vip/chongzhikaRefund 校验权限码（wx_renyuan.quanxian_password）
class _CzRefundDialog extends StatefulWidget {
  final String sn;
  final double amount;
  final bool scan; // true=扫码充值（原路退回），false=现金
  const _CzRefundDialog({required this.sn, required this.amount, required this.scan});
  @override
  State<_CzRefundDialog> createState() => _CzRefundDialogState();
}

class _CzRefundDialogState extends State<_CzRefundDialog> {
  static const List<String> _reasons = ['反结账', '顾客退款', '其他'];
  String reason = '';
  String pwd = '';

  void _key(String k) {
    setState(() {
      if (k == 'C') {
        pwd = '';
      } else if (k == '<') {
        if (pwd.isNotEmpty) pwd = pwd.substring(0, pwd.length - 1);
      } else if (pwd.length < 6) {
        pwd += k;
      }
    });
  }

  void _confirm() {
    if (reason.isEmpty) { toast(context, '请选择退款原因', error: true); return; }
    if (pwd.length != 6) { toast(context, '请输入6位数字权限密码（由商户在设置页分配）', error: true); return; }
    Navigator.pop(context, {'reason': reason, 'password': pwd});
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 480,
        padding: const EdgeInsets.all(22),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('充值退款', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${widget.scan ? '扫码充值，原路退回' : '现金充值，退回会员余额'} · ¥${Fmt.money(widget.amount)} · ${widget.sn}',
                  style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            InkWell(
              onTap: () => Navigator.pop(context),
              child: const Icon(Icons.close, size: 24, color: PosTheme.textHint),
            ),
          ]),
          const SizedBox(height: 14),
          // 退款原因
          Row(children: [
            const Text('退款原因', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
            const SizedBox(width: 10),
            Expanded(
              child: Row(children: [
                for (var i = 0; i < _reasons.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: _reasonChip(_reasons[i])),
                ],
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          // 权限码显示
          Container(
            height: 54,
            decoration: BoxDecoration(
              color: PosTheme.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: PosTheme.line),
            ),
            child: Row(children: [
              const SizedBox(width: 12),
              const Icon(Icons.lock_outline, size: 20, color: PosTheme.textHint),
              const SizedBox(width: 12),
              Expanded(
                child: pwd.isEmpty
                    ? const Text('请输入权限密码（6位数字，由商户分配）',
                        style: TextStyle(fontSize: 13, color: PosTheme.textHint))
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < 6; i++)
                            Container(
                              width: 13, height: 13,
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i < pwd.length ? PosTheme.accent : const Color(0xFFE7E9EE),
                              ),
                            ),
                        ],
                      ),
              ),
              const SizedBox(width: 12),
              if (pwd.isNotEmpty)
                InkWell(
                  onTap: () => _key('C'),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.backspace_outlined, size: 19, color: PosTheme.textSub),
                  ),
                ),
              const SizedBox(width: 6),
            ]),
          ),
          const SizedBox(height: 10),
          // 9 宫格数字键盘
          for (var row = 0; row < 4; row++)
            Padding(
              padding: EdgeInsets.only(bottom: row == 3 ? 0 : 8),
              child: Row(children: [
                for (var col = 0; col < 3; col++)
                  Expanded(child: _keyBtn(row, col)),
              ]),
            ),
          const SizedBox(height: 14),
          BigButton('确认退款 ¥${Fmt.money(widget.amount)}', onTap: _confirm,
              color: PosTheme.red, height: 52),
        ]),
      ),
    );
  }

  Widget _reasonChip(String text) {
    final on = reason == text;
    return InkWell(
      onTap: () => setState(() => reason = text),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFDEEEE) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? PosTheme.red.withOpacity(0.5) : PosTheme.line, width: on ? 1.5 : 1),
        ),
        child: Text(text, style: TextStyle(
            fontSize: 14, fontWeight: on ? FontWeight.w700 : FontWeight.w400,
            color: on ? PosTheme.red : PosTheme.textSub)),
      ),
    );
  }

  Widget _keyBtn(int row, int col) {
    String? label; VoidCallback? onTap;
    if (row < 3) {
      label = '${row * 3 + col + 1}';
      onTap = () => _key(label!);
    } else if (col == 0) {
      label = '清空';
      onTap = pwd.isEmpty ? null : () => _key('C');
    } else if (col == 1) {
      label = '0';
      onTap = () => _key('0');
    } else {
      label = '退格';
      onTap = pwd.isEmpty ? null : () => _key('<');
    }
    final dis = onTap == null;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        color: dis ? const Color(0xFFF2F3F7) : const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          splashColor: PosTheme.accent.withOpacity(0.10),
          child: Container(
            height: 52,
            alignment: Alignment.center,
            child: Text(label, style: TextStyle(
                fontSize: label.length > 1 ? 14 : 20,
                fontWeight: FontWeight.w700,
                color: dis ? PosTheme.textHint : (label == '清空' || label == '退格'
                    ? PosTheme.textSub : PosTheme.textMain))),
          ),
        ),
      ),
    );
  }
}
