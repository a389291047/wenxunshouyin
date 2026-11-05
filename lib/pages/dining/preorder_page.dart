import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/print_prefs.dart';
import '../../core/printer_route.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

/// 餐饮版 · 预约点餐（v3.3.102）
///
/// 顾客扫「门店预约码」（所有顾客同一个链接，不绑桌台）→ 选菜提交 →
/// 这里汇总所有提交，收银员「安排开台」选桌 → 菜品进账单 → 后厨出票。
class PreorderPage extends StatefulWidget {
  const PreorderPage({super.key});
  @override
  State<PreorderPage> createState() => _PreorderPageState();
}

class _PreorderPageState extends State<PreorderPage> {
  int tab = 0; // 0 待安排 1 已安排 2 已拒绝
  bool loading = true;
  String error = '';
  String keyword = '';
  List rows = [];
  Map counts = <String, dynamic>{'0': 0, '1': 0, '2': 0};
  List tables = [];
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _loadTables();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final r = await Api.preorderList(
        wenxunId: Session.wenxunId,
        status: '$tab',
        keyword: keyword,
      );
      if (!mounted) return;
      final d = (r['data'] ?? {}) as Map;
      setState(() {
        rows = (d['list'] ?? []) as List;
        counts = Map<String, dynamic>.from((d['counts'] ?? {}) as Map);
        loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.message;
      });
    }
  }

  Future<void> _loadTables() async {
    try {
      final r = await Api.tables(Session.wenxunId);
      if (!mounted) return;
      setState(() => tables = r);
    } on ApiError {
      // 桌台加载失败不阻塞列表
    }
  }

  /// 待安排总数（顶栏角标用，任何 tab 都取 counts['0']）
  int get _waiting => int.tryParse('${counts['0'] ?? 0}') ?? 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PosTheme.bg,
      body: Column(children: [
        _header(),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
              : error.isNotEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(error, style: const TextStyle(color: PosTheme.red)),
                      const SizedBox(height: 12),
                      BigButton('重新加载', onTap: _load, width: 140, height: 42),
                    ]))
                  : rows.isEmpty
                      ? EmptyView(
                          tab == 0 ? '暂无待安排的预约' : (tab == 1 ? '暂无已安排的预约' : '暂无已拒绝的预约'),
                          icon: Icons.event_available_outlined,
                        )
                      : RefreshIndicator(
                          color: PosTheme.accent,
                          onRefresh: () async {
                            await Future.wait([_load(), _loadTables()]);
                          },
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
                            itemCount: rows.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (_, i) => _card(Map<String, dynamic>.from(rows[i] as Map)),
                          ),
                        ),
        ),
      ]),
    );
  }

  // ==================== 顶部 ====================

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 24, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: PosTheme.line)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: '返回',
          ),
          const SizedBox(width: 2),
          const Text('预约点餐', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(width: 10),
          if (_waiting > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(color: PosTheme.red.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
              child: Text('待安排 $_waiting', style: const TextStyle(fontSize: 12, color: PosTheme.red, fontWeight: FontWeight.w700)),
            ),
          const SizedBox(width: 12),
          const Text('顾客扫码提交 → 收银员安排开台 → 菜品自动进账单并传后厨',
              style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
          const Spacer(),
          // 门店预约码（所有顾客同一个链接）
          OutlinedButton.icon(
            onPressed: _unionQr,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
              foregroundColor: PosTheme.blue,
              side: const BorderSide(color: PosTheme.blue),
            ),
            icon: const Icon(Icons.qr_code_2, size: 17),
            label: const Text('门店预约码'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: () {
              _load();
              _loadTables();
            },
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
              foregroundColor: PosTheme.accent,
              side: const BorderSide(color: PosTheme.accent),
            ),
            icon: const Icon(Icons.refresh, size: 17),
            label: const Text('刷新'),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          _tabChip(0, '待安排', PosTheme.accent),
          const SizedBox(width: 10),
          _tabChip(1, '已安排', PosTheme.green),
          const SizedBox(width: 10),
          _tabChip(2, '已拒绝', PosTheme.textHint),
          const SizedBox(width: 18),
          SizedBox(
            width: 260,
            height: 38,
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜手机号 / 称呼 / 桌台',
                hintStyle: const TextStyle(fontSize: 13, color: PosTheme.textHint),
                prefixIcon: const Icon(Icons.search, size: 18, color: PosTheme.textHint),
                filled: true,
                fillColor: PosTheme.bg,
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
              onSubmitted: (v) {
                keyword = v.trim();
                _load();
              },
            ),
          ),
          if (keyword.isNotEmpty) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                _searchCtrl.clear();
                keyword = '';
                _load();
              },
              child: const Text('清除'),
            ),
          ],
        ]),
      ]),
    );
  }

  Widget _tabChip(int key, String label, Color color) {
    final on = tab == key;
    final n = int.tryParse('${counts['$key'] ?? 0}') ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        setState(() => tab = key);
        _load();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
        decoration: BoxDecoration(
          color: on ? color : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: on ? color : PosTheme.line),
        ),
        child: Text(
          n > 0 ? '$label $n' : label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: on ? Colors.white : PosTheme.textSub,
          ),
        ),
      ),
    );
  }

  // ==================== 卡片 ====================

  Widget _card(Map<String, dynamic> r) {
    final st = int.tryParse('${r['status']}') ?? 0;
    final items = ((r['items'] ?? []) as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final total = double.tryParse('${r['total'] ?? 0}') ?? 0;
    final people = int.tryParse('${r['people_num'] ?? 0}') ?? 0;
    final name = '${r['contact_name'] ?? ''}'.trim();
    final phone = '${r['contact_phone'] ?? ''}'.trim();
    final arrive = '${r['arrive_time'] ?? ''}'.trim();
    final remark = '${r['remark'] ?? ''}'.trim();
    final tableTitle = '${r['table_title'] ?? ''}'.trim();
    final stColor = const {0: PosTheme.accent, 1: PosTheme.green, 2: PosTheme.textHint}[st] ?? PosTheme.textHint;
    final stText = const {0: '待安排', 1: '已安排', 2: '已拒绝'}[st] ?? '';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: st == 0 ? PosTheme.accent.withOpacity(0.35) : PosTheme.line),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: stColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(
                  name.isNotEmpty ? name.substring(0, 1) : '客',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: stColor),
                ),
              ),
              const SizedBox(width: 10),
              Text(name.isNotEmpty ? name : '未留称呼', style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
              if (phone.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(phone, style: const TextStyle(fontSize: 13.5, color: PosTheme.blue, fontWeight: FontWeight.w600)),
              ],
              if (people > 0) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: PosTheme.bg, borderRadius: BorderRadius.circular(20)),
                  child: Text('$people 人', style: const TextStyle(fontSize: 12, color: PosTheme.textSub, fontWeight: FontWeight.w600)),
                ),
              ],
              if (arrive.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFFFF7E8), borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.schedule, size: 12, color: Color(0xFFD97706)),
                    const SizedBox(width: 3),
                    Text(arrive, style: const TextStyle(fontSize: 12, color: Color(0xFFD97706), fontWeight: FontWeight.w600)),
                  ]),
                ),
              ],
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(color: stColor.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                child: Text(stText, style: TextStyle(fontSize: 12, color: stColor, fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              items.map((e) => '${e['goods_name'] ?? e['goods_title'] ?? ''}×${e['quantity'] ?? 0}').join('、'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub, height: 1.6),
            ),
            const SizedBox(height: 6),
            Row(children: [
              Text('提交 ${r['create_time'] ?? ''}', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              if (tableTitle.isNotEmpty) ...[
                const SizedBox(width: 10),
                Text('桌台 $tableTitle', style: const TextStyle(fontSize: 11.5, color: PosTheme.green, fontWeight: FontWeight.w600)),
              ],
              if (st == 1 && '${r['kaitai_id'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text('开台号 ${r['kaitai_id']}', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              ],
              if (st == 2 && '${r['handle_time'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text('处理 ${r['handle_time']}', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              ],
              if (remark.isNotEmpty) ...[
                const SizedBox(width: 10),
                Flexible(
                  child: Text('备注：$remark',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: PosTheme.amber)),
                ),
              ],
            ]),
          ]),
        ),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('¥${Fmt.money(total)}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: PosTheme.accent)),
          Text('${items.length} 项', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
          const SizedBox(height: 10),
          if (st == 0)
            Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 88,
                child: BigButton('拒绝',
                    onTap: () => _reject(r),
                    color: const Color(0xFFF4F5F7),
                    textColor: PosTheme.textSub,
                    height: 38),
              ),
              const SizedBox(width: 8),
              SizedBox(width: 118, child: BigButton('安排开台', onTap: () => _assign(r), height: 38)),
            ]),
        ]),
      ]),
    );
  }

  // ==================== 安排开台 ====================

  Future<void> _assign(Map<String, dynamic> r) async {
    if (tables.isEmpty) await _loadTables();
    if (!mounted) return;
    if (tables.isEmpty) {
      toast(context, '暂无桌台，请先在桌台管理里添加', error: true);
      return;
    }
    final picked = await showDialog<Map>(
      context: context,
      builder: (_) => _AssignDialog(row: r, tables: tables),
    );
    if (picked == null || !mounted) return;
    final tableId = int.tryParse('${picked['table_id']}') ?? 0;
    final people = int.tryParse('${picked['people_num']}') ?? 0;
    if (tableId <= 0) return;

    loadingDialog(context, '开台中…');
    try {
      final res = await Api.preorderApprove(
        wenxunId: Session.wenxunId,
        preorderId: int.tryParse('${r['id']}') ?? 0,
        tableId: tableId,
        peopleNum: people,
        operatorId: Session.staffId,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      Navigator.pop(context); // loading
      if ('${res['code']}' != '200') {
        toast(context, '${res['msg'] ?? '开台失败'}', error: true);
        return;
      }
      final d = (res['data'] ?? {}) as Map;
      final items = ((d['items'] ?? []) as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      toast(context, '${res['msg'] ?? '已开台'}');
      // 菜品下到厨房：后厨按分类路由出票 + 前台整单一张
      _printOrder(
        items,
        '${d['table_title'] ?? ''}',
        _quyuOf(tableId),
      );
      await Future.wait([_load(), _loadTables()]);
    } on ApiError catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  String _quyuOf(int tableId) {
    for (final t in tables) {
      if ('${t['id']}' == '$tableId') return '${t['quyu'] ?? ''}';
    }
    return '';
  }

  Future<void> _reject(Map<String, dynamic> r) async {
    final ok = await confirm(context, '拒绝预约', '拒绝后该预约不会开台，顾客所点菜品不会下到厨房，确定？');
    if (!ok || !mounted) return;
    try {
      final res = await Api.preorderReject(
        wenxunId: Session.wenxunId,
        preorderId: int.tryParse('${r['id']}') ?? 0,
        operatorId: Session.staffId,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      toast(context, '${res['msg'] ?? '已拒绝'}');
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  // ==================== 出票 ====================

  Future<void> _printOrder(List<Map<String, dynamic>> items, String tableTitle, String quyu) async {
    if (items.isEmpty) return;
    try {
      final cart = items
          .map((e) => <String, dynamic>{
                'goods_id': e['goods_id'],
                'goods_name': '${e['goods_name'] ?? e['goods_title'] ?? ''}',
                'goods_image': e['goods_image'] ?? '',
                'unit_price': e['unit_price'] ?? 0,
                'quantity': e['quantity'] ?? 0,
                'cat_id': '${e['cat_id'] ?? ''}',
              })
          .toList();
      if (await PrintPrefs.on('kitchen')) {
        final routes = await PrinterRoute.routes('${Session.wenxunId}');
        final byPrinter = <String, List<Map<String, dynamic>>>{};
        final fallback = <Map<String, dynamic>>[];
        for (final it in cart) {
          final catId = '${it['cat_id']}';
          String? target;
          if (catId.isNotEmpty && catId != 'null' && catId != '0') {
            for (final e in routes.entries) {
              if (e.value.contains(catId)) {
                target = e.key;
                break;
              }
            }
          }
          if (target != null) {
            byPrinter.putIfAbsent(target, () => []).add(it);
          } else {
            fallback.add(it);
          }
        }
        final futures = <Future>[];
        byPrinter.forEach((code, list) {
          futures.add(CloudPrinter.printTo(
              code,
              CloudPrinter.kitchenTicket(
                  tableTitle: tableTitle, tableQuyu: quyu, cart: list, isAdd: true, title: '后厨单')));
        });
        if (fallback.isNotEmpty) {
          futures.add(CloudPrinter.printKitchen(CloudPrinter.kitchenTicket(
              tableTitle: tableTitle, tableQuyu: quyu, cart: fallback, isAdd: true, title: '后厨单')));
        }
        await Future.wait(futures);
      }
      if (await PrintPrefs.on('front')) {
        final code = await PrinterRoute.frontPrinter('${Session.wenxunId}');
        await CloudPrinter.printFront(
            CloudPrinter.kitchenTicket(tableTitle: tableTitle, tableQuyu: quyu, cart: cart, title: '前台单'),
            machineCode: code);
      }
    } catch (_) {
      // 打印失败不影响开台
    }
  }

  // ==================== 门店预约码 ====================

  Future<void> _unionQr() async {
    final url = Api.preorderUnionUrl(wenxunId: Session.wenxunId);
    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('门店预约点餐码', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text('所有顾客扫同一个码：选菜 → 填手机号 → 提交预约\n收银员在「预约点餐」里安排桌台后，菜品直接下厨房',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: PosTheme.textHint, height: 1.6)),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                Api.preorderQrUrl(wenxunId: Session.wenxunId),
                width: 260,
                height: 260,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Container(
                  width: 260,
                  height: 260,
                  color: const Color(0xFFF4F5F7),
                  alignment: Alignment.center,
                  child: const Text('二维码加载失败\n请检查网络后重试',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(color: PosTheme.bg, borderRadius: BorderRadius.circular(8)),
              child: Text(url, style: const TextStyle(fontSize: 11.5, color: PosTheme.textSub)),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: BigButton('关闭', onTap: () => Navigator.pop(ctx), color: const Color(0xFFF4F5F7), textColor: PosTheme.textSub, height: 42),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: BigButton('复制链接', onTap: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (ctx.mounted) toast(ctx, '链接已复制，可发到朋友圈/公众号');
                }, height: 42),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// 安排开台弹窗：选桌 + 人数
class _AssignDialog extends StatefulWidget {
  final Map<String, dynamic> row;
  final List tables;
  const _AssignDialog({required this.row, required this.tables});

  @override
  State<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends State<_AssignDialog> {
  Map? picked;
  int people = 0;

  @override
  void initState() {
    super.initState();
    people = int.tryParse('${widget.row['people_num'] ?? 0}') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final items = ((widget.row['items'] ?? []) as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final total = double.tryParse('${widget.row['total'] ?? 0}') ?? 0;
    final name = '${widget.row['contact_name'] ?? ''}'.trim();
    final phone = '${widget.row['contact_phone'] ?? ''}'.trim();

    final available = widget.tables.where((t) {
      final st = int.tryParse('${t['status']}') ?? 0;
      return st == 0 || st == 1 || st == 2 || st == 3 || st == 4;
    }).toList();

    return Dialog(
      child: Container(
        width: 760,
        height: 640,
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('安排开台', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(width: 10),
            Text(
              [if (name.isNotEmpty) name, if (phone.isNotEmpty) phone, if (people > 0) '$people 人']
                  .join(' · '),
              style: const TextStyle(fontSize: 13, color: PosTheme.textSub),
            ),
            const Spacer(),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
          Text(
            '${items.map((e) => '${e['goods_name'] ?? e['goods_title']}×${e['quantity']}').join('、')}'
            '　合计 ¥${Fmt.money(total)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint, height: 1.6),
          ),
          const SizedBox(height: 12),
          const Text('选择桌台（就餐中 = 追加到该桌账单）',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: PosTheme.textSub)),
          const SizedBox(height: 8),
          Expanded(
            child: available.isEmpty
                ? const Center(child: Text('暂无可用桌台', style: TextStyle(color: PosTheme.textHint)))
                : GridView.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 150,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 1.45,
                    ),
                    itemCount: available.length,
                    itemBuilder: (_, i) {
                      final t = available[i] as Map;
                      final id = int.tryParse('${t['id']}') ?? 0;
                      final st = int.tryParse('${t['status']}') ?? 0;
                      final on = int.tryParse('${picked?['id']}') == id;
                      final stText = const {0: '空闲', 1: '已预定', 2: '就餐中·追加', 3: '扫码点餐', 4: '待清台'}[st] ?? '';
                      final stColor = const {
                        0: PosTheme.green,
                        1: PosTheme.amber,
                        2: PosTheme.accent,
                        3: PosTheme.blue,
                        4: Color(0xFFF97316),
                      }[st] ??
                          PosTheme.textHint;
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() => picked = t),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: on ? PosTheme.accent.withOpacity(0.06) : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: on ? PosTheme.accent : PosTheme.line, width: on ? 1.8 : 1),
                          ),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text('${t['title'] ?? ''}',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 3),
                            Text('${t['quyu'] ?? ''}', style: const TextStyle(fontSize: 11, color: PosTheme.textHint)),
                            const SizedBox(height: 3),
                            Text(stText,
                                style: TextStyle(fontSize: 11.5, color: stColor, fontWeight: FontWeight.w700)),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            const Text('用餐人数', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
            const SizedBox(width: 10),
            for (final n in [1, 2, 3, 4, 5, 6, 8, 10])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => people = n),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: people == n ? PosTheme.accent.withOpacity(0.1) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: people == n ? PosTheme.accent : PosTheme.line),
                    ),
                    child: Text('$n',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: people == n ? PosTheme.accent : PosTheme.textSub,
                        )),
                  ),
                ),
              ),
            const Spacer(),
            SizedBox(
              width: 100,
              child: BigButton('取消',
                  onTap: () => Navigator.pop(context),
                  color: const Color(0xFFF4F5F7),
                  textColor: PosTheme.textSub,
                  height: 42),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 150,
              child: BigButton(
                picked == null ? '请选择桌台' : '确认开台',
                onTap: picked == null
                    ? null
                    : () => Navigator.pop(context, {
                          'table_id': int.tryParse('${picked!['id']}') ?? 0,
                          'people_num': people,
                        }),
                height: 42,
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
