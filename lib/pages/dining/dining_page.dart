import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';
import '../retail/cashier_page.dart' show RetailCashierPage;

/// 餐饮版 · 点餐主页（中餐 / 面馆 / 快餐通用）
/// 桌台模式：桌台图 → 开台 → 点菜/加菜 → 结账 → 云打印
/// 快捷模式：直接点单收款（外带/快餐），落 POS 订单
class DiningPage extends StatefulWidget {
  const DiningPage({super.key});
  @override
  State<DiningPage> createState() => _DiningPageState();
}

class _DiningPageState extends State<DiningPage> {
  int mode = 0; // 0 桌台模式 1 快捷模式
  List tables = [];
  bool loading = true;
  String? error;

  // 桌台状态：0空闲 1已预定 2就餐中 3扫码点餐 4已结账待清台
  static const statusText = {0: '空闲', 1: '已预定', 2: '就餐中', 3: '扫码点餐', 4: '待清台'};
  static const statusColor = {
    0: PosTheme.green, 1: PosTheme.amber, 2: PosTheme.accent, 3: PosTheme.blue, 4: PosTheme.textHint,
  };

  int get idleCount => tables.where((t) => '${t['status']}' == '0').length;
  int get busyCount => tables.where((t) => '${t['status']}' == '2' || '${t['status']}' == '3').length;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final r = await Api.tables(Session.wenxunId);
      if (!mounted) return;
      setState(() { tables = r; loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.message; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (mode == 1) {
      // 快捷模式：直接复用零售收银（点单→收款→POS 单）
      return Column(children: [
        _modeBar(),
        const Expanded(child: RetailCashierPage()),
      ]);
    }
    return Column(children: [
      _modeBar(),
      _statsBar(),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
            : error != null
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(error!, style: const TextStyle(color: PosTheme.red)),
                    const SizedBox(height: 12),
                    BigButton('重新加载', onTap: _load, width: 140, height: 42),
                  ]))
                : tables.isEmpty
                    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: const [
                        Icon(Icons.table_restaurant_outlined, size: 56, color: PosTheme.textHint),
                        SizedBox(height: 12),
                        Text('还没有添加桌台，请联系管理员在商户后台批量添加', style: TextStyle(color: PosTheme.textHint)),
                      ]))
                    : RefreshIndicator(
                        color: PosTheme.accent,
                        onRefresh: _load,
                        child: GridView.builder(
                          padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 190, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.25,
                          ),
                          itemCount: tables.length,
                          itemBuilder: (_, i) => _tableCard(tables[i]),
                        ),
                      ),
      ),
    ]);
  }

  Widget _modeBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(children: [
        const Text('点餐', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        const SizedBox(width: 20),
        _seg('桌台模式', 0),
        const SizedBox(width: 8),
        _seg('快捷模式（外带/快餐）', 1),
        const Spacer(),
        Text('中餐 · 面馆 · 快餐通用', style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500)),
      ]),
    );
  }

  Widget _seg(String text, int v) {
    final on = mode == v;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => mode = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Text(text, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  Widget _statsBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      child: Row(children: [
        _legend('空闲 $idleCount', PosTheme.green),
        const SizedBox(width: 12),
        _legend('就餐中 $busyCount', PosTheme.accent),
        const SizedBox(width: 12),
        _legend('已预定 ${tables.where((t) => '${t['status']}' == '1').length}', PosTheme.amber),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _load,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14), foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
          icon: const Icon(Icons.refresh, size: 17),
          label: const Text('刷新桌台'),
        ),
      ]),
    );
  }

  Widget _legend(String text, Color c) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(text, style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
    ]);
  }

  Widget _tableCard(Map t) {
    final st = int.tryParse('${t['status']}') ?? 0;
    final c = statusColor[st] ?? PosTheme.textHint;
    final open = st == 0 || st == 3;
    final busy = st == 2;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (open) {
            _openTableDialog(t);
          } else if (busy) {
            _tableActionSheet(t);
          } else {
            toast(context, '该桌状态：${statusText[st]}');
          }
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.withOpacity(0.45), width: 1.6),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text(statusText[st]!, style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('${t['quyu'] ?? ''}', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            ]),
            const Spacer(),
            Text('${t['title']}', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('${t['renshu'] ?? '-'} 人桌', style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
            if (busy) ...[
              const SizedBox(height: 4),
              Text('已开台', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            ],
          ]),
        ),
      ),
    );
  }

  // ==================== 开台 ====================
  Future<void> _openTableDialog(Map t) async {
    int people = 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text('开台 · ${t['title']}'),
        content: SizedBox(width: 340, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${t['quyu'] ?? ''} · ${t['renshu'] ?? '-'} 人桌', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton.outlined(onPressed: () => setD(() { if (people > 1) people--; }), icon: const Icon(Icons.remove)),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 18),
              child: Text('$people', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: PosTheme.accent)),
            ),
            IconButton.outlined(onPressed: () => setD(() { if (people < 99) people++; }), icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 8),
          const Text('用餐人数', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认开台'),
          ),
        ],
      )),
    );
    if (ok != true || !mounted) return;
    loadingDialog(context, '开台中…');
    try {
      final r = await Api.tableOpen(
        wenxunId: Session.wenxunId,
        tableId: int.tryParse('${t['id']}') ?? 0,
        peopleNum: people,
        operatorId: Session.staffId,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        final kaitaiId = '${r['data']?['kaitai_id'] ?? ''}';
        toast(context, '开台成功');
        await _load();
        if (!mounted) return;
        // 直接进入点菜
        final nt = tables.firstWhere((x) => '${x['id']}' == '${t['id']}', orElse: () => t);
        _dishPanel(nt, kaitaiId.isEmpty ? '${nt['kaitai_id']}' : kaitaiId);
      } else {
        toast(context, '${r['msg'] ?? '开台失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 就餐中桌台操作 ====================
  Future<void> _tableActionSheet(Map t) async {
    final kaitaiId = '${t['kaitai_id'] ?? ''}';
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${t['title']} · 就餐中', textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 18),
          BigButton('查看账单 / 加菜 / 结账', onTap: () { Navigator.pop(context); _dishPanel(t, kaitaiId); }, height: 50),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: BigButton('转台', onTap: () { Navigator.pop(context); _changeTable(t); }, color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 46)),
            const SizedBox(width: 10),
            Expanded(child: BigButton('取消开台', onTap: () { Navigator.pop(context); _cancelOpen(t, kaitaiId); }, color: const Color(0xFFFFF1F0), textColor: PosTheme.red, height: 46)),
          ]),
        ]),
      )),
    );
  }

  // ==================== 点菜 / 账单面板 ====================
  Future<void> _dishPanel(Map t, String kaitaiId) async {
    await showDialog(context: context, builder: (_) => _TableBillDialog(table: t, kaitaiId: kaitaiId));
    _load();
  }

  // ==================== 转台 ====================
  Future<void> _changeTable(Map t) async {
    // 选目标桌（仅空闲）
    final candidates = tables.where((x) => '${x['status']}' == '0' && '${x['id']}' != '${t['id']}').toList();
    if (candidates.isEmpty) {
      toast(context, '没有空闲桌台可转', error: true);
      return;
    }
    final target = showDialog<Map>(context: context, builder: (_) => AlertDialog(
      title: const Text('转台 · 选择目标桌'),
      content: SizedBox(width: 380, height: 360, child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 110, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1.1),
        itemCount: candidates.length,
        itemBuilder: (_, i) => InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.pop(context, candidates[i]),
          child: Container(
            decoration: BoxDecoration(color: const Color(0xFFF0FFF6), borderRadius: BorderRadius.circular(10), border: Border.all(color: PosTheme.green.withOpacity(0.4))),
            child: Center(child: Text('${candidates[i]['title']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
          ),
        ),
      )),
    ));
    final picked = await target;
    if (picked == null || !mounted) return;
    loadingDialog(context, '转台中…');
    try {
      final r = await Api.tableChange(
        wenxunId: Session.wenxunId,
        sourceTableId: int.tryParse('${t['id']}') ?? 0,
        targetTableId: int.tryParse('${picked['id']}') ?? 0,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        toast(context, '已转至 ${picked['title']}');
        _load();
      } else {
        toast(context, '${r['msg'] ?? '转台失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 取消开台 ====================
  Future<void> _cancelOpen(Map t, String kaitaiId) async {
    final ok = await confirm(context, '取消开台', '「${t['title']}」未结算菜品将被清空，桌台恢复空闲，确定？');
    if (!ok || !mounted) return;
    loadingDialog(context, '处理中…');
    try {
      final r = await Api.tableCancelOpen(
        wenxunId: Session.wenxunId,
        tableId: int.tryParse('${t['id']}') ?? 0,
        kaitaiId: kaitaiId,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        toast(context, '已取消开台');
        _load();
      } else {
        toast(context, '${r['msg'] ?? '操作失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }
}

// ==================== 桌台账单 / 点菜 / 结账 ====================
class _TableBillDialog extends StatefulWidget {
  final Map table;
  final String kaitaiId;
  const _TableBillDialog({required this.table, required this.kaitaiId});
  @override
  State<_TableBillDialog> createState() => _TableBillDialogState();
}

class _TableBillDialogState extends State<_TableBillDialog> {
  List bill = [];
  double billTotal = 0;
  bool loading = true;
  List cats = [];
  List dishes = [];
  int catId = -1;

  // 结账中转：加菜后的菜品也进 bill
  List<Map<String, dynamic>> get settleCart => bill.map((b) => {
    'goods_id': b['goods_id'],
    'goods_name': b['goods_title'],
    'goods_image': b['goods_image'] ?? '',
    'unit_price': b['unit_price'],
    'quantity': b['quantity'],
  }).toList();

  @override
  void initState() {
    super.initState();
    _loadBill();
    _loadCats();
  }

  Future<void> _loadBill() async {
    try {
      final r = await Api.tableBill(wenxunId: Session.wenxunId, kaitaiId: widget.kaitaiId);
      if (!mounted) return;
      setState(() {
        bill = (r['list'] ?? []) as List;
        billTotal = double.tryParse('${r['total']}') ?? 0;
        loading = false;
      });
    } on ApiError {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  Future<void> _loadCats() async {
    try {
      final c = await Api.goodsCats(Session.wenxunId);
      if (!mounted || c.isEmpty) return;
      setState(() { cats = c; catId = int.tryParse('${c.first['id']}') ?? -1; });
      _loadDishes();
    } on ApiError {
      // 忽略，分类加载失败不阻塞账单
    }
  }

  Future<void> _loadDishes() async {
    if (catId <= 0) return;
    try {
      final g = await Api.goodsByCat(Session.wenxunId, catId);
      if (!mounted) return;
      setState(() => dishes = g);
    } on ApiError {
      if (!mounted) return;
      setState(() => dishes = []);
    }
  }

  Future<void> _addDish(Map g) async {
    loadingDialog(context, '加菜中…');
    try {
      final r = await Api.tableAddDish(
        wenxunId: Session.wenxunId,
        kaitaiId: widget.kaitaiId,
        cart: [{
          'goods_id': g['id'],
          'goods_name': g['title'],
          'goods_image': g['goods_image'] ?? '',
          'unit_price': double.tryParse('${g['amount'] ?? g['price']}') ?? 0,
          'quantity': 1,
        }],
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        toast(context, '已加：${g['title']}');
        _loadBill();
      } else {
        toast(context, '${r['msg'] ?? '加菜失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 结账 ====================
  Future<void> _settle() async {
    if (bill.isEmpty) {
      toast(context, '该桌还没有点菜品', error: true);
      return;
    }
    final methods = ['现金', '微信支付', '支付宝', '会员余额'];
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _DiningPayDialog(total: billTotal, methods: methods),
    );
    if (picked == null || !mounted) return;
    loadingDialog(context, '结算中…');
    try {
      final r = await Api.tableSettle(
        wenxunId: Session.wenxunId,
        kaitaiId: widget.kaitaiId,
        tableId: int.tryParse('${widget.table['id']}') ?? 0,
        tableTitle: '${widget.table['title']}',
        tableQuyu: '${widget.table['quyu'] ?? ''}',
        peopleNum: int.tryParse('${widget.table['people_num']}') ?? 1,
        operatorId: Session.staffId,
        operatorName: Session.staffName,
        goodsTotal: billTotal,
        finalTotal: billTotal,
        pay1Type: picked,
        pay1Money: billTotal,
        cart: settleCart,
      );
      if (!mounted) return;
      Navigator.pop(context); // loading
      if ('${r['code']}' == '200') {
        final orderSn = '${r['data']?['order_sn'] ?? ''}';
        Navigator.pop(context); // bill dialog
        // 云打印结账单
        CloudPrinter.print(CloudPrinter.diningReceipt(
          orderSn: orderSn,
          tableTitle: '${widget.table['title']}',
          peopleNum: int.tryParse('${widget.table['people_num']}') ?? 1,
          payMethod: picked,
          goodsTotal: billTotal,
          finalTotal: billTotal,
          cart: settleCart,
        )).catchError((_) => <String, dynamic>{});
        showDialog(context: context, builder: (_) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 72, height: 72, decoration: BoxDecoration(color: PosTheme.green.withOpacity(0.12), shape: BoxShape.circle),
                  child: const Icon(Icons.check, size: 40, color: PosTheme.green)),
              const SizedBox(height: 18),
              const Text('结账成功', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text('¥${Fmt.money(billTotal)} · $picked', style: const TextStyle(fontSize: 17, color: PosTheme.textSub)),
              if (orderSn.isNotEmpty) Text('单号 $orderSn', style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
              const SizedBox(height: 20),
              SizedBox(width: 220, child: BigButton('完成', onTap: () => Navigator.pop(context), height: 46)),
            ]),
          ),
        ));
      } else {
        toast(context, '${r['msg'] ?? '结算失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 860, height: 620,
        child: Column(children: [
          // 头部
          Container(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 14),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: PosTheme.line))),
            child: Row(children: [
              Text('${widget.table['title']} · 已点账单',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Text('人数 ${widget.table['people_num'] ?? 1}', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
              const Spacer(),
              Text('合计 ¥${Fmt.money(billTotal)}', style: const TextStyle(fontSize: 20, color: PosTheme.accent, fontWeight: FontWeight.w800)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
          ),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // 左：账单
              Expanded(
                flex: 5,
                child: loading
                    ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                    : bill.isEmpty
                        ? const EmptyView('还没有点菜品，从右侧点菜')
                        : ListView.separated(
                            padding: const EdgeInsets.all(14),
                            itemCount: bill.length,
                            separatorBuilder: (_, __) => const Divider(height: 1, color: PosTheme.line),
                            itemBuilder: (_, i) {
                              final b = bill[i];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 7),
                                child: Row(children: [
                                  Expanded(child: Text('${b['goods_title']}', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500))),
                                  Text('¥${Fmt.money(b['unit_price'])} ×${b['quantity']}', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                                  const SizedBox(width: 12),
                                  SizedBox(width: 66, child: Text('¥${Fmt.money(b['sub_total'])}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600))),
                                ]),
                              );
                            },
                          ),
              ),
              VerticalDivider(width: 1, color: PosTheme.line),
              // 右：点菜
              Expanded(
                flex: 6,
                child: Column(children: [
                  SizedBox(
                    height: 52,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.all(10),
                      itemCount: cats.length,
                      itemBuilder: (_, i) {
                        final c = cats[i];
                        final on = catId == c['id'];
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () { setState(() => catId = c['id']); _loadDishes(); },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: on ? PosTheme.accent : const Color(0xFFF7F8FA),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('${c['title']}', style: TextStyle(fontSize: 13, color: on ? Colors.white : PosTheme.textMain)),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: dishes.isEmpty
                        ? const EmptyView('该分类暂无菜品')
                        : GridView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.95),
                            itemCount: dishes.length,
                            itemBuilder: (_, i) {
                              final g = dishes[i];
                              return Material(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () => _addDish(g),
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: PosTheme.line)),
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                      Expanded(child: '${g['goods_image'] ?? ''}'.isNotEmpty
                                          ? ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.network(Api.base + ('${g['goods_image']}'.startsWith('/') ? '' : '/') + '${g['goods_image']}', fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) => Container(color: const Color(0xFFF5F6F8), child: const Icon(Icons.restaurant, color: PosTheme.textHint))))
                                          : Container(color: const Color(0xFFF5F6F8), child: const Icon(Icons.restaurant, color: PosTheme.textHint))),
                                      const SizedBox(height: 4),
                                      Text('${g['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                                      Text('¥${Fmt.money(g['amount'] ?? g['price'])}', style: const TextStyle(fontSize: 13, color: PosTheme.accent, fontWeight: FontWeight.w700)),
                                    ]),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ]),
              ),
            ]),
          ),
          // 底部操作
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: PosTheme.line))),
            child: Row(children: [
              Text('共 ${bill.length} 项 · 合计 ¥${Fmt.money(billTotal)}',
                  style: const TextStyle(fontSize: 14.5, color: PosTheme.textSub)),
              const Spacer(),
              BigButton('结账收款', onTap: bill.isEmpty ? null : _settle, width: 180, height: 50),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ==================== 餐饮收款弹窗 ====================
class _DiningPayDialog extends StatefulWidget {
  final double total;
  final List<String> methods;
  const _DiningPayDialog({required this.total, required this.methods});
  @override
  State<_DiningPayDialog> createState() => _DiningPayDialogState();
}

class _DiningPayDialogState extends State<_DiningPayDialog> {
  String? method;
  final icons = {'现金': Icons.payments_outlined, '微信支付': Icons.chat, '支付宝': Icons.account_balance_wallet_outlined, '会员余额': Icons.badge_outlined};
  final colors = {'现金': PosTheme.green, '微信支付': PosTheme.green, '支付宝': PosTheme.blue, '会员余额': PosTheme.accent};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        const Text('结账收款', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('¥${Fmt.money(widget.total)}', style: const TextStyle(fontSize: 26, color: PosTheme.accent, fontWeight: FontWeight.w800)),
      ]),
      content: SizedBox(width: 400, child: Wrap(
        spacing: 10, runSpacing: 10,
        children: widget.methods.map((m) {
          final on = method == m;
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => method = m),
            child: Container(
              width: 186, padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: on ? colors[m]!.withOpacity(0.1) : const Color(0xFFF7F8FA),
                border: Border.all(color: on ? colors[m]! : Colors.transparent, width: 1.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icons[m], size: 20, color: colors[m]),
                const SizedBox(width: 8),
                Text(m, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              ]),
            ),
          );
        }).toList(),
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          onPressed: method == null ? null : () => Navigator.pop(context, method),
          style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12)),
          child: const Text('确认收款', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
