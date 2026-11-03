import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/no_code_goods.dart';
import '../../ui/vip_recharge.dart';
import '../../ui/widgets.dart';
import 'dining_modes.dart';
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
  String region = ''; // 区域筛选：'' = 全部区域

  // 所有区域（去重、保序）
  List<String> get _regions {
    final seen = <String>[];
    for (final t in tables) {
      final q = '${t['quyu'] ?? ''}'.trim();
      if (q.isNotEmpty && !seen.contains(q)) seen.add(q);
    }
    return seen;
  }

  // 当前区域筛选下的桌台
  List get _filteredTables =>
      region.isEmpty ? tables : tables.where((t) => '${t['quyu'] ?? ''}'.trim() == region).toList();

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
      if (mode == 0) _orderModeBar(),
      if (mode == 0) _regionBar(),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
            : error != null
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(error!, style: const TextStyle(color: PosTheme.red)),
                    const SizedBox(height: 12),
                    BigButton('重新加载', onTap: _load, width: 140, height: 42),
                  ]))
                : _filteredTables.isEmpty
                    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: const [
                        Icon(Icons.table_restaurant_outlined, size: 56, color: PosTheme.textHint),
                        SizedBox(height: 12),
                        Text('该区域暂无桌台', style: TextStyle(color: PosTheme.textHint)),
                      ]))
                    : RefreshIndicator(
                        color: PosTheme.accent,
                        onRefresh: _load,
                        child: GridView.builder(
                          padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 190, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.25,
                          ),
                          itemCount: _filteredTables.length,
                          itemBuilder: (_, i) => _tableCard(_filteredTables[i]),
                        ),
                      ),
      ),
    ]);
  }

  Widget _modeBar() {
    final isTable = mode == 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
      child: Row(children: [
        const Text('点餐', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        const SizedBox(width: 20),
        _seg('桌台模式', 0),
        const SizedBox(width: 8),
        _seg('快捷模式（外带/快餐）', 1),
        if (isTable) ...[
          const Spacer(),
          _legend('空闲 $idleCount', PosTheme.green),
          const SizedBox(width: 12),
          _legend('就餐中 $busyCount', PosTheme.accent),
          const SizedBox(width: 12),
          _legend('已预定 ${tables.where((t) => '${t['status']}' == '1').length}', PosTheme.amber),
          const SizedBox(width: 14),
          OutlinedButton.icon(
            onPressed: _load,
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14), foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
            icon: const Icon(Icons.refresh, size: 17),
            label: const Text('刷新桌台'),
          ),
        ],
      ]),
    );
  }

  // ==================== 点餐方式条（8 种模式，与小程序截图一致） ====================

  static const List<Map<String, dynamic>> _orderModes = [
    {'label': '开台点餐', 'color': PosTheme.red},
    {'label': '不开台点餐', 'color': PosTheme.blue},
    {'label': '自助点餐', 'color': Color(0xFFFF7A45)},
    {'label': '扫码点餐', 'color': PosTheme.green},
    {'label': '外卖点餐', 'color': Color(0xFF7B61FF)},
    {'label': '排队点餐', 'color': PosTheme.blue},
    {'label': '预约点餐', 'color': Color(0xFF7B61FF)},
    {'label': '挂账点餐', 'color': PosTheme.red},
  ];

  Widget _orderModeBar() {
    return Container(
      height: 44,
      margin: const EdgeInsets.fromLTRB(24, 6, 24, 0),
      child: Row(children: [
        const Text('点餐方式', style: TextStyle(fontSize: 13.5, color: PosTheme.textHint)),
        const SizedBox(width: 12),
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [for (final m in _orderModes) _orderModeChip(m)],
          ),
        ),
      ]),
    );
  }

  Widget _orderModeChip(Map<String, dynamic> m) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _openOrderMode('${m['label']}'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: PosTheme.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 9, height: 9, decoration: BoxDecoration(color: m['color'] as Color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text('${m['label']}', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: PosTheme.textSub)),
          ]),
        ),
      ),
    );
  }

  Future<void> _openOrderMode(String label) async {
    switch (label) {
      case '开台点餐':
        toast(context, '请在下方选择空闲桌台进行开台点餐');
        break;
      case '不开台点餐':
        await showDialog(context: context, builder: (_) => const DirectOrderDialog());
        break;
      case '自助点餐':
      case '扫码点餐':
        if (tables.isEmpty) { toast(context, '暂无桌台，请先到后台添加', error: true); break; }
        final t = await showDialog<Map>(
          context: context,
          builder: (_) => TablePickDialog(tables: tables, title: '$label · 选桌出码'),
        );
        if (t != null && mounted) _showQrCode(t);
        break;
      case '外卖点餐':
        await showDialog(context: context, builder: (_) => const WaimaiDialog());
        break;
      case '排队点餐':
        await showDialog(context: context, builder: (_) => const PaihaoDialog());
        break;
      case '预约点餐':
        await showDialog(
          context: context,
          builder: (_) => BookListDialog(tables: tables, onArrival: _arrivalFlow, onCancelBook: _cancelBook),
        );
        break;
      case '挂账点餐':
        await showDialog(context: context, builder: (_) => const GuazhangDialog());
        break;
    }
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

  Widget _legend(String text, Color c) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(text, style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
    ]);
  }

  // ==================== 区域切换条（全部 / 大厅 / 客房 / 茶楼 …） ====================
  Widget _regionBar() {
    final regions = _regions;
    if (regions.length <= 1) {
      // 只有一个区域（或无区域）时不用筛选
      if (region.isNotEmpty) region = '';
      return const SizedBox.shrink();
    }
    return Container(
      height: 46,
      margin: const EdgeInsets.fromLTRB(24, 12, 24, 6),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _regionChip('全部', tables.length, ''),
          for (final r in regions)
            _regionChip(r, tables.where((t) => '${t['quyu'] ?? ''}'.trim() == r).length, r),
        ],
      ),
    );
  }

  Widget _regionChip(String label, int count, String value) {
    final on = region == value;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => region = value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: on ? PosTheme.accent : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? PosTheme.accent : PosTheme.line, width: on ? 0 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: on ? Colors.white.withOpacity(0.25) : const Color(0xFFF2F3F7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('$count', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textHint)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _tableCard(Map t) {
    final st = int.tryParse('${t['status']}') ?? 0;
    final c = statusColor[st] ?? PosTheme.textHint;
    final open = st == 0 || st == 3;
    final busy = st == 2;
    final bookInfo = st == 1
        ? '${('${t['book_operator_name'] ?? ''}')} ${('${t['book_time'] ?? ''}')}'.trim()
        : '';
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (open) {
            // 扫码点餐桌（状态3）若顾客已下单（有开台号），直接进账单面板；
            // 否则走开台流程
            final kt = '${t['kaitai_id'] ?? ''}';
            if (st == 3 && kt.isNotEmpty) {
              _dishPanel(t, kt);
            } else {
              _openTableDialog(t);
            }
          } else if (busy) {
            _tableActionSheet(t);
          } else if (st == 1) {
            _bookedActionSheet(t);
          } else {
            toast(context, '该桌状态：${statusText[st]}');
          }
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
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
            ]),
            const Spacer(),
            Text('${t['title']}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text('${t['renshu'] ?? '-'} 人桌', style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
            if (bookInfo.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text('预定 $bookInfo', style: const TextStyle(fontSize: 11, color: PosTheme.amber), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            if (busy) ...[
              const SizedBox(height: 2),
              Text('已开台', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            ],
            if (st == 0) ...[
              const SizedBox(height: 6),
              Row(children: [
                _cardAction('预点餐', onTap: () => _openPreorder(t)),
                const SizedBox(width: 8),
                _cardAction('点餐码', onTap: () => _showQrCode(t)),
              ]),
            ],
          ]),
        ),
      ),
    );
  }

  // 桌台卡片上的小操作按钮
  Widget _cardAction(String label, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6FA),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: PosTheme.line),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
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
          const SizedBox(height: 10),
          BigButton('顾客点餐码（扫码加菜）', onTap: () { Navigator.pop(context); _showQrCode(t); }, color: const Color(0xFFF0F5FF), textColor: PosTheme.blue, height: 46),
        ]),
      )),
    );
  }

  // ==================== 已预定桌台操作 ====================
  Future<void> _bookedActionSheet(Map t) async {
    final bookInfo = '${('${t['book_operator_name'] ?? '-'}')}  ${('${t['book_time'] ?? ''}')}'.trim();
    final remark = '${t['service_note'] ?? ''}';
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${t['title']} · 已预定', textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          if (bookInfo.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(bookInfo, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
          ],
          // 预点单摘要（异步查询）
          FutureBuilder<Map<String, dynamic>>(
            future: Api.preorderGet(wenxunId: Session.wenxunId, tableId: int.tryParse('${t['id']}') ?? 0),
            builder: (_, snap) {
              if (!snap.hasData || '${snap.data!['code']}' != '200') return const SizedBox.shrink();
              final list = (snap.data!['list'] ?? []) as List;
              if (list.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(color: const Color(0xFFFFF8EC), borderRadius: BorderRadius.circular(10)),
                  child: Text(
                    '已预点 ${list.length} 项 · ¥${snap.data!['total']}${remark.isNotEmpty ? ' · $remark' : ''}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12.5, color: PosTheme.amber, fontWeight: FontWeight.w600),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          BigButton('顾客到店 · 开台并出后厨票', onTap: () { Navigator.pop(context); _arrivalFlow(t); }, height: 50),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: BigButton('预点餐 / 改菜', onTap: () { Navigator.pop(context); _openPreorder(t); }, color: const Color(0xFFFFF8EC), textColor: PosTheme.amber, height: 46)),
            const SizedBox(width: 10),
            Expanded(child: BigButton('点餐码', onTap: () { Navigator.pop(context); _showQrCode(t); }, color: const Color(0xFFF0F5FF), textColor: PosTheme.blue, height: 46)),
          ]),
          const SizedBox(height: 10),
          BigButton('取消预定', onTap: () { Navigator.pop(context); _cancelBook(t); }, color: const Color(0xFFFFF1F0), textColor: PosTheme.red, height: 46),
        ]),
      )),
    );
  }

  // 打开预点餐弹窗（已预定桌）
  Future<void> _openPreorder(Map t) async {
    await showDialog(context: context, builder: (_) => _PreorderDialog(table: t));
    _load();
  }

  // ==================== 顾客到店：开台 + 出后厨票 ====================
  Future<void> _arrivalFlow(Map t) async {
    // 先问用餐人数（默认桌台容量）
    int people = int.tryParse('${t['renshu']}') ?? 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text('顾客到店 · ${t['title']}'),
        content: SizedBox(width: 340, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('将开台并把预点菜品转入账单，同时向后厨打印菜品小票', style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
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
            child: const Text('到店开台'),
          ),
        ],
      )),
    );
    if (ok != true || !mounted) return;
    loadingDialog(context, '开台中…');
    try {
      final r = await Api.preorderArrival(
        wenxunId: Session.wenxunId,
        tableId: int.tryParse('${t['id']}') ?? 0,
        peopleNum: people,
        operatorId: Session.staffId,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      Navigator.pop(context); // loading
      if ('${r['code']}' == '200') {
        final kaitaiId = '${r['data']?['kaitai_id'] ?? ''}';
        final items = (r['data']?['items'] ?? []) as List;
        final remark = '${r['data']?['remark'] ?? ''}';
        toast(context, items.isEmpty ? '开台成功（该桌无预点菜品）' : '开台成功，正在向后厨打印 ${items.length} 项预点菜品');
        // 后厨小票（不阻塞后续流程）
        CloudPrinter.printKitchen(CloudPrinter.kitchenTicket(
          tableTitle: '${t['title']}',
          tableQuyu: '${t['quyu'] ?? ''}',
          cart: items.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList(),
          remark: remark,
          title: '预点出菜单',
        )).catchError((_) => <String, dynamic>{});
        await _load();
        if (!mounted) return;
        // 进账单面板（可继续加菜/结账）
        final nt = tables.firstWhere((x) => '${x['id']}' == '${t['id']}', orElse: () => t);
        if (kaitaiId.isNotEmpty) _dishPanel(nt, kaitaiId);
      } else {
        toast(context, '${r['msg'] ?? '开台失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 取消预约 ====================
  Future<void> _cancelBook(Map t) async {
    final ok = await confirm(context, '取消预定', '确定取消「${t['title']}」的预定？取消后恢复为空闲桌台。');
    if (!ok || !mounted) return;
    loadingDialog(context, '处理中…');
    try {
      final r = await Api.tableCancelBook(
        wenxunId: Session.wenxunId,
        tableId: int.tryParse('${t['id']}') ?? 0,
        operatorId: Session.staffId,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        toast(context, '已取消预定');
        _load();
      } else {
        toast(context, '${r['msg'] ?? '操作失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 扫码点餐 · 桌台二维码 ====================
  Future<void> _showQrCode(Map t) async {
    await showDialog(context: context, builder: (_) => _TableQrDialog(table: t));
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
  Map? vip; // 结账选中的会员（会员余额支付用）

  /// 会员可用余额（现金余额 + 赠送余额）
  double _vipBalance() {
    if (vip == null) return 0;
    final a = double.tryParse('${vip!['amount'] ?? 0}') ?? 0;
    final g = double.tryParse('${vip!['gift_balance'] ?? 0}') ?? 0;
    return a + g;
  }

  /// 选择会员（结账用）
  Future<void> _pickVip() async {
    final picked = await showDialog<Map>(context: context, builder: (_) => const _DiningVipPicker());
    if (picked != null && mounted) setState(() => vip = picked);
  }

  /// 给选中会员充值（成功后回查最新余额）
  Future<void> _rechargeVip() async {
    if (vip == null) return;
    final r = await showVipRechargeDialog(context, vip: vip!);
    if (r == null || !mounted) return;
    toast(context, '充值成功 ¥${Fmt.money(r['amount'])}（送 ¥${Fmt.money(r['gift'])}）');
    final phone = '${vip!['phone'] ?? ''}';
    if (phone.isEmpty) return;
    try {
      final list = await Api.vipSearch(Session.wenxunId, phone);
      if (!mounted) return;
      for (final v in list) {
        if ('${v['id']}' == '${vip!['id']}') {
          setState(() => vip = v as Map);
          return;
        }
      }
    } on ApiError {
      // 回查失败不影响后续操作
    }
  }

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

  Future<void> _addDish(Map g) => _pushDishes([{
    'goods_id': g['id'],
    'goods_name': g['title'],
    'goods_image': g['goods_image'] ?? '',
    'unit_price': double.tryParse('${g['amount'] ?? g['price']}') ?? 0,
    'quantity': 1,
  }], label: '${g['title']}');

  /// 无码菜品：手输名称/单价/数量，直接加到桌台账单
  Future<void> _noCodeDish() async {
    final r = await showDialog<Map>(
      context: context,
      builder: (_) => const NoCodeGoodsDialog(title: '无码菜品'),
    );
    if (r == null || !mounted) return;
    await _pushDishes([{
      'goods_id': 0, // 无码菜品没有商品 id，后端强转 int 为 0
      'goods_name': r['name'],
      'goods_image': '',
      'unit_price': r['amount'],
      'quantity': r['num'],
    }], label: '${r['name']}×${r['num']}');
  }

  /// 统一加菜入口：请求后端 → 后厨小票 → 刷新账单
  Future<void> _pushDishes(List<Map<String, dynamic>> cart, {required String label}) async {
    loadingDialog(context, '加菜中…');
    try {
      final r = await Api.tableAddDish(
        wenxunId: Session.wenxunId,
        kaitaiId: widget.kaitaiId,
        cart: cart,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        toast(context, '已加：$label');
        // 加菜同步打后厨小票（不阻塞）
        CloudPrinter.printKitchen(CloudPrinter.kitchenTicket(
          tableTitle: '${widget.table['title']}',
          tableQuyu: '${widget.table['quyu'] ?? ''}',
          cart: cart.map((c) => {'goods_name': c['goods_name'], 'quantity': c['quantity']}).toList(),
          isAdd: true,
        )).catchError((_) => <String, dynamic>{});
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
    final methods = ['现金', '微信支付', '支付宝', '挂账', if (vip != null) '会员余额'];
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _DiningPayDialog(total: billTotal, methods: methods, vip: vip),
    );
    if (picked == null || !mounted) return;
    if (picked == '会员余额') {
      if (vip == null) {
        toast(context, '请先选择会员', error: true);
        return;
      }
      final bal = _vipBalance();
      if (bal < billTotal) {
        toast(context, '会员余额不足（¥${Fmt.money(bal)}），请先充值', error: true);
        return;
      }
    }
    String gzName = '';
    String gzPhone = '';
    if (picked == '挂账') {
      final gz = await showGuazhangInfoDialog(context);
      if (gz == null || !mounted) return;
      gzName = gz['name'] ?? '';
      gzPhone = gz['phone'] ?? '';
    }
    loadingDialog(context, picked == '挂账' ? '挂账中…' : '结算中…');
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
        vipId: picked == '会员余额' ? (int.tryParse('${vip!['id']}') ?? 0) : 0,
        phone: picked == '会员余额' ? '${vip!['phone'] ?? ''}' : '',
        guazhangName: gzName,
        guazhangPhone: gzPhone,
      );
      if (!mounted) return;
      // 先捕获 Navigator 和要用的数据：后面 pop 掉本弹窗后 State 会被销毁，
      // 不能再使用 State.context / widget / getter（否则点击"完成"时报 unmounted）
      final navigator = Navigator.of(context);
      final tableTitle = '${widget.table['title']}';
      final peopleNum = int.tryParse('${widget.table['people_num']}') ?? 1;
      final total = billTotal;
      final cart = settleCart;
      Navigator.pop(context); // loading
      if ('${r['code']}' == '200') {
        final orderSn = '${r['data']?['order_sn'] ?? ''}';
        navigator.pop(); // bill dialog
        // 云打印结账单
        CloudPrinter.print(CloudPrinter.diningReceipt(
          orderSn: orderSn,
          tableTitle: tableTitle,
          peopleNum: peopleNum,
          payMethod: picked,
          goodsTotal: total,
          finalTotal: total,
          cart: cart,
        )).catchError((_) => <String, dynamic>{});
        // 用 navigator.context 打开成功弹窗（本 State 已随账单弹窗销毁），
        // "完成"按钮用弹窗自己的 dctx 关闭自己
        showDialog(context: navigator.context, barrierDismissible: false, builder: (dctx) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 72, height: 72, decoration: BoxDecoration(color: PosTheme.green.withOpacity(0.12), shape: BoxShape.circle),
                  child: const Icon(Icons.check, size: 40, color: PosTheme.green)),
              const SizedBox(height: 18),
              const Text('结账成功', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text('¥${Fmt.money(total)} · $picked', style: const TextStyle(fontSize: 17, color: PosTheme.textSub)),
              if (orderSn.isNotEmpty) Text('单号 $orderSn', style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
              const SizedBox(height: 20),
              SizedBox(width: 220, child: BigButton('完成', onTap: () => Navigator.pop(dctx), height: 46)),
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
              const SizedBox(width: 14),
              _vipChip(),
              if (vip != null) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: _rechargeVip,
                  borderRadius: BorderRadius.circular(9),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF2ED),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: PosTheme.accent.withOpacity(0.4)),
                    ),
                    child: const Text('充值', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                  ),
                ),
              ],
              const Spacer(),
              // 无码菜品（临时菜/时价菜手动录入）
              InkWell(
                onTap: _noCodeDish,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF2ED),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: PosTheme.accent.withOpacity(0.4)),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.keyboard_outlined, size: 19, color: PosTheme.accent),
                    SizedBox(width: 7),
                    Text('无码菜品', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                  ]),
                ),
              ),
              const SizedBox(width: 12),
              BigButton('结账收款', onTap: bill.isEmpty ? null : _settle, width: 180, height: 50),
            ]),
          ),
        ]),
      ),
    );
  }

  /// 底部会员条：未选显示「选择会员」，已选显示姓名 + 余额，右侧可清除
  Widget _vipChip() {
    final has = vip != null;
    return InkWell(
      onTap: _pickVip,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: has ? const Color(0xFFFFF2ED) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: has ? PosTheme.accent.withOpacity(0.4) : PosTheme.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(has ? Icons.person : Icons.person_add_alt, size: 17, color: has ? PosTheme.accent : PosTheme.textSub),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              has
                  ? '${vip!['name'] ?? vip!['phone'] ?? ''}　余额 ¥${Fmt.money(_vipBalance())}'
                  : '选择会员',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: has ? FontWeight.w600 : FontWeight.w400,
                color: has ? PosTheme.accent : PosTheme.textSub,
              ),
            ),
          ),
          if (has) ...[
            const SizedBox(width: 6),
            InkWell(
              onTap: () => setState(() => vip = null),
              child: const Icon(Icons.close, size: 15, color: PosTheme.textSub),
            ),
          ],
        ]),
      ),
    );
  }
}

// ==================== 结账选会员弹窗（餐饮） ====================
class _DiningVipPicker extends StatefulWidget {
  const _DiningVipPicker();
  @override
  State<_DiningVipPicker> createState() => _DiningVipPickerState();
}

class _DiningVipPickerState extends State<_DiningVipPicker> {
  List list = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String kw) async {
    setState(() => loading = true);
    try {
      final r = kw.isEmpty
          ? await Api.vipList(Session.wenxunId)
          : await Api.vipSearch(Session.wenxunId, kw);
      if (!mounted) return;
      setState(() { list = r; loading = false; });
    } on ApiError {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        const Text('选择会员', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const Spacer(),
        IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 20)),
      ]),
      content: SizedBox(
        width: 480, height: 460,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: '手机号 / 姓名 搜索后回车', prefixIcon: Icon(Icons.search, size: 19), isDense: true),
            onSubmitted: (v) => _load(v.trim()),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                : list.isEmpty
                    ? const EmptyView('未找到会员')
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final v = list[i];
                          final nm = '${v['name'] ?? ''}'.trim();
                          final ph = '${v['phone'] ?? ''}'.trim();
                          return ListTile(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            leading: CircleAvatar(radius: 19, backgroundColor: PosTheme.accent.withOpacity(0.12),
                                child: const Icon(Icons.person, size: 20, color: PosTheme.accent)),
                            title: Text(nm.isEmpty ? ph : '$nm  $ph', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                            subtitle: Text('余额 ¥${Fmt.money((double.tryParse('${v['amount'] ?? 0}') ?? 0) + (double.tryParse('${v['gift_balance'] ?? 0}') ?? 0))}',
                                style: const TextStyle(fontSize: 12.5)),
                            onTap: () => Navigator.pop(context, v),
                          );
                        },
                      ),
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
  final Map? vip;
  const _DiningPayDialog({required this.total, required this.methods, this.vip});
  @override
  State<_DiningPayDialog> createState() => _DiningPayDialogState();
}

class _DiningPayDialogState extends State<_DiningPayDialog> {
  String? method;
  final icons = {'现金': Icons.payments_outlined, '微信支付': Icons.chat, '支付宝': Icons.account_balance_wallet_outlined, '会员余额': Icons.badge_outlined, '挂账': Icons.receipt_long_outlined};
  final colors = {'现金': PosTheme.green, '微信支付': PosTheme.green, '支付宝': PosTheme.blue, '会员余额': PosTheme.accent, '挂账': PosTheme.red};

  IconData _iconOf(String m) => icons[m] ?? Icons.payments_outlined;
  Color _colorOf(String m) => colors[m] ?? PosTheme.textSub;

  double get _balance {
    final a = double.tryParse('${widget.vip?['amount'] ?? 0}') ?? 0;
    final g = double.tryParse('${widget.vip?['gift_balance'] ?? 0}') ?? 0;
    return a + g;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        const Text('结账收款', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('¥${Fmt.money(widget.total)}', style: const TextStyle(fontSize: 26, color: PosTheme.accent, fontWeight: FontWeight.w800)),
      ]),
      content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
          spacing: 10, runSpacing: 10,
          children: widget.methods.map((m) {
            final on = method == m;
            return InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => method = m),
              child: Container(
                width: 186, padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: on ? _colorOf(m).withOpacity(0.1) : const Color(0xFFF7F8FA),
                  border: Border.all(color: on ? _colorOf(m) : Colors.transparent, width: 1.4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(_iconOf(m), size: 20, color: _colorOf(m)),
                  const SizedBox(width: 8),
                  Text(m, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                ]),
              ),
            );
          }).toList(),
        ),
        if (method == '会员余额') ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: const Color(0xFFFFF2ED), borderRadius: BorderRadius.circular(10)),
            child: Text(
              '会员「${widget.vip?['name'] ?? widget.vip?['phone'] ?? ''}」余额 ¥${Fmt.money(_balance)}　扣款后 ¥${Fmt.money((_balance - widget.total).clamp(0, double.maxFinite))}',
              style: const TextStyle(fontSize: 13, color: PosTheme.accent),
            ),
          ),
        ],
        if (method == '挂账') ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: const Color(0xFFFFF1F0), borderRadius: BorderRadius.circular(10)),
            child: const Text(
              '挂账不收款，桌台释放；账款进入「挂账台账」，稍后在餐饮页 → 点餐方式 → 挂账点餐 中核销收款',
              style: TextStyle(fontSize: 13, color: PosTheme.red),
            ),
          ),
        ],
      ])),
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

// ==================== 桌台点餐码弹窗 ====================
/// 展示某桌的扫码点餐二维码（后端 api/zhuotai/diancan 生成，
/// 二维码内容含 wenxun_id + table_id，顾客扫码自动关联本桌）
class _TableQrDialog extends StatefulWidget {
  final Map table;
  const _TableQrDialog({required this.table});
  @override
  State<_TableQrDialog> createState() => _TableQrDialogState();
}

class _TableQrDialogState extends State<_TableQrDialog> {
  int _reloadKey = 0;

  String get _qrUrl =>
      'https://shop.wx-zf.com/shouyin/zhuotai/diancan?table_id=${widget.table['id']}&wenxun_id=${Session.wenxunId}&t=$_reloadKey';

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 360,
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Expanded(
              child: Text('扫码点餐', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, size: 20),
              tooltip: '关闭',
            ),
          ]),
          Text('${widget.table['title']} · ${widget.table['quyu'] ?? ''}',
              style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
          const SizedBox(height: 16),
          Container(
            width: 264,
            height: 264,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: PosTheme.line),
            ),
            child: Image.network(
              _qrUrl,
              fit: BoxFit.contain,
              loadingBuilder: (_, child, progress) {
                if (progress == null) return child;
                return const Center(child: CircularProgressIndicator(color: PosTheme.accent));
              },
              errorBuilder: (_, __, ___) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.qr_code_2, size: 44, color: PosTheme.textHint),
                  SizedBox(height: 8),
                  Text('二维码加载失败', style: TextStyle(fontSize: 13, color: PosTheme.textHint)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            '顾客用微信扫码即可进入点餐页，\n下单自动关联本桌，无需手动选桌号',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: PosTheme.textHint, height: 1.6),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: BigButton('刷新', onTap: () => setState(() => _reloadKey++), color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 44)),
            const SizedBox(width: 10),
            Expanded(child: BigButton('完成', onTap: () => Navigator.pop(context), height: 44)),
          ]),
        ]),
      ),
    );
  }
}

// ==================== 收银员预点餐弹窗 ====================
/// 空闲桌：保存后自动预约（status→1）并挂预点菜品
/// 已预定桌：可继续改菜（全量替换）
/// 顾客到店后在桌台面板点「开台并出后厨票」
class _PreorderDialog extends StatefulWidget {
  final Map table;
  const _PreorderDialog({required this.table});
  @override
  State<_PreorderDialog> createState() => _PreorderDialogState();
}

class _PreorderDialogState extends State<_PreorderDialog> {
  List bill = [];
  String remark = '';
  bool loading = true;
  List cats = [];
  List dishes = [];
  int catId = -1;
  bool saving = false;

  double get total => bill.fold(0, (s, b) => s + (double.tryParse('${b['unit_price']}') ?? 0) * (int.tryParse('${b['quantity']}') ?? 0));

  @override
  void initState() {
    super.initState();
    _loadPreorder();
    _loadCats();
  }

  Future<void> _loadPreorder() async {
    try {
      final r = await Api.preorderGet(wenxunId: Session.wenxunId, tableId: int.tryParse('${widget.table['id']}') ?? 0);
      if (!mounted) return;
      setState(() {
        bill = (r['list'] ?? []) as List;
        remark = '${r['remark'] ?? ''}';
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
      // 忽略
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

  // 点菜：已有则数量+1，否则加入
  void _pick(Map g) {
    final id = '${g['id']}';
    final idx = bill.indexWhere((b) => '${b['goods_id']}' == id);
    setState(() {
      if (idx >= 0) {
        bill[idx]['quantity'] = (int.tryParse('${bill[idx]['quantity']}') ?? 0) + 1;
      } else {
        bill.add({
          'goods_id': g['id'],
          'goods_title': g['title'],
          'unit_price': double.tryParse('${g['amount'] ?? g['price']}') ?? 0,
          'quantity': 1,
        });
      }
    });
  }

  void _changeQty(int i, int delta) {
    setState(() {
      final q = (int.tryParse('${bill[i]['quantity']}') ?? 0) + delta;
      if (q <= 0) {
        bill.removeAt(i);
      } else {
        bill[i]['quantity'] = q;
      }
    });
  }

  Future<void> _save() async {
    if (saving) return;
    saving = true;
    loadingDialog(context, '保存中…');
    try {
      final r = await Api.preorderSave(
        wenxunId: Session.wenxunId,
        tableId: int.tryParse('${widget.table['id']}') ?? 0,
        remark: remark.trim(),
        cart: bill.map<Map<String, dynamic>>((b) => {
          'goods_id': b['goods_id'],
          'goods_name': b['goods_title'],
          'unit_price': b['unit_price'],
          'quantity': b['quantity'],
        }).toList(),
        operatorId: Session.staffId,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      Navigator.pop(context); // loading
      if ('${r['code']}' == '200') {
        toast(context, bill.isEmpty ? '已预约「${widget.table['title']}」' : '预点单已保存（${bill.length} 项）');
        Navigator.pop(context); // 本弹窗
      } else {
        toast(context, '${r['msg'] ?? '保存失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
    saving = false;
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
              Text('预点餐 · ${widget.table['title']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Text('提前点菜，顾客到店一键开台出后厨票', style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
              const Spacer(),
              Text('合计 ¥${Fmt.money(total)}', style: const TextStyle(fontSize: 20, color: PosTheme.accent, fontWeight: FontWeight.w800)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
          ),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // 左：已选菜品 + 备注 + 保存
              Expanded(
                flex: 5,
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                    child: TextField(
                      controller: TextEditingController(text: remark),
                      onChanged: (v) => remark = v,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '到店备注（如：预计12:00到店 · 张先生）',
                        prefixIcon: Icon(Icons.schedule, size: 20),
                      ),
                    ),
                  ),
                  Expanded(
                    child: loading
                        ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                        : bill.isEmpty
                            ? const EmptyView('还没选菜；不选菜保存 = 仅预约桌台')
                            : ListView.separated(
                                padding: const EdgeInsets.all(14),
                                itemCount: bill.length,
                                separatorBuilder: (_, __) => const Divider(height: 1, color: PosTheme.line),
                                itemBuilder: (_, i) {
                                  final b = bill[i];
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 6),
                                    child: Row(children: [
                                      Expanded(child: Text('${b['goods_title']}', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500))),
                                      Text('¥${Fmt.money(b['unit_price'])}', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                                      const SizedBox(width: 12),
                                      _qtyBtn(Icons.remove, () => _changeQty(i, -1)),
                                      Container(
                                        width: 34,
                                        alignment: Alignment.center,
                                        child: Text('${b['quantity']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                                      ),
                                      _qtyBtn(Icons.add, () => _changeQty(i, 1)),
                                      const SizedBox(width: 8),
                                      Text('¥${Fmt.money((double.tryParse('${b['unit_price']}') ?? 0) * (int.tryParse('${b['quantity']}') ?? 0))}',
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600), textAlign: TextAlign.right),
                                    ]),
                                  );
                                },
                              ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Expanded(child: BigButton('保存预点单', onTap: _save, height: 50)),
                    ]),
                  ),
                ]),
              ),
              VerticalDivider(width: 1, color: PosTheme.line),
              // 右：分类 + 菜品
              Expanded(
                flex: 6,
                child: Column(children: [
                  SizedBox(
                    height: 52,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      itemCount: cats.length,
                      itemBuilder: (_, i) {
                        final c = cats[i];
                        final on = catId == int.tryParse('${c['id']}');
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(9),
                            onTap: () { setState(() => catId = int.tryParse('${c['id']}') ?? -1); _loadDishes(); },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: on ? PosTheme.accent : const Color(0xFFF5F6FA),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text('${c['title']}', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
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
                            padding: const EdgeInsets.all(12),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 2.4),
                            itemCount: dishes.length,
                            itemBuilder: (_, i) {
                              final g = dishes[i];
                              return InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () => _pick(g),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(color: const Color(0xFFF8F9FC), borderRadius: BorderRadius.circular(10), border: Border.all(color: PosTheme.line)),
                                  child: Row(children: [
                                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                                      Text('${g['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 3),
                                      Text('¥${Fmt.money(g['amount'] ?? g['price'])}', style: const TextStyle(fontSize: 12.5, color: PosTheme.accent, fontWeight: FontWeight.w600)),
                                    ])),
                                    const Icon(Icons.add_circle_outline, size: 20, color: PosTheme.accent),
                                  ]),
                                ),
                              );
                            },
                          ),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _qtyBtn(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        width: 26, height: 26,
        decoration: BoxDecoration(color: const Color(0xFFF2F3F7), borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, size: 15, color: PosTheme.textSub),
      ),
    );
  }
}
