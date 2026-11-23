import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/print_prefs.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/order_card.dart';
import '../../ui/widgets.dart';
import '../../ui/xyf_orphan_check.dart';

/// 餐饮版 · 订单页（v3.3.83 重构：右侧导航 + 左侧内容）
/// 开台订单（就餐中）/ 堂食订单（已结算，可退款）/ 小程序订单 / 退款订单 / 充值订单
class DiningOrdersPage extends StatefulWidget {
  const DiningOrdersPage({super.key});
  @override
  State<DiningOrdersPage> createState() => _DiningOrdersPageState();
}

class _DiningOrdersPageState extends State<DiningOrdersPage> {
  // 0 开台订单(就餐中) 1 堂食订单(已结算) 2 小程序订单 3 退款订单 4 充值订单
  int tab = 0;

  static const List<Map<String, Object>> _navDefs = [
    {'key': 0, 'icon': Icons.restaurant, 'label': '开台订单', 'desc': '就餐中'},
    {'key': 1, 'icon': Icons.receipt_long, 'label': '堂食订单', 'desc': '已结算'},
    {'key': 2, 'icon': Icons.smartphone, 'label': '小程序订单', 'desc': '线上订单'},
    {'key': 3, 'icon': Icons.assignment_return, 'label': '退款订单', 'desc': '退款记录'},
    {'key': 4, 'icon': Icons.savings_outlined, 'label': '充值订单', 'desc': '会员充值'},
  ];

  // 开台/堂食（wx_table_order 分页）
  List diningList = [];
  int page = 1;
  int pages = 1;
  bool loading = true;
  Map? diningSelected;

  // 小程序
  List xcxAll = []; // order_from=1 全量
  int xcxTimeTab = 0; // 0 今天 1 昨天 2 上周
  Map? xcxSelected;

  // 退款 / 充值
  List refundAll = [];
  List czAll = [];

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
    if (tab > 2) return; // 退款/充值各自加载
    setState(() => loading = true);
    try {
      if (tab <= 1) {
        final Map<String, dynamic> r;
        if (tab == 0) {
          // 开台订单：数据源是就餐中桌台（wx_zhuotai status=2），未结算的主订单表里没有
          r = await Api.diningKaitaiList(Session.wenxunId);
        } else {
          r = await Api.diningOrders(Session.wenxunId, page, 20, 1);
        }
        if (!mounted) return;
        final d = r['data'] ?? {};
        final list = (d['list'] ?? []) as List;
        setState(() {
          diningList = list;
          pages = int.tryParse('${d['pages']}') ?? 1;
          loading = false;
        });
        _ensureDiningSelected();
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

  /// 退款订单 / 充值订单懒加载（切到对应页签时拉取）
  Future<void> _loadTabData() async {
    if (tab == 3 && refundAll.isEmpty) _loadRefunds();
    if (tab == 4 && czAll.isEmpty) _loadChongzhi();
  }

  Future<void> _loadRefunds() async {
    setState(() => loading = true);
    try {
      final l = await Api.refundList(Session.wenxunId);
      if (!mounted) return;
      setState(() { refundAll = l; loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      toast(context, e.message, error: true);
    }
  }

  Future<void> _loadChongzhi() async {
    setState(() => loading = true);
    try {
      final l = await Api.chongzhikaList(Session.wenxunId);
      if (!mounted) return;
      setState(() { czAll = l; loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      toast(context, e.message, error: true);
    }
  }

  void _switchTab(int v) {
    if (tab == v) return;
    setState(() { tab = v; loading = true; page = 1; diningSelected = null; });
    if (v <= 2) {
      _load();
    } else {
      setState(() => loading = false);
      _loadTabData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader('订单管理'),
      Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ===== 左侧内容 =====
        Expanded(child: _content()),
        const SizedBox(width: 16),
        // ===== 右侧导航菜单 =====
        Container(
          width: 168,
          margin: const EdgeInsets.fromLTRB(0, 0, 20, 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: PosTheme.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text('订单分类', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: PosTheme.textMain)),
            ),
            Expanded(child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              children: _navDefs.map((n) {
                final v = n['key'] as int;
                final sel = tab == v;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Material(
                    color: sel ? PosTheme.accent.withOpacity(0.1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _switchTab(v),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                        child: Row(children: [
                          Icon(n['icon'] as IconData, size: 18, color: sel ? PosTheme.accent : PosTheme.textSub),
                          const SizedBox(width: 8),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${n['label']}',
                                style: TextStyle(fontSize: 13, fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                                    color: sel ? PosTheme.accent : PosTheme.textMain)),
                            Text('${n['desc']}',
                                style: TextStyle(fontSize: 10.5, color: sel ? PosTheme.accent.withOpacity(0.7) : PosTheme.textHint)),
                          ])),
                        ]),
                      ),
                    ),
                  ),
                );
              }).toList(),
            )),
          ]),
        ),
      ])),
    ]);
  }

  Widget _content() {
    switch (tab) {
      case 2: return _xcxBody();
      case 3: return _refundBody();
      case 4: return _chongzhiBody();
      case 0:
      case 1:
      default: return _tableBody(tab == 0 ? 0 : 1);
    }
  }

  // ==================== 开台订单 / 堂食订单（主从布局） ====================

  void _ensureDiningSelected() {
    if (diningList.isEmpty) { diningSelected = null; return; }
    final curId = diningSelected == null ? '' : '${diningSelected!['id']}';
    if (!diningList.any((o) => '${o['id']}' == curId)) diningSelected = diningList.first as Map;
  }

  Widget _tableBody(int status) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 0, 24),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ---------- 左卡：订单列表 ----------
        Expanded(flex: 6, child: AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: Row(children: [
                Text(status == 0 ? '开台订单（就餐中）' : '堂食订单（已结算）',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('共 ${diningList.length} 单', style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
              ]),
            ),
            const Divider(height: 1, color: PosTheme.line),
            Expanded(child: loading
                ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                : diningList.isEmpty
                    ? EmptyView(status == 0 ? '暂无就餐中的订单' : '暂无已结算订单')
                    : RefreshIndicator(
                        onRefresh: _load,
                        color: PosTheme.accent,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          itemCount: diningList.length,
                          itemBuilder: (_, i) => _tableRow(diningList[i]),
                        ),
                      )),
            if (diningList.isNotEmpty) ...[
            const Divider(height: 1, color: PosTheme.line),
            if (status == 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton.outlined(
                      onPressed: page > 1 ? () { setState(() { page--; diningSelected = null; }); _load(); } : null,
                      icon: const Icon(Icons.chevron_left, size: 20)),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('$page / $pages 页', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  IconButton.outlined(
                      onPressed: page < pages ? () { setState(() { page++; diningSelected = null; }); _load(); } : null,
                      icon: const Icon(Icons.chevron_right, size: 20)),
                ]),
              ),
            ],
          ]),
        )),
        const SizedBox(width: 16),
        // ---------- 右卡：订单详情 ----------
        Expanded(flex: 5, child: diningSelected == null
            ? AppCard(child: EmptyView(loading ? '加载中…' : '选择订单查看详情'))
            : _tableDetailPanel(diningSelected!)),
      ]),
    );
  }

  Widget _tableRow(Map o) {
    final on = diningSelected != null && '${diningSelected!['id']}' == '${o['id']}';
    final refundTotal = double.tryParse('${o['refund_total']}') ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => diningSelected = o),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFFF2ED) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text('${o['table_title'] ?? ''} · ${o['people_num'] ?? '-'}人',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              // 挂账未核销：实心红标签（醒目），其余走普通状态标签
              if (_gzPending(o))
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: PosTheme.red, borderRadius: BorderRadius.circular(6)),
                  child: const Text('未结算 · 挂账未核销',
                      style: TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w700)),
                )
              else
                TagChip(_statusText(o), color: _statusColor(o)),
              if (refundTotal > 0) ...[
                const SizedBox(width: 6),
                const TagChip('有退款', color: PosTheme.red),
              ],
            ]),
            const SizedBox(height: 3),
            Text(_tableSubTitle(o),
                style: const TextStyle(fontSize: 12, color: PosTheme.textSub),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
          const SizedBox(width: 8),
          Text('¥${Fmt.money(o['final_total'] ?? o['goods_total'] ?? 0)}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.accent)),
        ]),
      ),
    );
  }

  /// 挂账未核销（v3.3.157）：后端 guazhang_status=0 未结 / 1 已结 / -1 未挂账
  bool _gzPending(Map o) => int.tryParse('${o['guazhang_status']}') == 0;

  /// 状态文案：挂账未核销 → 未结算（醒目）；核销后 → 已结算
  String _statusText(Map o) =>
      _gzPending(o) ? '未结算·挂账' : '${o['status_text'] ?? ''}';

  Color _statusColor(Map o) => _gzPending(o)
      ? PosTheme.red
      : ({0: PosTheme.accent, 1: PosTheme.green, 3: PosTheme.textHint}[int.tryParse('${o['order_status']}')] ??
          PosTheme.textHint);

  /// 列表副标题：就餐中显示「未结算 · 开台时间 · N项」；已结算显示单号+支付方式
  String _tableSubTitle(Map o) {
    final parts = <String>[
      '${o['order_sn'] ?? ''}'.isEmpty ? '未结算' : '${o['order_sn']}',
      Fmt.date(o['create_time']),
      '${_mergedGoods(((o['goods_list'] ?? []) as List)).length} 项',
    ];
    final pay = '${o['pay1_type'] ?? ''}';
    if (pay.isNotEmpty && pay != 'null') parts.add(pay);
    // 挂账订单显示挂账人（v3.3.156）
    final gzName = '${o['guazhang_name'] ?? ''}'.trim();
    if (gzName.isNotEmpty) parts.add('挂账:$gzName');
    return parts.join(' · ');
  }

  /// 同名同价菜品合并显示（加菜每份一条明细，逐行显示会重复）
  List<Map<String, dynamic>> _mergedGoods(List goods) {
    final list = <Map<String, dynamic>>[];
    final idx = <String, int>{};
    for (final raw in goods) {
      final g = Map<String, dynamic>.from(raw as Map);
      final key = '${g['goods_title']}|${g['unit_price']}|${g['remark'] ?? ''}';
      if (idx.containsKey(key)) {
        final m = list[idx[key]!];
        m['quantity'] = (double.tryParse('${m['quantity']}') ?? 0) +
            (double.tryParse('${g['quantity']}') ?? 0);
        m['sub_total'] = (double.tryParse('${m['sub_total']}') ?? 0) +
            (double.tryParse('${g['sub_total']}') ?? 0);
      } else {
        idx[key] = list.length;
        list.add(g);
      }
    }
    return list;
  }

  String _qtyFmt(num v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  Widget _tableDetailPanel(Map o) {
    final goods = (o['goods_list'] ?? []) as List;
    final total = double.tryParse('${o['final_total'] ?? o['goods_total'] ?? 0}') ?? 0;
    final refunded = double.tryParse('${o['refund_total']}') ?? 0;
    final refundable = double.tryParse('${o['final_total'] ?? 0}') ?? 0;
    final canRefund = (refundable - refunded) > 0 &&
        '${o['order_status']}' == '1' && '${o['payment_status']}' == '1';
    return AppCard(
      key: ValueKey('dining_${o['id']}'),
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // 头部
        Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          decoration: const BoxDecoration(
            color: Color(0xFFFBFBFC),
            borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
            border: Border(bottom: BorderSide(color: PosTheme.line)),
          ),
          child: Row(children: [
            const Icon(Icons.receipt_long, size: 19, color: PosTheme.accent),
            const SizedBox(width: 8),
            Expanded(child: Text('${'${o['order_status']}' == '0' ? '就餐中' : '堂食订单'} · ${o['table_title'] ?? ''}',
                style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700))),
            if (_gzPending(o))
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: PosTheme.red, borderRadius: BorderRadius.circular(6)),
                child: const Text('未结算 · 挂账未核销',
                    style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
              )
            else
              TagChip(_statusText(o), color: _statusColor(o)),
          ]),
        ),
        Expanded(child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
          children: [
            _kvRow('${o['order_status']}' == '0' ? '开台流水' : '单号',
                '${o['order_sn'] ?? ''}'.isEmpty ? '${o['kaitai_id'] ?? '-'}' : '${o['order_sn']}'),
            _kvRow('开台时间', Fmt.date(o['create_time'])),
            _kvRow('用餐人数', '${o['people_num'] ?? '-'} 人'),
            _kvRow('收银员', '${o['operator_name'] ?? '-'}'),
            if ('${o['pay1_type'] ?? ''}'.isNotEmpty && '${o['pay1_type']}' != 'null')
              _kvRow('支付方式', '${o['pay1_type']}'),
            // 挂账订单显示挂账人姓名/电话（v3.3.156）
            if ('${o['guazhang_name'] ?? ''}'.trim().isNotEmpty) ...[
              _kvRow('挂账人', '${o['guazhang_name']}'),
              if ('${o['guazhang_phone'] ?? ''}'.trim().isNotEmpty)
                _kvRow('挂账电话', '${o['guazhang_phone']}'),
              // 核销状态醒目显示（v3.3.157）
              if (_gzPending(o))
                _kvRow('挂账状态', '未核销 · 待收款', valueColor: PosTheme.red)
              else
                _kvRow('挂账状态', '已核销', valueColor: PosTheme.green),
            ],
            if (refunded > 0) _kvRow('已退款', '¥${Fmt.money(refunded)}', valueColor: PosTheme.red),
            const SizedBox(height: 8),
            const Divider(height: 1, color: PosTheme.line),
            const SizedBox(height: 6),
            ..._mergedGoods(goods).map((g) {
              final qty = double.tryParse('${g['quantity']}') ?? 0;
              return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Expanded(child: Text('${g['goods_title']}',
                    style: const TextStyle(fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis)),
                Text('¥${Fmt.money(g['unit_price'])} ×${_qtyFmt(qty)}',
                    style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
                const SizedBox(width: 12),
                SizedBox(width: 64, child: Text('¥${Fmt.money(g['sub_total'])}',
                    textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
            );
            }),
            const Divider(height: 14, color: PosTheme.line),
            // ===== 费用明细（菜品 + 附加费 + 优惠）=====
            ..._feeRows(o),
            const Divider(height: 14, color: PosTheme.line),
            Row(children: [
              Text(
                  _gzPending(o)
                      ? '挂账待收'
                      : ('${o['order_status']}' == '0' ? '消费金额' : '实收'),
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: _gzPending(o) ? PosTheme.red : null)),
              const Spacer(),
              Text('¥${Fmt.money(total)}',
                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: PosTheme.accent)),
            ]),
            if (refunded > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  const Text('累计退款', style: TextStyle(fontSize: 12.5, color: PosTheme.red)),
                  const Spacer(),
                  Text('-¥${Fmt.money(refunded)}',
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: PosTheme.red)),
                ]),
              ),
          ],
        )),
        // 底部操作：已结算单可补打小票；可退单再显示申请退款
        if ('${o['order_status']}' == '1')
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
            decoration: const BoxDecoration(
              color: Color(0xFFFBFBFC),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
              border: Border(top: BorderSide(color: PosTheme.line)),
            ),
            child: Row(children: [
              if (canRefund)
                Text('剩余可退 ¥${Fmt.money(refundable - refunded)}',
                    style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () => _reprintDining(o),
                style: OutlinedButton.styleFrom(
                  foregroundColor: PosTheme.blue,
                  side: const BorderSide(color: PosTheme.blue),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                icon: const Icon(Icons.print_outlined, size: 17),
                label: const Text('补打小票', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              ),
              if (canRefund) ...[
                const SizedBox(width: 12),
                SizedBox(width: 130, child: BigButton('申请退款', onTap: () => _tableRefund(o),
                    color: PosTheme.red, height: 44)),
              ],
            ]),
          ),
      ]),
    );
  }

  /// 费用明细行：菜品小计 + 附加费（开台/茶位/服务/餐盒）+ 优惠（折扣/手动/抹零/积分）
  List<Widget> _feeRows(Map o) {
    double f(String k) => double.tryParse('${o[k] ?? 0}') ?? 0;
    final hasGoods = ((o['goods_list'] ?? []) as List).isNotEmpty;

    final fees = <MapEntry<String, double>>[
      MapEntry('开台费', f('kaitai_fee')),
      MapEntry('茶位费', f('tea_fee')),
      MapEntry('服务费', f('service_fee')),
      MapEntry('餐盒费', f('box_fee')),
    ].where((e) => e.value > 0).toList();

    final prefers = <MapEntry<String, double>>[
      MapEntry('整单优惠', f('discount_amount')),
      MapEntry('会员优惠', f('vip_reduce')),
      MapEntry('手动优惠', f('manual_prefer')),
      MapEntry('抹零', f('quiling')),
      if ((int.tryParse('${o['jifen_num'] ?? 0}') ?? 0) > 0)
        MapEntry('积分抵扣（${o['jifen_num']}分）', f('jifen_deduct')),
    ].where((e) => e.value > 0).toList();

    final rows = <Widget>[];
    if (hasGoods) {
      rows.add(_feeRow('菜品小计', f('goods_total')));
    }
    if (fees.isNotEmpty) {
      for (final e in fees) {
        rows.add(_feeRow(e.key, e.value));
      }
    }
    if (prefers.isNotEmpty) {
      for (final e in prefers) {
        rows.add(_feeRow(e.key, -e.value, color: PosTheme.green));
      }
    }
    return rows;
  }

  Widget _feeRow(String label, double amount, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(children: [
        Text(label, style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
        const Spacer(),
        Text('${amount < 0 ? '-' : ''}¥${Fmt.money(amount.abs())}',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color ?? PosTheme.textMain)),
      ]),
    );
  }

  Widget _kvRow(String k, String v, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 72, child: Text(k, style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint))),
        Expanded(child: Text(v, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: valueColor ?? PosTheme.textMain))),
      ]),
    );
  }

  /// 补打堂食小票（v3.3.87）：USB 直连优先，云打印默认前台收银小票机
  Future<void> _reprintDining(Map o) async {
    if (!await PrintPrefs.on('reorder')) {
      toast(context, '订单补打小票已关闭（设置 → 小票打印设置）');
      return;
    }
    loadingDialog(context, '发送补打小票…');
    try {
      await CloudPrinter.printReorder(CloudPrinter.diningReprintTicket(o));
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '补打小票已发送');
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, '打印失败：$e', error: true);
    }
  }

  /// 堂食订单退款弹窗：金额（默认整单）+ 原因 + 权限密码
  Future<void> _tableRefund(Map o) async {
    final total = double.tryParse('${o['final_total'] ?? 0}') ?? 0;
    final refunded = double.tryParse('${o['refund_total']}') ?? 0;
    final refundable = double.parse((total - refunded).toStringAsFixed(2));
    final amtCtl = TextEditingController(text: refundable.toStringAsFixed(2));
    final reasonCtl = TextEditingController();
    final pwdCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('堂食订单退款 · ${o['table_title'] ?? ''}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('单号 ${o['order_sn'] ?? '-'} · 实收 ¥${Fmt.money(total)}${refunded > 0 ? ' · 已退 ¥${Fmt.money(refunded)}' : ''}',
              style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
          const SizedBox(height: 14),
          PosField(
            controller: amtCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            label: '退款金额（不填=整单退 ¥${Fmt.money(refundable)}）',
            compact: true,
          ),
          const SizedBox(height: 12),
          PosField(
            controller: reasonCtl,
            maxLines: 2,
            label: '退款原因',
            compact: true,
          ),
          const SizedBox(height: 12),
          PosField(
            controller: pwdCtl,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            label: '权限密码（6位数字）',
            icon: Icons.lock_outline,
            compact: true,
          ),
          const SizedBox(height: 8),
          const Text('会员余额支付原路退回余额；现金/扫码登记退款线下原路退回。', style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: PosTheme.red),
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('确认退款'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final amount = double.tryParse(amtCtl.text.trim()) ?? 0;
    final reason = reasonCtl.text.trim();
    final pwd = pwdCtl.text.trim();
    if (reason.isEmpty) { toast(context, '请填写退款原因', error: true); return; }
    if (pwd.length != 6 || int.tryParse(pwd) == null) { toast(context, '权限密码须为6位数字', error: true); return; }
    if (amount > refundable) { toast(context, '退款金额超出剩余可退金额', error: true); return; }
    loadingDialog(context, '退款中…');
    try {
      final r = await Api.diningOrderRefund(
        wenxunId: Session.wenxunId,
        orderId: int.tryParse('${o['id']}') ?? 0,
        reason: reason,
        password: pwd,
        amount: amount,
      );
      if (!mounted) return;
      if ('${r['code']}' == '200') {
        final msg = '${r['msg'] ?? '退款成功'}';
        // 「退款申请已受理」= 星驿付退款中：轮询终态（最长约 40 秒），防误报成功
        if (msg.contains('受理')) {
          final st = await Api.pollRefundStatus(
              dining: true, orderId: int.tryParse('${o['id']}') ?? 0);
          if (!mounted) return;
          Navigator.pop(context); // loading
          if (st == 'success') {
            toast(context, '退款成功，资金将原路退回');
          } else if (st == 'fail') {
            toast(context, '退款失败：渠道未完成退款，款项未退出', error: true);
          } else {
            toast(context, '退款处理中，资金将原路退回（1-3 个工作日到账）');
          }
        } else {
          Navigator.pop(context); // loading
          toast(context, msg);
        }
        refundAll = []; // 强制重拉退款列表
        _load();
      } else {
        Navigator.pop(context); // loading
        toast(context, '${r['msg'] ?? '退款失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, e.message, error: true);
    }
  }

  // ==================== 退款订单 ====================

  Widget _refundBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 0, 24),
      child: AppCard(padding: EdgeInsets.zero, child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Row(children: [
            const Text('退款订单', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton.icon(
              onPressed: _loadRefunds,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
            ),
          ]),
        ),
        const Divider(height: 1, color: PosTheme.line),
        Expanded(child: loading
            ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
            : refundAll.isEmpty
                ? const EmptyView('暂无退款记录')
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: refundAll.length,
                    itemBuilder: (_, i) => _refundRow(refundAll[i]),
                  )),
      ])),
    );
  }

  Widget _refundRow(Map r) {
    final st = int.tryParse('${r['status']}') ?? 1;
    final stColor = st == 2 ? PosTheme.green : (st == 1 ? PosTheme.amber : PosTheme.red);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(color: PosTheme.red.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.assignment_return, size: 19, color: PosTheme.red),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text('${r['order_number'] ?? ''}',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 6),
            TagChip('${r['status_text'] ?? ''}', color: stColor),
          ]),
          const SizedBox(height: 3),
          Text('${Fmt.date(r['create_time'])} · ${r['refund_reason'] ?? '-'}${'${r['operator_name'] ?? ''}'.isNotEmpty ? ' · ${r['operator_name']}' : ''}',
              style: const TextStyle(fontSize: 12, color: PosTheme.textSub),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        Text('-¥${Fmt.money(r['refund_amount'])}',
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: PosTheme.red)),
      ]),
    );
  }

  // ==================== 充值订单 ====================

  Widget _chongzhiBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 0, 24),
      child: AppCard(padding: EdgeInsets.zero, child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Row(children: [
            const Text('充值订单', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            const Flexible(
              child: Text('现金充值7天内可退 · 扫码充值仅当天可退',
                  style: TextStyle(fontSize: 11.5, color: PosTheme.textHint),
                  overflow: TextOverflow.ellipsis),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _loadChongzhi,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
            ),
          ]),
        ),
        const Divider(height: 1, color: PosTheme.line),
        Expanded(child: loading
            ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
            : czAll.isEmpty
                ? const EmptyView('暂无充值记录')
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: czAll.length,
                    itemBuilder: (_, i) => _chongzhiRow(czAll[i]),
                  )),
      ])),
    );
  }

  Widget _chongzhiRow(Map r) {
    final total = double.tryParse('${r['total']}') ?? (double.tryParse('${r['czamount']}') ?? 0);
    final gift = double.tryParse('${r['zengsong']}') ?? 0;
    final isScan = '${r['pay_type']}' == 'scan';
    final refunded = '${r['pay_status']}' == '2';
    final canRefund = r['can_refund'] == true;
    final why = '${r['cannot_reason'] ?? ''}';
    final vipName = '${r['vip_name'] ?? ''}';
    final phone = '${r['phone'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: (refunded ? PosTheme.textHint : PosTheme.green).withOpacity(0.1),
            borderRadius: BorderRadius.circular(10)),
          child: Icon(refunded ? Icons.undo : Icons.savings_outlined,
              size: 19, color: refunded ? PosTheme.textHint : PosTheme.green),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(vipName.isNotEmpty ? (phone.isNotEmpty ? '$vipName · $phone' : vipName) : (phone.isNotEmpty ? phone : '会员${r['vip_id']}'),
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 6),
            TagChip(isScan ? '扫码充值' : '现金充值', color: isScan ? PosTheme.blue : PosTheme.green),
            if (refunded) ...[
              const SizedBox(width: 6),
              TagChip('已退款', color: PosTheme.textHint),
            ],
          ]),
          const SizedBox(height: 3),
          Text('${r['order_sn'] ?? ''} · ${Fmt.date(r['pay_time'])}'
                  '${'${r['operator_name'] ?? ''}'.isNotEmpty ? ' · ${r['operator_name']}' : ''}',
              style: const TextStyle(fontSize: 12, color: PosTheme.textSub),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('+¥${Fmt.money(total)}',
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700,
                  color: refunded ? PosTheme.textHint : PosTheme.green)),
          if (gift > 0)
            Text('含赠送 ¥${Fmt.money(gift)}',
                style: const TextStyle(fontSize: 11, color: PosTheme.textHint)),
          const SizedBox(height: 5),
          if (refunded)
            Text('已退 ¥${Fmt.money(total)}', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint))
          else if (canRefund)
            InkWell(
              onTap: () => _refundChongzhi(r),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: PosTheme.red.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: PosTheme.red.withOpacity(0.4)),
                ),
                child: const Text('退款', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.red)),
              ),
            )
          else
            SizedBox(
              width: 150,
              child: Text(why, textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 11, color: PosTheme.textHint),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
        ]),
      ]),
    );
  }

  /// 充值退款：权限码确认 → 后端原路退（现金扣回余额 / 扫码星驿付原路）→ 打印退款充值小票
  Future<void> _refundChongzhi(Map r) async {
    final res = await showDialog<Map>(context: context, builder: (_) => _ChongzhiRefundDialog(record: r));
    if (res == null || !mounted) return;
    loadingDialog(context, '退款处理中…');
    try {
      final resp = await Api.chongzhikaRefund(
        wenxunId: Session.wenxunId,
        id: int.tryParse('${r['id']}') ?? 0,
        operatorId: Session.staffId,
        password: '${res['password'] ?? ''}',
        reason: '${res['reason'] ?? ''}',
      );
      if (!mounted) return;
      Navigator.pop(context); // loading
      if ('${resp['code']}' == '200') {
        toast(context, '退款成功，已扣回会员余额 ¥${Fmt.money(resp['data']?['total'] ?? 0)}');
        // 退款充值小票（USB 直连优先，无 USB 走云打印；商户可在小票打印设置关闭）
        if (await PrintPrefs.on('vipczrefund')) {
          final scanDone = '${(resp['data'] as Map?)?['scan_done']}' == 'true';
          CloudPrinter.print(CloudPrinter.vipRechargeTicket(
            vipName: '${r['vip_name'] ?? ''}',
            phone: '${r['phone'] ?? ''}',
            orderSn: '${(resp['data'] as Map?)?['order_sn'] ?? r['order_sn'] ?? ''}',
            amount: double.tryParse('${(resp['data'] as Map?)?['czamount'] ?? r['czamount']}') ?? 0,
            gift: double.tryParse('${(resp['data'] as Map?)?['zengsong'] ?? r['zengsong']}') ?? 0,
            payMethod: '${r['pay_type']}' == 'scan'
                ? (scanDone ? '扫码原路退回' : '扫码原路退款中')
                : '现金（线下退回）',
            balance: double.tryParse('${resp['balance'] ?? ''}'),
            refund: true,
            reason: '${res['reason'] ?? ''}',
          )).catchError((_) => <String, dynamic>{});
        }
        _loadChongzhi();
      } else {
        toast(context, '${resp['msg'] ?? '退款失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '退款失败：$e', error: true);
    }
  }

  // ==================== 小程序（主从布局） ====================

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
      padding: const EdgeInsets.fromLTRB(24, 0, 0, 24),
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
    final refundedAmt = double.tryParse('${o['refund_amount']}') ?? 0;
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
              if (refundSt == 0 && refundedAmt > 0) const TagChip('部分退款', color: PosTheme.red),
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

/// 充值退款确认弹窗（v3.3.174）：退款原因（触摸屏）+ 6位权限密码九宫格
class _ChongzhiRefundDialog extends StatefulWidget {
  final Map record;
  const _ChongzhiRefundDialog({required this.record});
  @override
  State<_ChongzhiRefundDialog> createState() => _ChongzhiRefundDialogState();
}

class _ChongzhiRefundDialogState extends State<_ChongzhiRefundDialog> {
  String reason = '顾客要求退款';
  String pwd = '';
  static const List<String> _reasons = ['顾客要求退款', '充值金额有误', '其他'];

  void _confirm() {
    if (pwd.length != 6) {
      toast(context, '请输入6位数字权限密码（由商户在设置页分配）', error: true);
      return;
    }
    Navigator.pop(context, {'reason': reason, 'password': pwd});
  }

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

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final total = double.tryParse('${r['total']}') ?? 0;
    final isScan = '${r['pay_type']}' == 'scan';
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('充值退款', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: PosTheme.red)),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${r['vip_name'] ?? r['phone'] ?? ''} · ${r['order_sn'] ?? ''}',
                  style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            InkWell(
              onTap: () => Navigator.pop(context),
              child: const Icon(Icons.close, size: 24, color: PosTheme.textHint),
            ),
          ]),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: PosTheme.bg, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('退款金额 ¥${Fmt.money(total)}',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: PosTheme.red)),
                const SizedBox(height: 3),
                Text(isScan ? '扫码支付将原路退回顾客账户' : '现金充值，线下退回并扣回会员余额',
                    style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
              ])),
            ]),
          ),
          const SizedBox(height: 14),
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
          const SizedBox(height: 14),
          // 权限密码显示框
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
                    : Row(children: [
                        for (var i = 0; i < 6; i++) ...[
                          if (i > 0) const SizedBox(width: 10),
                          Container(
                            width: 12, height: 12,
                            decoration: BoxDecoration(
                              color: i < pwd.length ? PosTheme.textMain : Colors.transparent,
                              shape: BoxShape.circle,
                              border: Border.all(color: PosTheme.textHint, width: 1.2),
                            ),
                          ),
                        ],
                      ]),
              ),
              const SizedBox(width: 12),
            ]),
          ),
          const SizedBox(height: 10),
          // 9宫格数字键盘
          Column(children: [
            for (final row in [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9'], ['C', '0', '<']])
              Row(children: [
                for (final k in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: InkWell(
                        onTap: () => _key(k),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: k == 'C' || k == '<' ? const Color(0xFFF7F8FA) : Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: PosTheme.line),
                          ),
                          child: Text(k == '<' ? '⌫' : k,
                              style: TextStyle(fontSize: k == 'C' ? 15 : 19,
                                  fontWeight: FontWeight.w600,
                                  color: k == 'C' ? PosTheme.red : PosTheme.textMain)),
                        ),
                      ),
                    ),
                  ),
              ]),
          ]),
          const SizedBox(height: 14),
          BigButton('确认退款 ¥${Fmt.money(total)}', onTap: _confirm, color: PosTheme.red, height: 52),
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
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFDEEEE) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? PosTheme.red.withOpacity(0.5) : PosTheme.line, width: on ? 1.5 : 1),
        ),
        child: Text(text, style: TextStyle(
          fontSize: 13, fontWeight: on ? FontWeight.w700 : FontWeight.w400,
          color: on ? PosTheme.red : PosTheme.textSub,
        ), maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
