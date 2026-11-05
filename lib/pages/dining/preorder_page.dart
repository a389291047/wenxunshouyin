import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/preorder_badge.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

/// 餐饮版 · 预约点餐（v3.3.104 左右布局）
///
/// 左侧：顾客提交的下单信息（待安排 / 已安排 / 已拒绝 + 搜索）
/// 右侧：该笔预约的菜品清单 + 操作按钮
/// 「安排开台」= 自动开台入账，**不打印**；打印必须回到桌台点「传后厨」。
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
  int? selectedId;
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
      final raw = r['data'];
      final d = raw is Map ? raw : const <String, dynamic>{};
      final list = d['list'];
      setState(() {
        rows = list is List ? list : <dynamic>[];
        counts = _asCounts(d['counts']);
        // 选中项若已不在当前列表，自动选中第一条
        final ids = rows.map((e) => '${(e as Map)['id']}').toList();
        if (selectedId == null || !ids.contains('$selectedId')) {
          selectedId = ids.isEmpty ? null : int.tryParse(ids.first);
        }
      });
      PreorderBadge.count.value = int.tryParse('${counts['0'] ?? 0}') ?? 0;
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => error = '数据解析失败：$e');
    } finally {
      if (mounted && loading) setState(() => loading = false);
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

  /// counts 兼容两种形态：对象 {"0":n} 与数组 [n,n,n]
  static Map<String, dynamic> _asCounts(dynamic raw) {
    final out = <String, dynamic>{'0': 0, '1': 0, '2': 0};
    if (raw is Map) {
      raw.forEach((k, v) => out['$k'] = v);
    } else if (raw is List) {
      for (var i = 0; i < raw.length && i < 3; i++) {
        out['$i'] = raw[i];
      }
    }
    return out;
  }

  int _c(String k) => int.tryParse('${counts[k] ?? 0}') ?? 0;

  Map<String, dynamic>? get _sel {
    if (selectedId == null) return null;
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r as Map);
      if ('${m['id']}' == '$selectedId') return m;
    }
    return null;
  }

  // ==================== 页面 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PosTheme.bg,
      body: Row(children: [
        SizedBox(width: 392, child: _leftPanel()),
        Container(width: 1, color: PosTheme.line),
        Expanded(child: _rightPanel()),
      ]),
    );
  }

  // ---------- 左：下单信息 ----------

  Widget _leftPanel() {
    return Container(
      color: Colors.white,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Row(children: [
            const Text('预约点餐', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                  color: PosTheme.accent.withOpacity(0.10), borderRadius: BorderRadius.circular(20)),
              child: Text('${_c('0')} 待安排',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: PosTheme.accent)),
            ),
            const Spacer(),
            IconButton(
              onPressed: _unionQr,
              icon: const Icon(Icons.qr_code_2, size: 21),
              tooltip: '门店预约码',
            ),
            IconButton(
              onPressed: () {
                _load();
                _loadTables();
              },
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: '刷新',
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            _tabChip(0, '待安排', _c('0'), PosTheme.accent),
            const SizedBox(width: 8),
            _tabChip(1, '已安排', _c('1'), PosTheme.green),
            const SizedBox(width: 8),
            _tabChip(2, '已拒绝', _c('2'), PosTheme.textHint),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: SizedBox(
            height: 38,
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜手机号 / 称呼',
                hintStyle: const TextStyle(fontSize: 13, color: PosTheme.textHint),
                prefixIcon: const Icon(Icons.search, size: 18, color: PosTheme.textHint),
                suffixIcon: keyword.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          _searchCtrl.clear();
                          keyword = '';
                          _load();
                        },
                      ),
                filled: true,
                fillColor: PosTheme.bg,
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
              onSubmitted: (v) {
                keyword = v.trim();
                _load();
              },
            ),
          ),
        ),
        Expanded(child: _listArea()),
      ]),
    );
  }

  Widget _tabChip(int key, String label, int n, Color color) {
    final on = tab == key;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () {
          setState(() => tab = key);
          _load();
        },
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? color.withOpacity(0.10) : Colors.white,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: on ? color : PosTheme.line, width: on ? 1.4 : 1),
          ),
          child: Text(
            n > 0 ? '$label $n' : label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: on ? color : PosTheme.textSub,
            ),
          ),
        ),
      ),
    );
  }

  Widget _listArea() {
    if (loading) return const Center(child: CircularProgressIndicator(color: PosTheme.accent));
    if (error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(error, textAlign: TextAlign.center, style: const TextStyle(color: PosTheme.red, fontSize: 13)),
            const SizedBox(height: 12),
            BigButton('重新加载', onTap: _load, width: 140, height: 40),
          ]),
        ),
      );
    }
    if (rows.isEmpty) {
      return EmptyView(
        tab == 0 ? '暂无待安排的预约' : (tab == 1 ? '暂无已安排的预约' : '暂无已拒绝的预约'),
        icon: Icons.event_available_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 16),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _listCard(Map<String, dynamic>.from(rows[i] as Map)),
    );
  }

  Widget _listCard(Map<String, dynamic> r) {
    final id = int.tryParse('${r['id']}') ?? 0;
    final on = id == selectedId;
    final st = int.tryParse('${r['status']}') ?? 0;
    final stColor = const {0: PosTheme.accent, 1: PosTheme.green, 2: PosTheme.textHint}[st] ?? PosTheme.textHint;
    final stText = const {0: '待安排', 1: '已安排', 2: '已拒绝'}[st] ?? '';
    final name = '${r['contact_name'] ?? ''}'.trim();
    final phone = '${r['contact_phone'] ?? ''}'.trim();
    final arrive = '${r['arrive_time'] ?? ''}'.trim();
    final people = int.tryParse('${r['people_num'] ?? 0}') ?? 0;
    final total = double.tryParse('${r['total'] ?? 0}') ?? 0;
    final items = (r['items'] is List ? r['items'] as List : const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final dishText = items.take(3).map((e) => '${e['goods_name'] ?? e['goods_title'] ?? ''}').join('、');
    final createTime = '${r['create_time'] ?? ''}';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => selectedId = id),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent.withOpacity(0.05) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line, width: on ? 1.6 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: stColor.withOpacity(0.10), borderRadius: BorderRadius.circular(8)),
              child: Text(name.isNotEmpty ? name.substring(0, 1) : '客',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: stColor)),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(name.isNotEmpty ? name : '未留称呼',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
            ),
            if (phone.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(phone, style: const TextStyle(fontSize: 12, color: PosTheme.blue, fontWeight: FontWeight.w600)),
            ],
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: stColor.withOpacity(0.10), borderRadius: BorderRadius.circular(20)),
              child: Text(stText, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: stColor)),
            ),
          ]),
          const SizedBox(height: 7),
          Row(children: [
            if (people > 0) ...[
              _mini(Icons.people_alt_outlined, '$people 人'),
              const SizedBox(width: 10),
            ],
            if (arrive.isNotEmpty) _mini(Icons.schedule, arrive),
            const Spacer(),
            Text('¥${Fmt.money(total)}',
                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: PosTheme.accent)),
          ]),
          if (dishText.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text('$dishText${items.length > 3 ? ' 等${items.length}项' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
          ],
          if (createTime.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text('提交 $createTime', style: const TextStyle(fontSize: 11, color: PosTheme.textHint)),
          ],
        ]),
      ),
    );
  }

  Widget _mini(IconData icon, String text) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: PosTheme.textHint),
      const SizedBox(width: 3),
      Text(text, style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
    ]);
  }

  // ---------- 右：菜品清单 + 操作 ----------

  Widget _rightPanel() {
    final r = _sel;
    if (r == null) {
      return const EmptyView('选择左侧任意一条预约，查看顾客所点菜品', icon: Icons.touch_app_outlined);
    }
    final st = int.tryParse('${r['status']}') ?? 0;
    final items = (r['items'] is List ? r['items'] as List : const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final total = double.tryParse('${r['total'] ?? 0}') ?? 0;
    final name = '${r['contact_name'] ?? ''}'.trim();
    final phone = '${r['contact_phone'] ?? ''}'.trim();
    final people = int.tryParse('${r['people_num'] ?? 0}') ?? 0;
    final arrive = '${r['arrive_time'] ?? ''}'.trim();
    final remark = '${r['remark'] ?? ''}'.trim();
    final tableTitle = '${r['table_title'] ?? ''}'.trim();
    final kaitai = '${r['kaitai_id'] ?? ''}'.trim();
    final stColor = const {0: PosTheme.accent, 1: PosTheme.green, 2: PosTheme.textHint}[st] ?? PosTheme.textHint;
    final stText = const {0: '待安排', 1: '已安排', 2: '已拒绝'}[st] ?? '';

    return Column(children: [
      // 顾客信息
      Container(
        width: double.infinity,
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: stColor.withOpacity(0.10), borderRadius: BorderRadius.circular(12)),
              child: Text(name.isNotEmpty ? name.substring(0, 1) : '客',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: stColor)),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(name.isNotEmpty ? name : '未留称呼',
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration:
                      BoxDecoration(color: stColor.withOpacity(0.10), borderRadius: BorderRadius.circular(20)),
                  child: Text(stText, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: stColor)),
                ),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                if (phone.isNotEmpty)
                  Text(phone, style: const TextStyle(fontSize: 13.5, color: PosTheme.blue, fontWeight: FontWeight.w700)),
                if (phone.isNotEmpty && people > 0) const SizedBox(width: 12),
                if (people > 0)
                  Text('$people 人', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                if (arrive.isNotEmpty) ...[
                  if (phone.isNotEmpty || people > 0) const SizedBox(width: 12),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.schedule, size: 14, color: PosTheme.textHint),
                    const SizedBox(width: 3),
                    Text('到店 $arrive', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                  ]),
                ],
              ]),
            ]),
            const Spacer(),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              const Text('合计', style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              Text('¥${Fmt.money(total)}',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: PosTheme.accent)),
            ]),
          ]),
          if (st == 1 && tableTitle.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: const Color(0xFFEAF9F0), borderRadius: BorderRadius.circular(9)),
              child: Row(children: [
                const Icon(Icons.check_circle, size: 15, color: PosTheme.green),
                const SizedBox(width: 6),
                Text('已安排到「$tableTitle」${kaitai.isNotEmpty ? ' · 开台号 $kaitai' : ''}',
                    style: const TextStyle(fontSize: 12.5, color: PosTheme.green, fontWeight: FontWeight.w600)),
              ]),
            ),
          ],
          if (remark.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8EC),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0xFFF5E3C0)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.sticky_note_2_outlined, size: 15, color: Color(0xFFB7791F)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('备注：$remark',
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A6216), height: 1.5)),
                ),
              ]),
            ),
          ],
        ]),
      ),
      // 菜品清单
      Expanded(
        child: Container(
          margin: const EdgeInsets.fromLTRB(20, 14, 20, 10),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
              child: Row(children: [
                const Icon(Icons.restaurant_menu, size: 17, color: PosTheme.accent),
                const SizedBox(width: 7),
                const Text('菜品清单', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Text('共 ${items.length} 项', style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                const Spacer(),
                const Text('安排开台后菜品自动入账，不会打印；打印请到该桌点「传后厨」',
                    style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              ]),
            ),
            const Divider(height: 1, color: PosTheme.line),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('该预约没有菜品', style: TextStyle(color: PosTheme.textHint)))
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF3F4F7)),
                      itemBuilder: (_, i) => _dishRow(items[i]),
                    ),
            ),
          ]),
        ),
      ),
      // 操作栏
      Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 14),
        child: Row(children: [
          const Icon(Icons.info_outline, size: 15, color: PosTheme.textHint),
          const SizedBox(width: 6),
          const Expanded(
            child: Text('「安排开台」只开台入账，不出任何小票；需到桌台点「传后厨」才打印后厨单与前台单',
                style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
          ),
          const SizedBox(width: 12),
          if (st == 0) ...[
            SizedBox(
              width: 116,
              child: BigButton('拒绝预约', onTap: () => _reject(r),
                  color: const Color(0xFFF4F5F7), textColor: PosTheme.textSub, height: 44),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 168,
              child: BigButton('安排开台', onTap: () => _assign(r), height: 44),
            ),
          ] else if (st == 1)
            const SizedBox(
              width: 200,
              child: Text('菜品已入账单，回「点餐」到该桌点「传后厨」出票',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: PosTheme.green, fontWeight: FontWeight.w600)),
            )
          else
            const SizedBox(width: 168, child: Text('该预约已拒绝', textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: PosTheme.textHint))),
        ]),
      ),
    ]);
  }

  Widget _dishRow(Map<String, dynamic> it) {
    final title = '${it['goods_name'] ?? it['goods_title'] ?? ''}';
    final price = double.tryParse('${it['unit_price'] ?? 0}') ?? 0;
    final qty = int.tryParse('${it['quantity'] ?? 0}') ?? 0;
    final sub = double.tryParse('${it['sub_total'] ?? 0}') ?? (price * qty);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('单价 ¥${Fmt.money(price)}', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
          ]),
        ),
        SizedBox(
          width: 70,
          child: Text('× $qty',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub, fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          width: 92,
          child: Text('¥${Fmt.money(sub)}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }

  // ==================== 操作 ====================

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
    var closed = false;
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
      closed = true;
      if ('${res['code']}' != '200') {
        toast(context, '${res['msg'] ?? '开台失败'}', error: true);
        return;
      }
      // v3.3.104：只开台入账，不出任何小票；打印由桌台的「传后厨」触发
      toast(context, '已开台入账（未打印）；到该桌点「传后厨」才出票');
      await Future.wait([_load(), _loadTables()]);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (!closed) {
        Navigator.pop(context);
        closed = true;
      }
      toast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      if (!closed) {
        Navigator.pop(context);
        closed = true;
      }
      toast(context, '开台异常：$e', error: true);
    }
  }

  /// 拒绝/取消预约：无需权限码，二次确认即可（v3.3.104）
  Future<void> _reject(Map<String, dynamic> r) async {
    final ok = await confirm(context, '取消预约',
        '取消后该预约作废，顾客所点菜品不会开台也不会下到厨房。\n（此操作不需要权限码）确定取消？');
    if (!ok || !mounted) return;
    try {
      final res = await Api.preorderReject(
        wenxunId: Session.wenxunId,
        preorderId: int.tryParse('${r['id']}') ?? 0,
        operatorId: Session.staffId,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      toast(context, '${res['msg'] ?? '已取消'}');
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
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
            const Text('所有顾客扫同一个码：选菜 → 填手机号 → 提交预约\n收银员在「预约点餐」里安排开台后，菜品进账单，再点「传后厨」出票',
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
                child: BigButton('关闭',
                    onTap: () => Navigator.pop(ctx),
                    color: const Color(0xFFF4F5F7),
                    textColor: PosTheme.textSub,
                    height: 42),
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
