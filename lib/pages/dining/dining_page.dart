import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/no_code_common.dart';
import '../../core/pay_methods.dart';
import '../../core/preorder_badge.dart';
import '../../core/print_prefs.dart';
import '../../core/printer_route.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/voice.dart';
import '../../ui/brand_logos.dart';
import '../../ui/no_code_goods.dart';
import '../../ui/receipt_preview.dart';
import '../../ui/vip_recharge.dart';
import '../../ui/widgets.dart';
import '../../ui/xyf_scan_pay.dart';
import 'dining_modes.dart';
import '../retail/cashier_page.dart' show RetailCashierPage, RetailGoodsImage;

/// 餐饮版 · 点餐主页（中餐 / 面馆 / 快餐通用）
/// 桌台模式：桌台图 → 开台 → 点菜/加菜 → 结账 → 云打印
/// 快捷模式：直接点单收款（外带/快餐），落 POS 订单

/// 后厨出票共享路由（v3.3.124：按「云打印机」页的绑定配置）：
/// 1. role=kitchen 的机各自出票：cats 非空时出自己分类的菜（同分类绑多台=双打备份）；
///    cats 为空则不出票（除非开了「接收未分配分类」）；
/// 2. 未分配分类的菜：发给所有开了「接收未分配分类」的后厨机，没有则走默认后厨打印机（旧行为兜底）；
/// 3. 每台机按自己的出票方式：whole=整单合并一张 / split=一菜一切（每个菜品一张票）；
/// 4. 「米饭只打前台单」开启时过滤米饭类菜品（主食由前台单统一出，后厨不出）。
Future<void> diningPrintKitchenRouted({
  required List<Map<String, dynamic>> items,
  String tableTitle = '',
  String tableQuyu = '',
  bool isAdd = true,
  String title = '后厨单',
  String remark = '',
}) async {
  if (items.isEmpty) return;
  final wid = '${Session.wenxunId}';
  final riceOnly = await PrinterRoute.riceFrontOnly(wid);
  final kitchenItems = riceOnly
      ? items.where((it) => !PrinterRoute.isRiceItem('${it['goods_name'] ?? ''}')).toList()
      : items;
  if (kitchenItems.isEmpty) return;
  final cfgs = await PrinterRoute.printerCfgs(wid);
  final kitchens = cfgs.entries.where((e) => e.value.role == 'kitchen').toList();
  final kt = await PrinterRoute.kitchenTicketOpts(wid); // 后厨明细行开关（v3.3.135 云端配置）
  String ticket(List<Map<String, dynamic>> cart, {String font = ''}) => CloudPrinter.kitchenTicket(
      tableTitle: tableTitle, tableQuyu: tableQuyu, cart: cart,
      isAdd: isAdd, title: title, remark: remark, font: font,
      showTable: kt['table'] ?? true, showTime: kt['time'] ?? true,
      showStaff: kt['staff'] ?? true, showCount: kt['count'] ?? true);
  final futures = <Future>[];
  final taken = <Map<String, dynamic>>[]; // 已被分类绑定的菜
  void emit(String code, PrinterCfg cfg, List<Map<String, dynamic>> list) {
    if (list.isEmpty) return;
    taken.addAll(list);
    if (cfg.mode == PrinterRoute.modeSplit) {
      if (kt['merge'] ?? true) {
        // 同名同做法合并成一张（v3.3.138，可开关）：加 7 份只打一张「x7」，省纸；
        // 关闭后恢复每份一张（分拣场景）。注意在分类过滤之后合并，不影响分单路由。
        final merged = <String, Map<String, dynamic>>{};
        for (final it in list) {
          final name = '${it['goods_name'] ?? ''}';
          final note = '${it['remark'] ?? ''}'.trim();
          final key = '$name|$note';
          final qty = int.tryParse('${it['quantity']}') ?? 0;
          if (merged.containsKey(key)) {
            merged[key]!['quantity'] = (int.tryParse('${merged[key]!['quantity']}') ?? 0) + qty;
          } else {
            final m = Map<String, dynamic>.from(it);
            m['goods_name'] = name;
            m['remark'] = note;
            m['quantity'] = qty;
            merged[key] = m;
          }
        }
        for (final it in merged.values) {
          futures.add(CloudPrinter.printTo(code, ticket([it], font: cfg.font)));
        }
      } else {
        for (final it in list) {
          futures.add(CloudPrinter.printTo(code, ticket([it], font: cfg.font)));
        }
      }
    } else {
      futures.add(CloudPrinter.printTo(code, ticket(list, font: cfg.font)));
    }
  }
  // 按分类分工：同分类绑多台 = 双打备份
  for (final e in kitchens) {
    final cats = e.value.cats;
    if (cats.isEmpty) continue;
    emit(e.key, e.value, kitchenItems.where((it) => cats.contains('${it['cat_id'] ?? ''}')).toList());
  }
  // 未分配分类的菜 → 兜底/双打机
  final fallback = kitchenItems.where((it) => !taken.contains(it)).toList();
  if (fallback.isNotEmpty) {
    final backups = kitchens.where((e) => e.value.allCats).toList();
    if (backups.isNotEmpty) {
      for (final e in backups) {
        emit(e.key, e.value, fallback);
      }
    } else if (kitchens.isNotEmpty) {
      // 分类没匹配到任何绑定机（cat_id 反查失败等）：仍按绑定的后厨机方式出票，
      // 保留一菜一切/字体设置，不再退回「默认打印机整单一张」（v3.3.134 修复）
      emit(kitchens.first.key, kitchens.first.value, fallback);
    } else {
      futures.add(CloudPrinter.printKitchen(ticket(fallback)));
    }
  }
  await Future.wait(futures);
}

/// 前台单出票共享路由（v3.3.124）：
/// - 绑定 role=front 的机：每台按自己的出票方式出（whole=主单一张 / split=每菜一张），
///   绑定多台时全部出票（双打备份）；
/// - 无前台绑定机：自动选机（收银小票类型优先），整单一张（旧行为）。
Future<void> diningPrintFrontRouted({
  required List<Map<String, dynamic>> items,
  String tableTitle = '',
  String tableQuyu = '',
  bool isAdd = false,
  String title = '前台单',
  String remark = '',
}) async {
  if (items.isEmpty) return;
  final wid = '${Session.wenxunId}';
  final cfgs = await PrinterRoute.printerCfgs(wid);
  final fronts = cfgs.entries.where((e) => e.value.role == 'front').toList();
  String ticket(List<Map<String, dynamic>> cart, {String font = ''}) => CloudPrinter.kitchenTicket(
      tableTitle: tableTitle, tableQuyu: tableQuyu, cart: cart,
      isAdd: isAdd, title: title, remark: remark, font: font);
  final futures = <Future>[];
  if (fronts.isEmpty) {
    futures.add(CloudPrinter.printFront(ticket(items)));
  } else {
    for (final e in fronts) {
      if (e.value.mode == PrinterRoute.modeSplit) {
        for (final it in items) {
          futures.add(CloudPrinter.printTo(e.key, ticket([it], font: e.value.font)));
        }
      } else {
        futures.add(CloudPrinter.printTo(e.key, ticket(items, font: e.value.font)));
      }
    }
  }
  await Future.wait(futures);
}

/// 预结单等场景取前台目标机：优先绑定的前台机，无绑定返回空 = 自动选机
Future<String> diningFrontMachineCode() async {
  final cfgs = await PrinterRoute.printerCfgs('${Session.wenxunId}');
  for (final e in cfgs.entries) {
    if (e.value.role == 'front') return e.key;
  }
  return await PrinterRoute.frontPrinter('${Session.wenxunId}');
}

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
  // 预约点餐入口已移到左侧菜单「预约」（v3.3.104），顶部不再显示按钮与角标

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
    0: PosTheme.green, 1: PosTheme.amber, 2: PosTheme.accent, 3: PosTheme.blue, 4: Color(0xFFF97316),
  };
  // 待清台桌台卡片渐变（v3.3.87）：已结账但顾客可能继续就餐/加菜，醒目区分
  static const clearedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFFB75E), Color(0xFFF97316)],
  );
  // 就餐中桌台卡片渐变（v3.3.90）：红色渐变醒目
  static const busyGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF6B6B), Color(0xFFE53E3E)],
  );

  int get idleCount => tables.where((t) => '${t['status']}' == '0').length;
  int get busyCount => tables.where((t) => '${t['status']}' == '2' || '${t['status']}' == '3').length;

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // 每 20 秒静默刷新一次「预约待安排」数量（顾客随时可能提交预约，v3.3.103）
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) _loadPreorderCount();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final r = await Api.tables(Session.wenxunId);
      if (!mounted) return;
      // 拉取就餐中桌台「未起菜」统计（v3.3.111），失败不影响桌台显示
      Map<String, dynamic> kp = {};
      try {
        kp = await Api.kitchenPending(Session.wenxunId);
      } catch (_) {}
      for (final t in r) {
        if (t is! Map) continue;
        final st = kp['t${t['id']}'];
        if (st is Map) {
          t['kitchen_total'] = st['total'];
          t['kitchen_pending'] = st['pending'];
        }
      }
      setState(() { tables = r; loading = false; });
      _loadPreorderCount();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.message; });
    }
  }

  /// 预约点餐待安排数量（写入左侧导航「预约」红点，v3.3.104）
  Future<void> _loadPreorderCount() async {
    try {
      final r = await Api.preorderList(wenxunId: Session.wenxunId, status: '0');
      if (!mounted) return;
      final raw = r['data'];
      final d = raw is Map ? raw : const <String, dynamic>{};
      final c = d['counts'];
      int n = 0;
      if (c is Map) {
        n = int.tryParse('${c['0'] ?? c[0] ?? 0}') ?? 0;
      } else if (c is List && c.isNotEmpty) {
        n = int.tryParse('${c[0]}') ?? 0;
      }
      PreorderBadge.count.value = n;
      // 预约单自动打印已改为全局轮询（见 ShellPage，v3.3.152），此处只更新红点
    } catch (_) {
      // 预约模块异常不影响桌台
    }
  }

  @override
  Widget build(BuildContext context) {
    if (mode == 1) {
      // 堂食模式（原快捷模式）：直接复用零售收银（点单→收款→POS 单）
      return Column(children: [
        _topBar(),
        const Expanded(child: RetailCashierPage()),
      ]);
    }
    return Column(children: [
      _topBar(),
      _regionBar(),
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

  // ==================== 顶栏（v3.3.65：模式切换合并进点餐方式一行，去掉独立按钮） ====================

  static const List<Map<String, dynamic>> _orderModes = [
    {'label': '开台点餐', 'color': PosTheme.red},
    {'label': '堂食模式', 'color': Color(0xFFFF7A45)},
    {'label': '排队取号', 'color': PosTheme.blue},
    {'label': '挂账点餐', 'color': PosTheme.red},
  ];

  Widget _topBar() {
    return Container(
      height: 48,
      margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(children: [
        const Text('点餐方式', style: TextStyle(fontSize: 13.5, color: PosTheme.textHint)),
        const SizedBox(width: 12),
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [for (final m in _orderModes) _orderModeChip(m)],
          ),
        ),
        if (mode == 0) ...[
          const SizedBox(width: 12),
          _legend('空闲 $idleCount', PosTheme.green),
          const SizedBox(width: 12),
          _legend('就餐中 $busyCount', PosTheme.accent),
          const SizedBox(width: 12),
          _legend('已预定 ${tables.where((t) => '${t['status']}' == '1').length}', PosTheme.amber),
          const SizedBox(width: 12),
          _legend('待清台 ${tables.where((t) => '${t['status']}' == '4').length}', const Color(0xFFF97316)),
          const SizedBox(width: 14),
          // 餐饮交班对账入口已移到「交班页」（v3.3.77）
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

  Widget _orderModeChip(Map<String, dynamic> m) {
    final label = '${m['label']}';
    final c = m['color'] as Color;
    // 开台点餐 / 堂食模式 是当前生效模式时高亮
    final on = (label == '开台点餐' && mode == 0) || (label == '堂食模式' && mode == 1);
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _openOrderMode(label),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          decoration: BoxDecoration(
            color: on ? c : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: on ? c : PosTheme.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 9, height: 9, decoration: BoxDecoration(color: on ? Colors.white : c, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
          ]),
        ),
      ),
    );
  }

  Future<void> _openOrderMode(String label) async {
    switch (label) {
      case '开台点餐':
        // 只切回桌台视图，开台需先点桌台卡片再弹人数弹窗（v3.3.66）
        setState(() => mode = 0);
        break;
      case '堂食模式':
        setState(() => mode = 1);
        break;
      case '排队取号':
        await showDialog(context: context, builder: (_) => const PaihaoDialog());
        break;
      case '挂账点餐':
        await showDialog(context: context, builder: (_) => const GuazhangDialog());
        break;
    }
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
    final pending = int.tryParse('${t['pending'] ?? 0}') ?? 0; // 顾客扫码待确认预点单数（v3.3.101）
    final c = statusColor[st] ?? PosTheme.textHint;
    final open = st == 0 || st == 3;
    final busy = st == 2;
    final cleared = st == 4; // 已结账待清台：渐变卡片，可继续加菜/清台（v3.3.87）
    // 未起菜统计（v3.3.111）：全部未传后厨 → 等待中·未起菜；部分未传 → 提示 N 道未起菜
    final kTotal = int.tryParse('${t['kitchen_total'] ?? 0}') ?? 0;
    final kPending = int.tryParse('${t['kitchen_pending'] ?? 0}') ?? 0;
    final notStarted = busy && kTotal > 0 && kPending >= kTotal;
    final partially = busy && kPending > 0 && kPending < kTotal;
    final stLabel = notStarted ? '等待中 · 未起菜' : statusText[st]!;
    final bookInfo = st == 1
        ? '${('${t['book_operator_name'] ?? ''}')} ${('${t['book_time'] ?? ''}')}'.trim()
        : '';
    // 并台来源桌台名（v3.3.93）：如 "3,5" → "3、5"
    final mergeText = '${t['merge_titles'] ?? ''}'
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join('、');
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          // 有顾客扫码预点单：优先处理确认开台（v3.3.101）
          if (pending > 0) {
            _pendingSheet(t);
            return;
          }
          if (open) {
            // 扫码点餐桌（状态3）若顾客已下单（有开台号），直接进账单面板；
            // 空闲桌弹操作面板（开台点餐/预定桌台/预约点餐）；扫码未下单桌直接开台
            final kt = '${t['kaitai_id'] ?? ''}';
            if (st == 3 && kt.isNotEmpty) {
              _dishPanel(t, kt);
            } else if (st == 0) {
              _idleActionSheet(t);
            } else {
              _openTableDialog(t);
            }
          } else if (busy) {
            _tableActionSheet(t);
          } else if (st == 1) {
            _bookedActionSheet(t);
          } else if (cleared) {
            _clearedActionSheet(t);
          } else {
            toast(context, '该桌状态：${statusText[st]}');
          }
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(
            gradient: cleared
                ? clearedGradient
                : busy
                    ? busyGradient
                    : null,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: pending > 0
                    ? const Color(0xFFEF4444)
                    : (cleared || busy) ? Colors.white.withOpacity(0.35) : c.withOpacity(0.45),
                width: pending > 0 ? 2 : 1.6),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 9, height: 9, decoration: BoxDecoration(color: (cleared || busy) ? Colors.white : c, shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text(stLabel, style: TextStyle(fontSize: 12, color: (cleared || busy) ? Colors.white : c, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (pending > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFEF4444), borderRadius: BorderRadius.circular(20)),
                  child: Text('顾客预点 $pending', style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w800)),
                ),
            ]),
            const Spacer(),
            Text('${t['title']}', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: (cleared || busy) ? Colors.white : null)),
            if (bookInfo.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text('预定 $bookInfo', style: const TextStyle(fontSize: 11, color: PosTheme.amber), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            if (busy) ...[
              const SizedBox(height: 2),
              Text('消费 ¥${Fmt.money(t['zongjine'] ?? 0)}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white.withOpacity(0.95))),
              if (notStarted) ...[
                const SizedBox(height: 1),
                Text('菜品 $kTotal 道待传后厨 · 点击可传后厨', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.85))),
              ] else if (partially) ...[
                const SizedBox(height: 1),
                Text('$kPending 道未起菜 · 点击可传后厨', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.85))),
              ],
              if (mergeText.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text('并入 $mergeText', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.9))),
              ],
            ],
            if (cleared) ...[
              const SizedBox(height: 2),
              Text('已结账 · 可继续加菜', style: TextStyle(fontSize: 11.5, color: Colors.white.withOpacity(0.9))),
              if (mergeText.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text('并入 $mergeText', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.85))),
              ],
            ],
          ]),
        ),
      ),
    );
  }

  // ==================== 顾客扫码预点餐（v3.3.101） ====================

  /// 全店待确认的顾客预点单总数（顶栏提示用）
  /// 顾客扫码预点单确认面板（一桌可能有多条，逐条同意/拒绝）
  Future<void> _pendingSheet(Map t) async {
    List<Map<String, dynamic>> rows;
    try {
      final r = await Api.preorderPending(wenxunId: Session.wenxunId);
      final data = (r['data'] ?? {}) as Map;
      rows = ((data['list'] ?? []) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) => '${e['table_id']}' == '${t['id']}')
          .toList();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
      return;
    }
    if (!mounted) return;
    if (rows.isEmpty) {
      toast(context, '该桌暂无待确认的预点单');
      _load();
      return;
    }
    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: Container(
          width: 580,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${t['title']} · 顾客预点单', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const Spacer(),
              IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
            ]),
            const Text('顾客扫码提交，确认后才会下单到厨房并出票', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final items = ((r['items'] ?? []) as List)
                      .whereType<Map>()
                      .map((e) => Map<String, dynamic>.from(e))
                      .toList();
                  final total = double.tryParse('${r['total'] ?? 0}') ?? 0;
                  final people = int.tryParse('${r['people_num']}') ?? 0;
                  final remark = '${r['remark'] ?? ''}';
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF9F6),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: PosTheme.accent.withOpacity(0.3)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text('${r['create_time'] ?? ''}', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                        if (people > 0) ...[
                          const SizedBox(width: 8),
                          Text('$people 人', style: const TextStyle(fontSize: 11.5, color: PosTheme.blue, fontWeight: FontWeight.w600)),
                        ],
                        const Spacer(),
                        Text('¥${Fmt.money(total)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: PosTheme.accent)),
                      ]),
                      const SizedBox(height: 6),
                      ...items.map((it) {
                        final sub = double.tryParse('${it['sub_total'] ?? 0}') ?? 0;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: Row(children: [
                            Expanded(child: Text('${it['goods_name'] ?? it['goods_title'] ?? ''}', style: const TextStyle(fontSize: 13))),
                            Text('×${it['quantity']}', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 66,
                              child: Text('¥${Fmt.money(sub)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                            ),
                          ]),
                        );
                      }),
                      if (remark.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('备注：$remark', style: const TextStyle(fontSize: 12, color: PosTheme.amber)),
                      ],
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(
                          child: BigButton('拒绝',
                              onTap: () => _rejectPending(ctx, r),
                              color: const Color(0xFFF4F5F7), textColor: PosTheme.textSub, height: 40),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: BigButton('同意并开台',
                              onTap: () => _approvePending(ctx, r, t, people), height: 40),
                        ),
                      ]),
                    ]),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// 同意顾客预点单：开台/追加菜品 → 后厨+前台出票 → 刷新桌台
  Future<void> _approvePending(BuildContext ctx, Map r, Map t, int people) async {
    Navigator.pop(ctx);
    final pnum = people > 0 ? people : (int.tryParse('${t['kaitai_people'] ?? 1}') ?? 1);
    loadingDialog(context, '开台中…');
    try {
      final res = await Api.preorderApprove(
        wenxunId: Session.wenxunId,
        preorderId: int.tryParse('${r['id']}') ?? 0,
        peopleNum: pnum,
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
      final items = ((d['items'] ?? []) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      toast(context, '${res['msg'] ?? '已同意并开台'}');
      // 出票：后厨按分类路由（可多台分单）+ 前台整单一张（与 v3.3.99 规则一致）
      if (items.isNotEmpty) _printScannedOrder(items, t);
      setState(() {});
      _load();
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, e.message, error: true);
    }
  }

  /// 拒绝顾客预点单
  Future<void> _rejectPending(BuildContext ctx, Map r) async {
    Navigator.pop(ctx);
    final ok = await confirm(context, '拒绝预点单', '拒绝后顾客所点菜品不会开台，确定？');
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
      _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  /// 顾客扫码预点菜品出票（后厨分单路由 + 前台整单）
  Future<void> _printScannedOrder(List<Map<String, dynamic>> items, Map t) async {
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
      final tableTitle = '${t['title'] ?? ''}';
      final quyu = '${t['quyu'] ?? ''}';
      if (await PrintPrefs.on('kitchen')) {
        await diningPrintKitchenRouted(
          items: cart,
          tableTitle: tableTitle,
          tableQuyu: quyu,
          isAdd: true,
          title: '后厨单',
        );
      }
      if (await PrintPrefs.on('front')) {
        await diningPrintFrontRouted(items: cart, tableTitle: tableTitle, tableQuyu: quyu);
      }
    } catch (_) {
      // 打印失败不影响开台
    }
  }

  // ==================== 空闲桌操作面板（开台点餐 / 预定桌台 / 预约点餐，v3.3.91） ====================
  Future<void> _idleActionSheet(Map t) async {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${t['title']} · 空闲', textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('选择本桌的下一步操作', textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
          const SizedBox(height: 18),
          BigButton('开台点餐', onTap: () { Navigator.pop(context); _openTableDialog(t); }, height: 50),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: BigButton('预定桌台', onTap: () { Navigator.pop(context); _bookTable(t); }, color: const Color(0xFFFFF8EC), textColor: PosTheme.amber, height: 46)),
            const SizedBox(width: 10),
            Expanded(child: BigButton('预约点餐', onTap: () { Navigator.pop(context); _openPreorder(t); }, color: const Color(0xFFF0F6FF), textColor: PosTheme.blue, height: 46)),
          ]),
        ]),
      )),
    );
  }

  // 纯预定桌台（不点菜，0→1）
  Future<void> _bookTable(Map t) async {
    try {
      final r = await Api.tableBook(
        wenxunId: Session.wenxunId,
        tableId: int.tryParse('${t['id']}') ?? 0,
        operatorId: Session.staffId,
        operatorName: Session.staffName.isEmpty ? '收银员' : Session.staffName,
      );
      if (!mounted) return;
      if ('${r['code']}' == '200') {
        toast(context, '已预定「${t['title']}」');
      } else {
        toast(context, '${r['msg'] ?? '预定失败'}');
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      toast(context, e.message);
    }
    _load();
  }

  // ==================== 开台（点桌台图 → 人数数字键盘弹窗，v3.3.67） ====================
  Future<void> _openTableDialog(Map t) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => KaitaiKeypadDialog(
        table: t,
        onPreorder: (t2) => _openPreorder(t2), // 弹窗内可查看/修改预点单（v3.3.90）
        onOpened: (t2, kaitaiId) async {
          await _load();
          if (!mounted) return;
          final nt = tables.firstWhere((x) => '${x['id']}' == '${t2['id']}', orElse: () => t2);
          _dishPanel(nt, kaitaiId);
        },
      ),
    );
  }

  // ==================== 就餐中桌台操作 ====================
  Future<void> _tableActionSheet(Map t) async {
    final kaitaiId = '${t['kaitai_id'] ?? ''}';
    // v3.3.115：传后厨统一在账单面板内操作（带打印+数量显示），
    // 此处不再提供只改状态的传后厨入口（避免菜品不打印就被标记已传）
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${t['title']} · 就餐中', textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 18),
          BigButton('查看账单 / 传后厨 / 加菜 / 结账', onTap: () { Navigator.pop(context); _dishPanel(t, kaitaiId); }, height: 50),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: BigButton('转台', onTap: () { Navigator.pop(context); _changeTable(t); }, color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 46)),
            const SizedBox(width: 10),
            Expanded(child: BigButton('并台', onTap: () { Navigator.pop(context); _mergeTable(t); }, color: const Color(0xFFF0F6FF), textColor: PosTheme.blue, height: 46)),
            const SizedBox(width: 10),
            Expanded(child: BigButton('取消开台', onTap: () { Navigator.pop(context); _cancelOpen(t, kaitaiId); }, color: const Color(0xFFFFF1F0), textColor: PosTheme.red, height: 46)),
          ]),
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
          BigButton('预点餐 / 改菜', onTap: () { Navigator.pop(context); _openPreorder(t); }, color: const Color(0xFFFFF8EC), textColor: PosTheme.amber, height: 46),
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

  // ==================== 待清台（已结账）桌台操作（v3.3.87） ====================
  Future<void> _clearedActionSheet(Map t) async {
    final kaitaiId = '${t['kaitai_id'] ?? ''}';
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${t['title']} · 待清台', textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('已结账，顾客可能继续就餐或加菜', textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
          const SizedBox(height: 18),
          if (kaitaiId.isNotEmpty) ...[
            BigButton('继续点餐 / 加菜 / 再结算', onTap: () { Navigator.pop(context); _dishPanel(t, kaitaiId); }, height: 50),
            const SizedBox(height: 10),
          ],
          BigButton('清台（顾客离店后恢复空闲）', onTap: () { Navigator.pop(context); _clearTable(t); }, color: const Color(0xFFFFF4EC), textColor: const Color(0xFFF97316), height: 46),
        ]),
      )),
    );
  }

  // 清台：待清台桌台恢复空闲（有未结算加菜时后端会拦截）
  Future<void> _clearTable(Map t) async {
    final ok = await confirm(context, '确认清台', '「${t['title']}」已结账，确认顾客已离店并清台？清台后恢复为空闲桌台。');
    if (!ok || !mounted) return;
    loadingDialog(context, '清台中…');
    try {
      final r = await Api.tableQingtai(
        wenxunId: Session.wenxunId,
        tableId: int.tryParse('${t['id']}') ?? 0,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        toast(context, '已清台');
        _load();
      } else {
        toast(context, '${r['msg'] ?? '清台失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
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
        // 后厨小票（不阻塞后续流程；走共享路由：米饭过滤 + 整单/一菜一切）
        if (await PrintPrefs.on('kitchen')) {
          diningPrintKitchenRouted(
            items: items.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList(),
            tableTitle: '${t['title']}',
            tableQuyu: '${t['quyu'] ?? ''}',
            remark: remark,
            title: '预点出菜单',
          ).catchError((_) => <String, dynamic>{});
        }
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

  // ==================== 并台（v3.3.71）：本桌菜品并入其他就餐中桌台 ====================
  Future<void> _mergeTable(Map t) async {
    final kaitaiId = '${t['kaitai_id'] ?? ''}';
    if (kaitaiId.isEmpty) return;
    // 目标：其他就餐中桌台
    final candidates = tables.where((x) => '${x['status']}' == '2' && '${x['id']}' != '${t['id']}' && '${x['kaitai_id'] ?? ''}'.isNotEmpty).toList();
    if (candidates.isEmpty) {
      toast(context, '没有其他就餐中的桌台可并', error: true);
      return;
    }
    final target = await showDialog<Map>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('并台 · ${t['title']} 并入'),
        content: SizedBox(width: 380, height: 360, child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 110, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1.1),
          itemCount: candidates.length,
          itemBuilder: (_, i) => InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => Navigator.pop(context, candidates[i]),
            child: Container(
              decoration: BoxDecoration(color: const Color(0xFFF0F6FF), borderRadius: BorderRadius.circular(10), border: Border.all(color: PosTheme.blue.withOpacity(0.4))),
              child: Center(child: Text('${candidates[i]['title']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            ),
          ),
        )),
      ),
    );
    if (target == null || !mounted) return;
    final ok = await confirm(context, '确认并台', '「${t['title']}」的全部菜品将并入「${target['title']}」账单，本桌恢复空闲。确定？');
    if (!ok || !mounted) return;
    loadingDialog(context, '并台中…');
    try {
      final r = await Api.tableMerge(
        wenxunId: Session.wenxunId,
        sourceKaitaiId: kaitaiId,
        targetKaitaiId: '${target['kaitai_id'] ?? ''}',
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        final srcTitle = r['data']?['source_table_title'] ?? t['title'];
        toast(context, '「$srcTitle」已并入 ${r['data']?['target_table_title'] ?? target['title']}');
        _load();
      } else {
        toast(context, '${r['msg'] ?? '并台失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 取消开台（6位权限码数字键盘，v3.3.92） ====================
  Future<void> _cancelOpen(Map t, String kaitaiId) async {
    final pwd = await showDialog<String>(
      context: context,
      builder: (_) => _CancelOpenPwdDialog(table: t),
    );
    if (pwd == null || pwd.isEmpty || !mounted) return;
    loadingDialog(context, '处理中…');
    try {
      final r = await Api.tableCancelOpen(
        wenxunId: Session.wenxunId,
        tableId: int.tryParse('${t['id']}') ?? 0,
        kaitaiId: kaitaiId,
        operatorId: Session.staffId,
        password: pwd,
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

/// 取消开台权限码弹窗：6 位圆点 + 九宫格数字键盘（触摸屏，v3.3.92）
class _CancelOpenPwdDialog extends StatefulWidget {
  final Map table;
  const _CancelOpenPwdDialog({required this.table});
  @override
  State<_CancelOpenPwdDialog> createState() => _CancelOpenPwdDialogState();
}

class _CancelOpenPwdDialogState extends State<_CancelOpenPwdDialog> {
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
    if (pwd.length != 6) {
      toast(context, '请输入6位数字权限密码（由商户在设置页分配）', error: true);
      return;
    }
    Navigator.pop(context, pwd);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('取消开台', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${widget.table['title']} · 未点菜才可取消',
                  style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            InkWell(
              onTap: () => Navigator.pop(context),
              child: const Icon(Icons.close, size: 24, color: PosTheme.textHint),
            ),
          ]),
          const SizedBox(height: 18),
          // 6 位圆点显示框
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
                    : Row(mainAxisAlignment: MainAxisAlignment.start, children: [
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
              if (pwd.isNotEmpty)
                InkWell(
                  onTap: () => _key('C'),
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text('清空', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
                  ),
                ),
              const SizedBox(width: 8),
            ]),
          ),
          const SizedBox(height: 12),
          // 九宫格数字键盘
          _pad(),
          const SizedBox(height: 14),
          BigButton('确认取消开台', onTap: _confirm, color: PosTheme.red, height: 50),
        ]),
      ),
    );
  }

  Widget _pad() {
    Widget keyBtn(String label, {VoidCallback? onTap, Color? color, IconData? icon}) {
      final enabled = onTap != null;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            color: enabled ? (color ?? Colors.white) : PosTheme.bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: PosTheme.line),
          ),
          alignment: Alignment.center,
          child: icon != null
              ? Icon(icon, size: 24, color: enabled ? PosTheme.textMain : PosTheme.textHint)
              : Text(label, style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w700,
                  color: enabled ? (color ?? PosTheme.textMain) : PosTheme.textHint)),
        ),
      );
    }

    return Column(children: [
      for (var row = 0; row < 4; row++) ...[
        if (row > 0) const SizedBox(height: 8),
        Row(children: [
          for (var col = 0; col < 3; col++) ...[
            if (col > 0) const SizedBox(width: 8),
            Expanded(
              child: row < 3
                  ? keyBtn('${row * 3 + col + 1}', onTap: () => _key('${row * 3 + col + 1}'))
                  : (col == 0
                      ? keyBtn('清空', onTap: pwd.isEmpty ? null : () => _key('C'), color: const Color(0xFFF2F3F7))
                      : (col == 1
                          ? keyBtn('0', onTap: () => _key('0'))
                          : keyBtn('退格', onTap: pwd.isEmpty ? null : () => _key('<'),
                              icon: Icons.backspace_outlined))),
            ),
          ],
        ]),
      ],
    ]);
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
  String orderRemark = ''; // 整单备注（v3.3.71）
  // 商品搜索（名称/简拼，v3.3.75）
  final searchCtrl = TextEditingController();
  String keyword = '';
  List allGoods = []; // 全部商品缓存（首次搜索时拉取）
  bool allGoodsLoading = false;
  // 待传后厨清单（v3.3.99）：点菜/加菜只入账不出票，
  // 点「传后厨」才统一打印（后厨按分类路由 + 前台整单一张）
  // v3.3.115：待传状态持久化到后端 is_xiachu 字段（下单=0，打印传后厨=1），
  // 账单面板关闭重开数量不丢（内存清单方案已废弃）
  int get _pendingCount {
    int n = 0;
    for (final b in bill) {
      if ('${b['is_xiachu'] ?? 1}' == '0') {
        final remain = (int.tryParse('${b['quantity']}') ?? 0) - (int.tryParse('${b['refund_num']}') ?? 0);
        if (remain > 0) n += remain;
      }
    }
    return n;
  }

  /// 会员可用余额（现金余额 + 赠送余额）
  double _vipBalance() {
    if (vip == null) return 0;
    final a = double.tryParse('${vip!['amount'] ?? 0}') ?? 0;
    final g = double.tryParse('${vip!['gift_balance'] ?? 0}') ?? 0;
    return a + g;
  }

  // 结账中转：加菜后的菜品也进 bill（已退/部分退按剩余件数，退完的行剔除，v3.3.70）
  List<Map<String, dynamic>> get settleCart {
    final out = <Map<String, dynamic>>[];
    for (final b in bill) {
      final remain = (int.tryParse('${b['quantity']}') ?? 0) - (int.tryParse('${b['refund_num']}') ?? 0);
      if (remain <= 0) continue;
      out.add({
        'goods_id': b['goods_id'],
        'goods_name': b['goods_title'],
        'goods_image': b['goods_image'] ?? '',
        'unit_price': b['unit_price'],
        'quantity': remain,
        'remark': b['remark'] ?? '',
      });
    }
    return out;
  }

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
      // v3.3.87：已结算明细（order_id>0，待清台后继续加菜场景）不参与再结算，
      // 账单面板与结算金额只统计未结算部分（order_id=0）
      final all = (r['list'] ?? []) as List;
      final unpaid = all.where((e) => '${(e as Map)['order_id'] ?? 0}' == '0').toList();
      final merged = _mergeBill(unpaid);
      setState(() {
        bill = merged;
        billTotal = merged.fold<double>(0, (s, b) => s + (double.tryParse('${b['sub_total']}') ?? 0));
        loading = false;
      });
    } on ApiError {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  /// 同菜合并累计（v3.3.74）：goods_id+单价+做法 相同的明细行合并为一条，
  /// 并按下单时间分成「点菜」（开台后 10 分钟内）与「加菜」（之后）两组分别显示。
  /// 合并行保留 _items 原始明细，退菜/划菜按明细行逐条操作。
  List<Map<String, dynamic>> _mergeBill(List raw) {
    if (raw.isEmpty) return [];
    DateTime? first;
    for (final it in raw) {
      final t = DateTime.tryParse('${it['create_time']}'.replaceAll(' ', 'T'));
      if (t != null && (first == null || t.isBefore(first))) first = t;
    }
    final map = <String, Map<String, dynamic>>{};
    final order = <String>[];
    for (final row in raw) {
      final it = row as Map;
      final t = DateTime.tryParse('${it['create_time']}'.replaceAll(' ', 'T'));
      final isAdd = first != null && t != null && t.difference(first).inMinutes >= 10;
      final key = '${it['goods_id']}|${it['goods_title']}|${it['unit_price']}|${it['remark'] ?? ''}|$isAdd';
      if (!map.containsKey(key)) {
        final m = Map<String, dynamic>.from(it);
        m['_items'] = [it];
        m['is_add'] = isAdd;
        map[key] = m;
        order.add(key);
      } else {
        final m = map[key]!;
        (m['_items'] as List).add(it);
        m['quantity'] = (int.tryParse('${m['quantity']}') ?? 0) + (int.tryParse('${it['quantity']}') ?? 0);
        m['refund_num'] = (int.tryParse('${m['refund_num']}') ?? 0) + (int.tryParse('${it['refund_num']}') ?? 0);
        m['sub_total'] = ((double.tryParse('${m['sub_total']}') ?? 0) + (double.tryParse('${it['sub_total']}') ?? 0)).toStringAsFixed(2);
        if ('${it['is_chu']}' != '1') m['is_chu'] = 0; // 全部已出才算已出
        if ('${it['is_xiachu'] ?? 1}' != '1') m['is_xiachu'] = 0; // 任一未传后厨即算未传（v3.3.115）
      }
    }
    return order.map((k) => map[k]!).toList();
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

  /// 搜索输入：首次搜索时拉全量商品（含 jianpin），按名称/简拼过滤（v3.3.75）
  Future<void> _onSearch(String v) async {
    setState(() => keyword = v);
    if (allGoods.isEmpty && !allGoodsLoading) {
      allGoodsLoading = true;
      try {
        final r = await Api.goodsAll(Session.wenxunId);
        if (!mounted) return;
        setState(() => allGoods = (r['goods'] ?? []) as List);
      } on ApiError {
        // 拉取失败则搜索只作用于当前分类商品
      }
      allGoodsLoading = false;
    }
  }

  /// 网格展示的商品：搜索模式=全量过滤（名称/简拼，忽略大小写），否则=当前分类
  List get _gridGoods {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return dishes;
    final pool = allGoods.isNotEmpty ? allGoods : dishes;
    return pool.where((g) {
      final title = '${g['title'] ?? ''}'.toLowerCase();
      final jp = '${g['jianpin'] ?? ''}'.toLowerCase();
      return title.contains(kw) || (jp.isNotEmpty && jp.contains(kw));
    }).toList();
  }

  Future<void> _addDish(Map g, {String note = ''}) => _pushDishes([{
    'goods_id': g['id'],
    'goods_name': g['title'],
    'goods_image': g['goods_image'] ?? '',
    'unit_price': double.tryParse('${g['amount'] ?? g['price']}') ?? 0,
    'quantity': 1,
    'cat_id': g['cat_id'] ?? '', // 后厨分单路由用（v3.3.82）
    if (note.isNotEmpty) 'remark': note,
  }], label: note.isEmpty ? '${g['title']}' : '${g['title']}($note)');

  /// 做法备注点菜：长按商品 → 选常用做法（免辣/少辣等）+ 自定义 → 带备注加入（v3.3.71）
  Future<void> _addDishWithNote(Map g) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _DishNoteDialog(title: '${g['title']}'),
    );
    if (note == null || !mounted) return; // note 为空串=不带备注直接加
    _addDish(g, note: note);
  }

  /// 修改做法（v3.3.141）：账单行「做」按钮，仅未传后厨的明细可改
  /// 保存后做法随「传后厨」一起打到后厨单（后厨票做法行必打）
  Future<void> _editZuofa(Map b) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _DishNoteDialog(
        title: '${b['goods_title']}',
        initial: '${b['remark'] ?? ''}',
        confirmText: '保存做法',
      ),
    );
    if (note == null || !mounted) return;
    final ids = b['_items'] is List
        ? (b['_items'] as List).map((it) => int.tryParse('${it['id']}') ?? 0).where((i) => i > 0).toList()
        : [int.tryParse('${b['id']}') ?? 0];
    if (ids.isEmpty) return;
    try {
      final r = await Api.tableItemZuofa(
        wenxunId: Session.wenxunId,
        kaitaiId: widget.kaitaiId,
        itemIds: ids,
        remark: note,
      );
      final updated = int.tryParse('${r['data']?['updated'] ?? 0}') ?? 0;
      if ('${r['code']}' == '200' && updated > 0) {
        toast(context, note.isEmpty ? '已清除做法' : '已保存做法：$note');
        _loadBill();
      } else {
        toast(context, '${r['msg'] ?? '菜品已传后厨，做法不可修改'}', error: true);
      }
    } on ApiError catch (e) {
      toast(context, e.message, error: true);
    }
  }

  /// 催菜：向后厨云打印机打催菜单（v3.3.71）
  Future<void> _urge(Map b) async {    final remain = (int.tryParse('${b['quantity']}') ?? 0) - (int.tryParse('${b['refund_num']}') ?? 0);
    if (remain <= 0) return;
    if (!await PrintPrefs.on('urge')) {
      toast(context, '催菜单打印已关闭（设置 → 小票打印设置）');
      return;
    }
    try {
      await _printKitchenRouted([{
        'goods_name': b['goods_title'],
        'quantity': remain,
        'remark': b['remark'] ?? '',
        'cat_id': _catOf(b['goods_id']),
      }], isAdd: false, title: '催菜单');
      if (mounted) toast(context, '已催菜：${b['goods_title']}');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  /// 出品划菜：标记该菜品后厨已出（v3.3.71；v3.3.74 合并行按明细逐条标记）
  Future<void> _chuhua(Map b) async {
    final target = '${b['is_chu']}' == '1' ? false : true;
    try {
      String? err;
      final ids = b['_items'] is List
          ? (b['_items'] as List).map((it) => int.tryParse('${it['id']}') ?? 0).where((i) => i > 0).toList()
          : [int.tryParse('${b['id']}') ?? 0];
      for (final id in ids) {
        final r = await Api.tableChuhua(
          wenxunId: Session.wenxunId,
          kaitaiId: widget.kaitaiId,
          itemId: id,
          isChu: target,
        );
        if ('${r['code']}' != '200') {
          err = '${r['msg'] ?? '操作失败'}';
          break;
        }
      }
      if (!mounted) return;
      if (err == null) {
        _loadBill();
      } else {
        toast(context, err, error: true);
      }
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  /// 整单备注（v3.3.71）
  Future<void> _editOrderRemark() async {
    final r = await showDialog<String>(
      context: context,
      builder: (_) => _OrderRemarkDialog(initial: orderRemark),
    );
    if (r == null || !mounted) return;
    setState(() => orderRemark = r);
  }

  /// 全部划菜（v3.3.71）
  Future<void> _chuhuaAll() async {
    try {
      final r = await Api.tableChuhua(wenxunId: Session.wenxunId, kaitaiId: widget.kaitaiId, itemId: 0, isChu: true);
      if (!mounted) return;
      if ('${r['code']}' == '200') {
        toast(context, '已全部划菜');
        _loadBill();
      } else {
        toast(context, '${r['msg'] ?? '操作失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  /// 无码菜品：手输名称/单价/数量，直接加到桌台账单
  Future<void> _noCodeDish() async {
    final r = await showDialog<Map>(
      context: context,
      builder: (_) => const NoCodeGoodsDialog(title: '无码菜品'),
    );
    if (r == null || !mounted) return;
    final ok = await _pushDishes([{
      'goods_id': 0, // 无码菜品没有商品 id，后端强转 int 为 0
      'goods_name': r['name'],
      'goods_image': '',
      'unit_price': r['amount'],
      'quantity': r['num'],
    }], label: '${r['name']}×${r['num']}');
    // 加菜成功的无码菜品记入「常用」（v3.3.178）
    if (ok) await NoCodeCommon.add('${r['name']}');
  }

  /// 统一加菜入口：请求后端 → 暂存待传清单 → 刷新账单
  /// （v3.3.99 起加菜不再即时打印，点「传后厨」统一出票，避免一菜一票浪费纸）
  /// 返回是否成功（v3.3.178 无码菜品常用记录用）
  Future<bool> _pushDishes(List<Map<String, dynamic>> cart, {required String label}) async {
    loadingDialog(context, '加菜中…');
    try {
      final r = await Api.tableAddDish(
        wenxunId: Session.wenxunId,
        kaitaiId: widget.kaitaiId,
        cart: cart,
      );
      if (!mounted) return false;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        toast(context, '已加：$label');
        // 后端已将新菜标记为「未传后厨」（is_xiachu=0，v3.3.115），
        // 重拉账单后「传后厨(N)」数量自动包含，无需内存暂存
        _loadBill();
        return true;
      } else {
        toast(context, '${r['msg'] ?? '加菜失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
    return false;
  }

  // ==================== 打印路由（v3.3.82：多台云打印机分配） ====================

  /// 商品所属分类 id（从全量/当前分类商品缓存中查；查不到返回空 = 走默认后厨机）
  String _catOf(dynamic goodsId) {
    for (final src in [allGoods, dishes]) {
      for (final g in src) {
        if ('${g['id']}' == '$goodsId') return '${g['cat_id'] ?? catId}';
      }
    }
    return '';
  }

  /// 按分类路由打后厨小票（v3.3.123 改走共享路由：米饭过滤 + 后厨模式整单/一菜一切）
  Future<void> _printKitchenRouted(List<Map<String, dynamic>> items, {bool isAdd = true, String title = '后厨单'}) async {
    if (items.isEmpty) return;
    await diningPrintKitchenRouted(
      items: items,
      tableTitle: '${widget.table['title']}',
      tableQuyu: '${widget.table['quyu'] ?? ''}',
      isAdd: isAdd,
      title: title,
    );
  }

  /// 传后厨（v3.3.115）：
  /// 有未传菜品（后端 is_xiachu=0，跨面板关闭持久）→ 后厨按分类路由出票 + 前台整单一张，
  /// 打印成功后调后端置为已传；无未传菜品 → 兜底走「补打未出品」
  Future<void> _sendKitchen() async {
    if (_pendingCount > 0) {
      await _sendPendingKitchen();
      return;
    }
    await _reprintKitchen();
  }

  /// 传送未传菜品：后厨单按「打印机分配」路由（后厨可一菜一出），前台固定整单一张
  Future<void> _sendPendingKitchen() async {
    // 从账单原始行收集未传后厨菜品（含分类 id，供后厨分单路由）
    final items = <Map<String, dynamic>>[];
    for (final b in bill) {
      if ('${b['is_xiachu'] ?? 1}' != '0') continue;
      for (final row in ((b['_items'] ?? []) as List)) {
        final m = Map<String, dynamic>.from(row as Map);
        final remain = (int.tryParse('${m['quantity']}') ?? 0) - (int.tryParse('${m['refund_num']}') ?? 0);
        if (remain <= 0) continue;
        m['quantity'] = remain;
        // 后端明细行字段是 goods_title，打印模板读 goods_name，必须映射（v3.3.116 修复合计件数 0）
        m['goods_name'] = '${m['goods_title'] ?? m['goods_name'] ?? ''}';
        if ('${m['cat_id'] ?? ''}'.isEmpty) m['cat_id'] = _catOf(m['goods_id']); // 空串也反查（v3.3.134）
        items.add(m);
      }
    }
    if (items.isEmpty) {
      await _reprintKitchen();
      return;
    }
    final kitchenOn = await PrintPrefs.on('kitchen');
    final frontOn = await PrintPrefs.on('front');
    if (!kitchenOn && !frontOn) {
      toast(context, '后厨单与前台单打印均已关闭（设置 → 小票打印设置）');
      return;
    }
    try {
      if (kitchenOn) {
        await _printKitchenRouted(items, isAdd: true, title: '后厨单');
      }
      if (frontOn) {
        // 前台单走绑定配置（v3.3.124）：绑定前台机按各自方式出票（多台双打），无绑定自动选机整单一张
        await diningPrintFrontRouted(
          items: items,
          tableTitle: '${widget.table['title']}',
          tableQuyu: '${widget.table['quyu'] ?? ''}',
        );
      }
      // 打印成功后：后端 is_xiachu 置 1（持久化，v3.3.115），
      // 之后再开面板数量归零；打印失败不会置 1，重开面板数量仍在
      try {
        await Api.tableChuanHouchu(wenxunId: Session.wenxunId, kaitaiId: widget.kaitaiId);
      } catch (_) {}
      if (!mounted) return;
      setState(() {});
      _loadBill();
      toast(context, '已传送后厨（${items.length} 项）');
    } catch (_) {
      if (mounted) toast(context, '打印失败，请检查云打印机网络', error: true);
    }
  }

  // ==================== 退菜（v3.3.70） ====================
  Future<void> _retreat(Map b) async {
    final total = int.tryParse('${b['quantity']}') ?? 0;
    final refunded = int.tryParse('${b['refund_num']}') ?? 0;
    final can = total - refunded;
    if (can <= 0) return;
    if ('${b['order_id']}' != '0') {
      toast(context, '已结算菜品不能退菜，请走订单退款', error: true);
      return;
    }
    int num = 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setD) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(width: 380, padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('退菜 · ${b['goods_title']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text('已点 $total 件${refunded > 0 ? ' · 已退 $refunded 件' : ''} · 本次最多可退 $can 件',
              style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
          const SizedBox(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            InkWell(
              onTap: () => setD(() { if (num > 1) num--; }),
              borderRadius: BorderRadius.circular(12),
              child: Container(width: 56, height: 56, alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0xFFF5F6FA), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.remove, size: 26)),
            ),
            Container(width: 110, alignment: Alignment.center,
                child: Text('$num', style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: PosTheme.red))),
            InkWell(
              onTap: () => setD(() { if (num < can) num++; }),
              borderRadius: BorderRadius.circular(12),
              child: Container(width: 56, height: 56, alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0xFFF5F6FA), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.add, size: 26)),
            ),
          ]),
          const SizedBox(height: 8),
          Text('退 ¥${Fmt.money((double.tryParse('${b['unit_price']}') ?? 0) * num)}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.red)),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: BigButton('取消', onTap: () => Navigator.pop(ctx, false), color: const Color(0xFFF5F6FA), textColor: PosTheme.textSub, height: 46)),
            const SizedBox(width: 10),
            Expanded(child: BigButton('确认退菜', onTap: () => Navigator.pop(ctx, true), color: PosTheme.red, height: 46)),
          ]),
        ])),
      )),
    );
    if (ok != true || !mounted) return;
    loadingDialog(context, '退菜中…');
    try {
      // 合并行：按 _items 原始明细依次分摊退件数（v3.3.74）
      int left = num;
      String? err;
      for (final raw in (b['_items'] as List)) {
        if (left <= 0) break;
        final remain = (int.tryParse('${raw['quantity']}') ?? 0) - (int.tryParse('${raw['refund_num']}') ?? 0);
        if (remain <= 0) continue;
        final n = left > remain ? remain : left;
        final r = await Api.tableRetreatDish(
          wenxunId: Session.wenxunId,
          kaitaiId: widget.kaitaiId,
          itemId: int.tryParse('${raw['id']}') ?? 0,
          num: n,
        );
        if ('${r['code']}' != '200') {
          err = '${r['msg'] ?? '退菜失败'}';
          break;
        }
        left -= n;
      }
      if (!mounted) return;
      Navigator.pop(context); // loading
      if (err == null && left == 0) {
        toast(context, '已退：${b['goods_title']} ×$num');
        // 退菜同步打后厨退菜票（不阻塞；米饭只打前台单时退米饭不出后厨票）
        if (await PrintPrefs.on('retreat')) {
          final riceOnly = await PrinterRoute.riceFrontOnly('${Session.wenxunId}');
          if (riceOnly && PrinterRoute.isRiceItem('${b['goods_title']}')) {
            // 米饭类不进后厨，跳过退菜单
          } else {
            // v3.3.127：退菜单也走共享路由（按绑定出票 + 各机字体），失败不阻塞退菜
            diningPrintKitchenRouted(
              items: [{'goods_name': b['goods_title'], 'quantity': num, 'cat_id': _catOf(b['goods_id'])}],
              tableTitle: '${widget.table['title']}',
              tableQuyu: '${widget.table['quyu'] ?? ''}',
              isAdd: false,
              title: '退菜单',
            ).catchError((_) => <String, dynamic>{});
          }
        }
        _loadBill();
      } else {
        toast(context, err ?? '退菜失败', error: true);
        _loadBill(); // 部分成功也刷新
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  /// 重打后厨票：只打「未出品（未划菜）」的菜品（v3.3.93），已出的菜不再重复打印
  /// 按分类路由（v3.3.82）；合并行按 _items 明细逐条判断出品状态
  Future<void> _reprintKitchen() async {
    final items = <Map<String, dynamic>>[];
    for (final b in bill) {
      final remain = (int.tryParse('${b['quantity']}') ?? 0) - (int.tryParse('${b['refund_num']}') ?? 0);
      if (remain <= 0) continue;
      final raw = b['_items'] is List && (b['_items'] as List).isNotEmpty ? (b['_items'] as List) : [b];
      var qty = 0;
      for (final it in raw) {
        if ('${it['is_chu'] ?? 0}' == '1') continue; // 已出品跳过
        final q = (int.tryParse('${it['quantity']}') ?? 0) - (int.tryParse('${it['refund_num']}') ?? 0);
        if (q > 0) qty += q;
      }
      if (qty <= 0) continue;
      items.add({
        'goods_id': b['goods_id'],
        'goods_name': b['goods_title'],
        'goods_image': b['goods_image'] ?? '',
        'unit_price': b['unit_price'],
        'quantity': qty,
        'remark': b['remark'] ?? '',
      });
    }
    if (items.isEmpty) {
      toast(context, '当前菜品都已出品，无需重打后厨单', error: true);
      return;
    }
    if (!await PrintPrefs.on('reprint')) {
      toast(context, '传后厨重打单打印已关闭（设置 → 小票打印设置）');
      return;
    }
    try {
      final routed = items.map((c) => {...c, 'cat_id': _catOf(c['goods_id'])}).toList();
      await _printKitchenRouted(routed, isAdd: false, title: '后厨单重打');
      if (!mounted) return;
      toast(context, '已传后厨打印机（${items.length} 项未出品）');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  /// 预结单（v3.3.82）：预览当前账单 → 确认后发往前台打印机（先出单核对，非正式结算）
  Future<void> _prebill() async {
    if (bill.isEmpty) {
      toast(context, '该桌还没有点菜品', error: true);
      return;
    }
    if (!await PrintPrefs.on('prebill')) {
      toast(context, '预结单打印已关闭（设置 → 小票打印设置）');
      return;
    }
    final items = settleCart;
    if (items.isEmpty) {
      toast(context, '当前没有未退菜品', error: true);
      return;
    }
    // 预结单也按绑定的前台机字体出（v3.3.127）
    final cfgs = await PrinterRoute.printerCfgs('${Session.wenxunId}');
    String frontFont = '';
    for (final e in cfgs.entries) {
      if (e.value.role == 'front') { frontFont = e.value.font; break; }
    }
    final content = CloudPrinter.prebillTicket(
      tableTitle: '${widget.table['title']}',
      peopleNum: int.tryParse('${widget.table['people_num']}') ?? 1,
      goodsTotal: billTotal,
      cart: items,
      extraLines: [if (orderRemark.isNotEmpty) '备注: $orderRemark'],
      font: frontFont,
    );
    final code = await diningFrontMachineCode();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => ReceiptPreviewDialog(title: '预结单', content: content, machineCode: code),
    );
  }

  // ==================== 结账 ====================
  Future<void> _settle() async {
    if (bill.isEmpty) {
      toast(context, '该桌还没有点菜品', error: true);
      return;
    }
    // ===== 快捷通道（v3.3.164）：默认支付方式是微信/支付宝时，点「结账收款」直接弹付款码 =====
    final prefs0 = await PayMethods.load();
    final quickMethod = prefs0.first;
    if (quickMethod == '微信支付' || quickMethod == '支付宝') {
      final quickNo = 'XYFD${DateTime.now().millisecondsSinceEpoch}'
          '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
      final pay = await showXyfScanPayDialog(context,
          amount: billTotal, title: '扫码收款 · $quickMethod', bizType: 'dining',
          orderNo: quickNo, moreLabel: '折扣 / 现金 / 挂账 / 会员 → 完整结账');
      if (!mounted) return;
      if (pay != null && pay['more'] != true) {
        // 扫码成功：按默认方式直接结算（金额=账单合计，无折扣调整），全程零确认
        return _settleExec({
          'final': billTotal,
          'kaitai_fee': 0.0, 'tea_fee': 0.0, 'service_fee': 0.0, 'box_fee': 0.0,
          'discount_rate': 10.0, 'quiling': 0.0,
          'jifen_num': 0, 'jifen_deduct': 0.0,
          'invoice_title': '', 'invoice_no': '',
          'order_remark': orderRemark,
          'method': quickMethod, 'vip': vip,
          'cash_received': 0.0, 'cash_change': 0.0,
          'xyf_order_no': '${pay['orderNo'] ?? quickNo}',
          'xyf_channel': int.tryParse('${pay['order']?['pay_channel'] ?? 0}') ?? 0,
          'scan_paid': true,
        });
      }
      // 取消扫码 或 点「完整结账」→ 继续走下面的完整弹窗
    }

    // 1. 合并弹窗（v3.3.143，v3.3.144 会员选择内置于弹窗右卡）：一次操作完成
    final adj = await showDialog<Map>(
      context: context,
      builder: (_) => _SettlePayDialog(goodsTotal: billTotal, vip: vip, initialRemark: orderRemark),
    );
    if (adj == null || !mounted) return;
    return _settleExec(adj);
  }

  /// 结算执行（v3.3.164 从 _settle 拆出）：adj = 结账弹窗 / 快捷扫码带回的参数
  Future<void> _settleExec(Map adj) async {
    final picked = '${adj['method'] ?? ''}';
    if (picked.isEmpty) return;
    setState(() => vip = adj['vip'] as Map?); // 弹窗内选择的会员回写面板（余额校验/落库用）
    final finalTotal = (adj['final'] as double?) ?? billTotal;
    final kaitaiFee = (adj['kaitai_fee'] as double?) ?? 0;
    final teaFee = (adj['tea_fee'] as double?) ?? 0;
    final serviceFee = (adj['service_fee'] as double?) ?? 0;
    final boxFee = (adj['box_fee'] as double?) ?? 0;
    final discountRate = (adj['discount_rate'] as double?) ?? 10;
    final quiling = (adj['quiling'] as double?) ?? 0;
    final jifenNum = (adj['jifen_num'] as int?) ?? 0;
    final jifenDeduct = (adj['jifen_deduct'] as double?) ?? 0;
    final invoiceTitle = '${adj['invoice_title'] ?? ''}';
    final invoiceNo = '${adj['invoice_no'] ?? ''}';
    final remark = '${adj['order_remark'] ?? ''}';
    final cashRecv = (adj['cash_received'] as double?) ?? 0;   // 现金实收（v3.3.150）
    final cashChange = (adj['cash_change'] as double?) ?? 0;   // 现金找零
    setState(() => orderRemark = remark);

    // 2. 会员余额 / 挂账校验
    if (picked == '会员余额') {
      if (vip == null) {
        toast(context, '请先选择会员', error: true);
        return;
      }
      final bal = _vipBalance();
      if (bal < finalTotal) {
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
    // 扫码收款（v3.3.163）：结账弹窗内点微信/支付宝已直通扫码完成收款，
    // 成功结果带 xyf_order_no/xyf_channel 回传，此处直接使用；
    // 缺失时兜底走原流程（弹窗关闭后再扫码）
    String xyfOrderNo = '${adj['xyf_order_no'] ?? ''}';
    int xyfChannel = (adj['xyf_channel'] as int?) ?? 0;
    if ((picked == '微信支付' || picked == '支付宝') && xyfOrderNo.isEmpty) {
      xyfOrderNo = 'XYFD${DateTime.now().millisecondsSinceEpoch}'
          '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
      final pay = await showXyfScanPayDialog(context,
          amount: finalTotal, title: '扫码收款 · $picked', bizType: 'dining', orderNo: xyfOrderNo);
      if (pay == null || !mounted) return;
      xyfOrderNo = '${pay['orderNo'] ?? xyfOrderNo}';
      xyfChannel = int.tryParse('${pay['order']?['pay_channel'] ?? 0}') ?? 0;
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
        finalTotal: finalTotal,
        pay1Type: picked,
        pay1Money: finalTotal,
        cart: settleCart,
        vipId: picked == '会员余额' ? (int.tryParse('${vip!['id']}') ?? 0) : 0,
        phone: picked == '会员余额' ? '${vip!['phone'] ?? ''}' : '',
        guazhangName: gzName,
        guazhangPhone: gzPhone,
        orderRemark: remark,
        kaitaiFee: kaitaiFee,
        teaFee: teaFee,
        serviceFee: serviceFee,
        boxFee: boxFee,
        discountRate: discountRate,
        quiling: quiling,
        jifenNum: jifenNum,
        jifenDeduct: jifenDeduct,
        invoiceTitle: invoiceTitle,
        invoiceNo: invoiceNo,
        payOrderNo: xyfOrderNo,
        payChannel: xyfChannel,
      );
      if (!mounted) return;
      // 先捕获 Navigator 和要用的数据：后面 pop 掉本弹窗后 State 会被销毁，
      // 不能再使用 State.context / widget / getter（否则点击"完成"时报 unmounted）
      final navigator = Navigator.of(context);
      final tableTitle = '${widget.table['title']}';
      final peopleNum = int.tryParse('${widget.table['people_num']}') ?? 1;
      final total = finalTotal;
      final goodsTotal = billTotal;
      final cart = settleCart;
      Navigator.pop(context); // loading
      if ('${r['code']}' == '200') {
        final orderSn = '${r['data']?['order_sn'] ?? ''}';
        navigator.pop(); // bill dialog
        // 云打印结账单（含费用/优惠/发票明细行）
        final extra = <String>[];
        if (kaitaiFee > 0) extra.add('开台费: ¥${Fmt.money(kaitaiFee)}');
        if (teaFee > 0) extra.add('茶位费: ¥${Fmt.money(teaFee)}');
        if (serviceFee > 0) extra.add('服务费: ¥${Fmt.money(serviceFee)}');
        if (boxFee > 0) extra.add('餐盒费: ¥${Fmt.money(boxFee)}');
        if (discountRate != 10) extra.add('整单折扣: $discountRate 折');
        if (quiling > 0) extra.add('抹零: -¥${Fmt.money(quiling)}');
        if (jifenNum > 0) extra.add('积分抵扣: $jifenNum 分 (-¥${Fmt.money(jifenDeduct)})');
        if (picked == '现金' && cashRecv > 0) extra.add('实收现金: ¥${Fmt.money(cashRecv)}　找零: ¥${Fmt.money(cashChange)}');
        // 挂账订单打印挂账人姓名/电话（v3.3.156）
        if (picked == '挂账' && gzName.isNotEmpty) {
          extra.add('挂账人: $gzName${gzPhone.isNotEmpty ? '　电话: $gzPhone' : ''}');
        }
        if (remark.isNotEmpty) extra.add('整单备注: $remark');
        if (invoiceTitle.isNotEmpty) extra.add('发票: $invoiceTitle${invoiceNo.isNotEmpty ? '（税号 $invoiceNo）' : ''}');
        if (await PrintPrefs.on('dining')) {
          CloudPrinter.print(CloudPrinter.diningReceipt(
            orderSn: orderSn,
            tableTitle: tableTitle,
            peopleNum: peopleNum,
            payMethod: picked,
            goodsTotal: goodsTotal,
            finalTotal: total,
            cart: cart,
            extraLines: extra,
          )).catchError((_) => <String, dynamic>{});
        }
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
              if (picked == '现金' && cashRecv > 0)
                Text('实收 ¥${Fmt.money(cashRecv)} · 找零 ¥${Fmt.money(cashChange)}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF22B573))),
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
    // 四周各留 10% 屏幕边距，适配大屏（v3.3.70）
    final size = MediaQuery.of(context).size;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(horizontal: size.width * 0.1, vertical: size.height * 0.1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: size.width * 0.8, height: size.height * 0.8,
          child: Column(children: [
            _header(),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // 左：账单（含退菜）
                Expanded(
                  flex: 4,
                  child: loading
                      ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                      : bill.isEmpty
                          ? const EmptyView('还没有点菜品，从右侧点菜')
                          : ListView.separated(
                              padding: const EdgeInsets.all(14),
                              itemCount: bill.length,
                              separatorBuilder: (_, __) => const Divider(height: 1, color: PosTheme.line),
                              itemBuilder: (_, i) => _billRow(bill[i]),
                            ),
                ),
                VerticalDivider(width: 1, color: PosTheme.line),
                // 右：点菜区（分类左栏 + 商品网格，v3.3.70）
                Expanded(
                  flex: 7,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _catRail(),
                    Expanded(child: _dishGrid()),
                  ]),
                ),
              ]),
            ),
            _footer(),
          ]),
        ),
      ),
    );
  }

  // ==================== 头部 ====================
  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 16, 14, 14),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: PosTheme.line))),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(color: PosTheme.accent, borderRadius: BorderRadius.circular(10)),
          child: Text('${widget.table['title']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
        ),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('已点账单', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          // 用餐人数（点击可修改，v3.3.76）
          InkWell(
            onTap: _editPeople,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('人数 $_peopleNow', style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
                const SizedBox(width: 3),
                const Icon(Icons.edit, size: 12, color: PosTheme.textHint),
              ]),
            ),
          ),
        ]),
        // 并台来源桌台名（v3.3.93）
        if ('${widget.table['merge_titles'] ?? ''}'.trim().isNotEmpty) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: const Color(0xFFF0F6FF), borderRadius: BorderRadius.circular(7), border: Border.all(color: PosTheme.blue.withOpacity(0.3))),
            child: Text(
              '并入 ${'${widget.table['merge_titles']}'.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).join('、')}',
              style: const TextStyle(fontSize: 11.5, color: PosTheme.blue, fontWeight: FontWeight.w600),
            ),
          ),
        ],
        const Spacer(),
        // 商品搜索（名称/简拼，v3.3.75；合计只在底部显示）
        SizedBox(
          width: 260,
          height: 40,
          child: TextField(
            controller: searchCtrl,
            onChanged: _onSearch,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              hintText: '搜索商品名称 / 简拼',
              hintStyle: const TextStyle(fontSize: 13, color: PosTheme.textHint),
              prefixIcon: const Icon(Icons.search, size: 19, color: PosTheme.textHint),
              // 清除搜索（v3.3.76）
              suffixIcon: keyword.trim().isEmpty ? null : InkWell(
                onTap: () { searchCtrl.clear(); setState(() => keyword = ''); },
                borderRadius: BorderRadius.circular(20),
                child: const Icon(Icons.close, size: 16, color: PosTheme.textHint),
              ),
              suffixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 30),
              isDense: true,
              filled: true,
              fillColor: const Color(0xFFF7F8FA),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 右上角关闭按钮已移除（v3.3.76），点击弹窗外空白即关闭
      ]),
    );
  }

  /// 当前显示的用餐人数（开台记录 kaitai_people 优先，历史数据回落 people_num/1）
  int get _peopleNow => int.tryParse('${widget.table['kaitai_people'] ?? widget.table['people_num'] ?? 1}') ?? 1;

  /// 修改用餐人数（v3.3.76）：+/- 步进 → 保存到桌台开台记录
  Future<void> _editPeople() async {
    int people = _peopleNow;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setD) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(width: 360, padding: const EdgeInsets.all(26), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('修改用餐人数', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('${widget.table['title']}', style: const TextStyle(fontSize: 13, color: PosTheme.textHint)),
          const SizedBox(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            InkWell(
              onTap: () => setD(() { if (people > 1) people--; }),
              borderRadius: BorderRadius.circular(12),
              child: Container(width: 60, height: 60, alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0xFFF5F6FA), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.remove, size: 28)),
            ),
            Container(width: 110, alignment: Alignment.center,
                child: Text('$people', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: PosTheme.accent))),
            InkWell(
              onTap: () => setD(() { if (people < 99) people++; }),
              borderRadius: BorderRadius.circular(12),
              child: Container(width: 60, height: 60, alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0xFFF5F6FA), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.add, size: 28)),
            ),
          ]),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: BigButton('取消', onTap: () => Navigator.pop(ctx, false), color: const Color(0xFFF5F6FA), textColor: PosTheme.textSub, height: 46)),
            const SizedBox(width: 10),
            Expanded(child: BigButton('确认修改', onTap: () => Navigator.pop(ctx, true), height: 46)),
          ]),
        ])),
      )),
    );
    if (ok != true || !mounted) return;
    loadingDialog(context, '保存中…');
    try {
      final r = await Api.tablePeople(
        wenxunId: Session.wenxunId,
        tableId: int.tryParse('${widget.table['id']}') ?? 0,
        peopleNum: people,
      );
      if (!mounted) return;
      Navigator.pop(context); // loading
      if ('${r['code']}' == '200') {
        widget.table['kaitai_people'] = people; // 同步本地（父级 tables 持有同一 map 引用）
        widget.table['people_num'] = people;
        if (mounted) setState(() {});
        toast(context, '用餐人数已改为 $people');
      } else {
        toast(context, '${r['msg'] ?? '修改失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 账单行（做法备注 + 催菜/划菜/退菜，v3.3.71） ====================
  Widget _billRow(Map b) {
    final total = int.tryParse('${b['quantity']}') ?? 0;
    final refunded = int.tryParse('${b['refund_num']}') ?? 0;
    final allBack = refunded >= total; // 整行退完
    final isChu = '${b['is_chu'] ?? 0}' == '1';
    final note = '${b['remark'] ?? ''}'.trim();
    final unsettled = '${b['order_id']}' == '0';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text('${b['goods_title']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w500,
                      color: allBack ? PosTheme.textHint : PosTheme.textMain,
                      decoration: allBack ? TextDecoration.lineThrough : TextDecoration.none,
                    )),
              ),
              if ('${b['is_add']}' == 'true' || b['is_add'] == true) ...[
                const SizedBox(width: 6),
                _miniTag('加菜', const Color(0xFFFFF8EC), PosTheme.amber),
              ],
              if (refunded > 0) ...[
                const SizedBox(width: 6),
                _miniTag(allBack ? '已退' : '已退$refunded', const Color(0xFFFFF1F0), PosTheme.red),
              ],
              if (isChu) ...[
                const SizedBox(width: 6),
                _miniTag('已出', const Color(0xFFEDFFF5), PosTheme.green),
              ],
            ]),
            const SizedBox(height: 2),
            Text('¥${Fmt.money(b['unit_price'])} ×${total - refunded}${total > 1 ? '/$total' : ''}${note.isNotEmpty ? ' · 做法:$note' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
          ]),
        ),
        Text('¥${Fmt.money(b['sub_total'])}', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700,
            color: allBack ? PosTheme.textHint : PosTheme.textMain)),
        const SizedBox(width: 10),
        // 操作列：做（未传后厨可改做法）/ 催菜 / 划菜 / 退菜（仅未结算且有剩余件数）
        if (!allBack && unsettled)
          Row(mainAxisSize: MainAxisSize.min, children: [
            if ('${b['is_xiachu'] ?? 1}' != '1') ...[
              _rowBtn('做', const Color(0xFFFFF8EC), PosTheme.amber, onTap: () => _editZuofa(b)),
              const SizedBox(width: 5),
            ],
            _rowBtn('催', const Color(0xFFF0F6FF), PosTheme.blue, onTap: () => _urge(b)),
            const SizedBox(width: 5),
            _rowBtn(isChu ? '取消' : '划', isChu ? const Color(0xFFF2F3F7) : const Color(0xFFEDFFF5), isChu ? PosTheme.textSub : PosTheme.green, onTap: () => _chuhua(b)),
            const SizedBox(width: 5),
            _rowBtn('退', const Color(0xFFFFF1F0), PosTheme.red, onTap: () => _retreat(b)),
          ])
        else
          const SizedBox(width: 143),
      ]),
    );
  }

  Widget _miniTag(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5)),
      child: Text(text, style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w600)),
    );
  }

  Widget _rowBtn(String text, Color bg, Color fg, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 32, height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: fg)),
      ),
    );
  }

  // ==================== 分类左栏 ====================
  Widget _catRail() {
    return Container(
      width: 118,
      color: const Color(0xFFF7F8FA),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 10),
        itemCount: cats.length + 1, // 第 0 位固定「无码菜品」（v3.3.147 从底部移入）
        itemBuilder: (_, i) {
          if (i == 0) {
            // 无码菜品（临时菜/时价菜手动录入）：固定在分类第一位，功能不变
            return Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: _noCodeDish,
                child: Container(
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFFFF7A45), PosTheme.accent]),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.keyboard_outlined, size: 17, color: Colors.white),
                    SizedBox(width: 5),
                    Text('无码菜品', maxLines: 1,
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white)),
                  ]),
                ),
              ),
            );
          }
          final c = cats[i - 1];
          final on = catId == c['id'];
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                setState(() {
                  catId = c['id'];
                  if (keyword.isNotEmpty) { keyword = ''; searchCtrl.clear(); } // 选分类即退出搜索
                });
                _loadDishes();
              },
              child: Container(
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? PosTheme.accent : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
                ),
                child: Text('${c['title']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? Colors.white : PosTheme.textSub)),
              ),
            ),
          );
        },
      ),
    );
  }

  // ==================== 商品网格 ====================
  Widget _dishGrid() {
    final list = _gridGoods;
    final searching = keyword.trim().isNotEmpty;
    return list.isEmpty
        ? EmptyView(searching ? '未找到匹配「${keyword.trim()}」的商品' : '该分类暂无菜品')
        : GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 140, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.92),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final g = list[i];
              return Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _addDish(g),
                  onLongPress: () => _addDishWithNote(g), // 长按=带做法备注点菜
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: PosTheme.line)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: RetailGoodsImage(urls: _dishImgUrls(g)),
                      )),
                      const SizedBox(height: 5),
                      Text('${g['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('¥${Fmt.money(g['amount'] ?? g['price'])}', style: const TextStyle(fontSize: 13.5, color: PosTheme.accent, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              );
            },
          );
  }

  /// 商品图片候选地址（与收银页同规则：接口地址 → /goods/ 前缀 → 根路径，v3.3.73）
  List<String> _dishImgUrls(Map g) {
    final raw = '${g['goods_image'] ?? ''}'.trim();
    final out = <String>[];
    void add(String? u) {
      final s = (u ?? '').trim();
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    add('${g['goods_image_url']}');
    add('${g['goods_image_url_alt']}');
    if (raw.isNotEmpty && !raw.startsWith('http')) {
      final p = raw.startsWith('/') ? raw : '/$raw';
      add('${Api.base}/goods$p');
      add('${Api.base}$p');
    } else if (raw.startsWith('http')) {
      add(raw);
    }
    return out;
  }

  // ==================== 底部操作 ====================
  Widget _footer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: PosTheme.line))),
      child: Row(children: [
        // 左侧可横向滚动按钮区（Spacer 与横向滚动互斥，所以右侧固定按钮放外层）
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              Text('共 ${bill.length} 项 · 合计 ¥${Fmt.money(billTotal)}',
                  style: const TextStyle(fontSize: 14.5, color: PosTheme.textSub)),
              const SizedBox(width: 14),
              // 整单备注（v3.3.71）
              InkWell(
                onTap: _editOrderRemark,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: orderRemark.isNotEmpty ? const Color(0xFFFFF8EC) : const Color(0xFFF7F8FA),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: orderRemark.isNotEmpty ? PosTheme.amber.withOpacity(0.5) : PosTheme.line),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.edit_note, size: 19, color: orderRemark.isNotEmpty ? PosTheme.amber : PosTheme.textSub),
                    const SizedBox(width: 7),
                    Text(orderRemark.isEmpty ? '整单备注' : '备注:${orderRemark.length > 6 ? '${orderRemark.substring(0, 6)}…' : orderRemark}',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: orderRemark.isNotEmpty ? PosTheme.amber : PosTheme.textSub)),
                  ]),
                ),
              ),
              const SizedBox(width: 12),
              // 全部划菜（v3.3.71）
              InkWell(
                onTap: bill.isEmpty ? null : _chuhuaAll,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEDFFF5),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: PosTheme.green.withOpacity(0.4)),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.done_all, size: 19, color: PosTheme.green),
                    SizedBox(width: 7),
                    Text('全部划菜', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: PosTheme.green)),
                  ]),
                ),
              ),
              const SizedBox(width: 12),
              // 预结单（v3.3.82）：预览并打印当前账单（先出单核对，非正式结算）
              InkWell(
                onTap: bill.isEmpty ? null : _prebill,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF6F0FF),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF8B5CF6).withOpacity(0.4)),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.receipt, size: 19, color: Color(0xFF8B5CF6)),
                    SizedBox(width: 7),
                    Text('预结单', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF8B5CF6))),
                  ]),
                ),
              ),
              const SizedBox(width: 12),
              // 传后厨（v3.3.99）：点菜不再即时出票，点此统一传送
              // 未传 >0 时打未传菜品（后厨按分类路由 + 前台整单一张）；无未传时补打未出品
              // v3.3.115：数量来自后端 is_xiachu，面板关闭重开不丢
              InkWell(
                onTap: bill.isEmpty && _pendingCount == 0 ? null : _sendKitchen,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: _pendingCount > 0 ? const Color(0xFFFFF7E8) : const Color(0xFFF0F6FF),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _pendingCount > 0
                          ? const Color(0xFFF59E0B).withOpacity(0.5)
                          : PosTheme.blue.withOpacity(0.4),
                    ),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.send_outlined, size: 18, // 发送图标（v3.3.149，餐具也不贴切）
                        color: _pendingCount > 0 ? const Color(0xFFD97706) : PosTheme.blue),
                    const SizedBox(width: 7),
                    Text(
                      _pendingCount > 0 ? '传后厨($_pendingCount)' : '传后厨',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _pendingCount > 0 ? const Color(0xFFD97706) : PosTheme.blue,
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(width: 12),
            ]),
          ),
        ),
        const SizedBox(width: 12),
        // 右侧固定：结账收款
        BigButton('结账收款', onTap: bill.isEmpty ? null : _settle, width: 180, height: 50),
      ]),
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
    // 排版与开台点餐账单面板一致（v3.3.90）：左账单 / 右分类栏+商品图片网格 / 底部操作
    final size = MediaQuery.of(context).size;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(horizontal: size.width * 0.1, vertical: size.height * 0.1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: size.width * 0.8, height: size.height * 0.8,
          child: Column(children: [
            _header(),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // 左：已选菜品（数量步进）
                Expanded(
                  flex: 4,
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
                                  padding: const EdgeInsets.symmetric(vertical: 7),
                                  child: Row(children: [
                                    Expanded(
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text('${b['goods_title']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
                                        const SizedBox(height: 2),
                                        Text('¥${Fmt.money(b['unit_price'])}', style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                                      ]),
                                    ),
                                    _qtyBtn(Icons.remove, () => _changeQty(i, -1)),
                                    Container(width: 34, alignment: Alignment.center,
                                        child: Text('${b['quantity']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
                                    _qtyBtn(Icons.add, () => _changeQty(i, 1)),
                                    const SizedBox(width: 10),
                                    SizedBox(width: 72,
                                        child: Text('¥${Fmt.money((double.tryParse('${b['unit_price']}') ?? 0) * (int.tryParse('${b['quantity']}') ?? 0))}',
                                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700), textAlign: TextAlign.right)),
                                  ]),
                                );
                              },
                            ),
                ),
                VerticalDivider(width: 1, color: PosTheme.line),
                // 右：分类栏 + 商品图片网格（与开台点餐一致）
                Expanded(
                  flex: 7,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _catRail(),
                    Expanded(child: _dishGrid()),
                  ]),
                ),
              ]),
            ),
            _footer(),
          ]),
        ),
      ),
    );
  }

  // ==================== 头部（桌名徽章 + 合计） ====================
  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 14),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: PosTheme.line))),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(color: PosTheme.amber, borderRadius: BorderRadius.circular(10)),
          child: Text('${widget.table['title']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
        ),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('预点餐', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text('保存后桌台自动预约，顾客到店一键开台出后厨票', style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
        ]),
        const Spacer(),
        Text('合计 ¥${Fmt.money(total)}', style: const TextStyle(fontSize: 20, color: PosTheme.accent, fontWeight: FontWeight.w800)),
      ]),
    );
  }

  // ==================== 分类左栏（样式同开台点餐） ====================
  Widget _catRail() {
    return Container(
      width: 118,
      color: const Color(0xFFF7F8FA),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 10),
        itemCount: cats.length,
        itemBuilder: (_, i) {
          final c = cats[i];
          final on = catId == int.tryParse('${c['id']}');
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () { setState(() => catId = int.tryParse('${c['id']}') ?? -1); _loadDishes(); },
              child: Container(
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? PosTheme.accent : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
                ),
                child: Text('${c['title']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? Colors.white : PosTheme.textSub)),
              ),
            ),
          );
        },
      ),
    );
  }

  // ==================== 商品图片网格（样式同开台点餐） ====================
  Widget _dishGrid() {
    return dishes.isEmpty
        ? const EmptyView('该分类暂无菜品')
        : GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 140, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.92),
            itemCount: dishes.length,
            itemBuilder: (_, i) {
              final g = dishes[i];
              return Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _pick(g),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: PosTheme.line)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: RetailGoodsImage(urls: _dishImgUrls(g)),
                      )),
                      const SizedBox(height: 5),
                      Text('${g['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('¥${Fmt.money(g['amount'] ?? g['price'])}', style: const TextStyle(fontSize: 13.5, color: PosTheme.accent, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              );
            },
          );
  }

  /// 商品图片候选地址（与开台点餐同规则）
  List<String> _dishImgUrls(Map g) {
    final raw = '${g['goods_image'] ?? ''}'.trim();
    final out = <String>[];
    void add(String? u) {
      final s = (u ?? '').trim();
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    add('${g['goods_image_url']}');
    add('${g['goods_image_url_alt']}');
    if (raw.isNotEmpty && !raw.startsWith('http')) {
      final p = raw.startsWith('/') ? raw : '/$raw';
      add('${Api.base}/goods$p');
      add('${Api.base}$p');
    } else if (raw.startsWith('http')) {
      add(raw);
    }
    return out;
  }

  // ==================== 底部操作（清空 / 保存预点单） ====================
  Widget _footer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: PosTheme.line))),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: TextEditingController(text: remark),
            onChanged: (v) => remark = v,
            style: const TextStyle(fontSize: 13.5),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '到店备注（如：预计12:00到店 · 张先生）',
              prefixIcon: Icon(Icons.schedule, size: 19),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Text('共 ${bill.length} 项', style: const TextStyle(fontSize: 14, color: PosTheme.textSub)),
        const SizedBox(width: 14),
        InkWell(
          onTap: bill.isEmpty ? null : () => setState(() => bill.clear()),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: bill.isEmpty ? const Color(0xFFF7F8FA) : const Color(0xFFFFF1F0),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: bill.isEmpty ? PosTheme.line : PosTheme.red.withOpacity(0.4)),
            ),
            child: Text('清空', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                color: bill.isEmpty ? PosTheme.textHint : PosTheme.red)),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 180, height: 50,
          child: BigButton('保存预点单', onTap: _save, height: 50),
        ),
      ]),
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

// ==================== 做法备注弹窗（v3.3.71 长按点菜；v3.3.141 候选项=商户自定义「常用做法」；
// v3.3.142 收银员只勾选不输入，做法由商户在「设置 → 常用做法」维护，保证点餐速度） ====================
class _DishNoteDialog extends StatefulWidget {
  final String title;
  final String initial; // 编辑已有做法时回填（账单行「做」按钮用）
  final String confirmText;
  const _DishNoteDialog({required this.title, this.initial = '', this.confirmText = '加菜'});
  @override
  State<_DishNoteDialog> createState() => _DishNoteDialogState();
}

class _DishNoteDialogState extends State<_DishNoteDialog> {
  List<String> common = List<String>.from(PrinterRoute.defaultZuofa); // 先给默认，异步换商户自定义
  final Set<String> picked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await PrinterRoute.zuofaList('${Session.wenxunId}');
    if (!mounted) return;
    setState(() {
      common = l;
      // 回填：已有做法中命中候选项的勾选（不在候选里的旧自定义做法保存后会被丢弃）
      if (widget.initial.trim().isNotEmpty) {
        final tokens = widget.initial.split('，').map((e) => e.trim()).where((e) => e.isNotEmpty);
        picked..clear()..addAll(tokens.where(l.contains));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('做法备注 · ${widget.title}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
          spacing: 8, runSpacing: 8,
          children: common.map((s) {
            final on = picked.contains(s);
            return InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: () => setState(() { on ? picked.remove(s) : picked.add(s); }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: on ? PosTheme.accent : const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
                ),
                child: Text(s, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 10),
        Text('做法候选项由商户在「设置 → 常用做法」自定义', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(context, picked.join('，')),
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
}

// ==================== 整单备注（v3.3.71） ====================
class _OrderRemarkDialog extends StatefulWidget {
  final String initial;
  const _OrderRemarkDialog({required this.initial});
  @override
  State<_OrderRemarkDialog> createState() => _OrderRemarkDialogState();
}

class _OrderRemarkDialogState extends State<_OrderRemarkDialog> {
  final ctrl = TextEditingController();
  @override
  void initState() {
    super.initState();
    ctrl.text = widget.initial;
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('整单备注', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      content: SizedBox(width: 420, child: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: 3,
        decoration: const InputDecoration(hintText: '如：先上凉菜、12:30 前出餐、打包一半'),
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(context, ctrl.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

// ==================== 结算优惠弹窗（v3.3.71）：费用/折扣/抹零/积分/发票/整单备注 ====================
// ==================== 结账收款弹窗（v3.3.143 合并版；v3.3.144 全屏95%+内置会员选择） ====================
/// 左卡：费用/折扣/抹零/积分/整单备注/发票（选填项收银员可全部跳过，备注默认折叠）
/// 右卡：会员选择（余额支付/积分抵扣入口）+ 应收金额 + 支付方式——少一步操作
class _SettlePayDialog extends StatefulWidget {
  final double goodsTotal;
  final Map? vip; // 面板已选会员则带入
  final String initialRemark;
  const _SettlePayDialog({required this.goodsTotal, this.vip, required this.initialRemark});
  @override
  State<_SettlePayDialog> createState() => _SettlePayDialogState();
}

class _SettlePayDialogState extends State<_SettlePayDialog> {
  final kaitaiCtrl = TextEditingController();
  final teaCtrl = TextEditingController();
  final serviceCtrl = TextEditingController();
  final boxCtrl = TextEditingController();
  final remarkCtrl = TextEditingController();
  final invoiceCtrl = TextEditingController();
  final invoiceNoCtrl = TextEditingController();
  final cashCtrl = TextEditingController(); // 现金实收（v3.3.150 找零）
  double rate = 10; // 10 = 不打折
  int moling = 0;   // 0 不抹零 1 抹角 2 抹元
  bool useJifen = false;
  bool remarkOpen = false; // 整单备注默认折叠（v3.3.144）
  String? method;
  Map? vip; // 弹窗内选择的会员（选择后解锁「会员余额」支付与积分抵扣）
  List<String> methodOrder = PayMethods.defaultOrder; // 商户自定义排序（v3.3.163）

  double get _cash => double.tryParse(cashCtrl.text.trim()) ?? 0;

  static const payIcons = {
    '现金': Icons.payments_outlined, '微信支付': Icons.chat,
    '支付宝': Icons.account_balance_wallet_outlined, '会员余额': Icons.badge_outlined,
    '挂账': Icons.receipt_long_outlined,
  };
  // 每种支付方式一个品牌色（v3.3.146 彩色大卡片）
  static const payColors = {
    '现金': Color(0xFF22B573),      // 现金绿
    '微信支付': Color(0xFF07C160),  // 微信支付官方绿
    '支付宝': Color(0xFF1677FF),    // 支付宝官方蓝
    '会员余额': PosTheme.accent,    // 会员橙
    '挂账': Color(0xFFE4573D),      // 挂账红
  };
  static const payDarks = {
    '现金': Color(0xFF189B5B), '微信支付': Color(0xFF06AD56), '支付宝': Color(0xFF0F5FD6),
    '会员余额': PosTheme.accentDeep, '挂账': Color(0xFFC23A22),
  };
  static const paySubs = {
    '现金': '即时到账 · 支持找零', '微信支付': '扫码枪 · 付款码收款', '支付宝': '扫码枪 · 付款码收款',
    '会员余额': '余额扣款 · 积分抵扣', '挂账': '记账后补款',
  };

  List<String> get _methods {
    // 商户自定义排序（设置 → 支付方式排序，v3.3.176 与零售/生鲜复用同一排序）；
    // 餐饮只显示餐饮有的方式（扫码收款/会员支付是零售专属），会员余额需先选会员
    const diningSet = ['微信支付', '支付宝', '现金', '挂账', '会员余额'];
    final list = methodOrder
        .where(diningSet.contains)
        .where((m) => m != '会员余额' || vip != null)
        .toList();
    return list;
  }

  /// 点击支付方式：微信/支付宝免确认直通扫码（v3.3.163）——
  /// 立即弹出扫码枪收款，付款成功自动带结果关单；取消则回到结账页
  Future<void> _tapMethod(String m) async {
    if (m != '微信支付' && m != '支付宝') {
      setState(() {
        method = m;
        // 现金支付：默认按应收金额预填实收（可改大收整钱，自动算找零）
        if (m == '现金' && cashCtrl.text.trim().isEmpty) {
          cashCtrl.text = finalTotal.toStringAsFixed(2);
        }
      });
      return;
    }
    setState(() => method = m);
    final orderNo = 'XYFD${DateTime.now().millisecondsSinceEpoch}'
        '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
    final pay = await showXyfScanPayDialog(context,
        amount: finalTotal, title: '扫码收款 · $m', bizType: 'dining', orderNo: orderNo);
    if (!mounted) return;
    if (pay == null) {
      // 扫码取消：不记账，收回选中状态，防止误点「确认收款」造成记账式收款
      setState(() => method = null);
      return;
    }
    // 付款成功：直接带完整结算参数关单（跳过「确认收款」按钮）
    Navigator.pop(context, {
      'final': finalTotal,
      'kaitai_fee': _num(kaitaiCtrl),
      'tea_fee': _num(teaCtrl),
      'service_fee': _num(serviceCtrl),
      'box_fee': _num(boxCtrl),
      'discount_rate': rate,
      'quiling': quiling,
      'jifen_num': (jifenMax * 100).round(),
      'jifen_deduct': jifenMax,
      'invoice_title': invoiceCtrl.text.trim(),
      'invoice_no': invoiceNoCtrl.text.trim(),
      'order_remark': remarkCtrl.text.trim(),
      'method': m,
      'vip': vip,
      'cash_received': 0.0,
      'cash_change': 0.0,
      'xyf_order_no': '${pay['orderNo'] ?? orderNo}',
      'xyf_channel': int.tryParse('${pay['order']?['pay_channel'] ?? 0}') ?? 0,
      'scan_paid': true,
    });
  }

  /// 选择会员（复用餐饮会员选择弹窗）
  Future<void> _pickVip() async {
    final p = await showDialog<Map>(context: context, builder: (_) => const _DiningVipPicker());
    if (p == null || !mounted) return;
    setState(() => vip = p);
  }

  /// 会员充值（v3.3.164）：结账弹窗内直接充值，成功后【不关闭结账界面】，
  /// 余额即时累加（本金+赠送），可继续用会员余额支付本单
  Future<void> _rechargeVip() async {
    if (vip == null) return;
    final r = await showVipRechargeDialog(context, vip: vip!);
    if (r == null || !mounted) return;
    final amt = double.tryParse('${r['amount'] ?? 0}') ?? 0;
    final gift = double.tryParse('${r['gift'] ?? 0}') ?? 0;
    setState(() {
      vip = {
        ...vip!,
        'amount': (double.tryParse('${vip!['amount'] ?? 0}') ?? 0) + amt,
        'gift_balance': (double.tryParse('${vip!['gift_balance'] ?? 0}') ?? 0) + gift,
      };
    });
    VoiceService.instance.pay('充值', amt);
    toast(context, '充值成功（¥${Fmt.money(amt)}${gift > 0 ? ' + 赠送 ¥${Fmt.money(gift)}' : ''}），余额 ¥${Fmt.money(_balance)}');
  }

  void _clearVip() => setState(() {
        vip = null;
        if (method == '会员余额') method = null; // 会员被清除时收回该支付方式
      });

  double _num(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;
  int get _points => int.tryParse('${vip?['jifen'] ?? 0}') ?? 0; // 100积分=1元

  double get fees => _num(kaitaiCtrl) + _num(teaCtrl) + _num(serviceCtrl) + _num(boxCtrl);
  double get rawTotal => (widget.goodsTotal + fees) * rate / 10;

  double get quiling {
    if (moling == 1) return rawTotal - ((rawTotal * 10).floorToDouble()) / 10;
    if (moling == 2) return rawTotal - rawTotal.floorToDouble();
    return 0;
  }

  double get afterMoling => rawTotal - quiling;
  double get jifenMax => useJifen && _points > 0 ? (_points / 100).floorToDouble().clamp(0, afterMoling).toDouble() : 0;
  double get finalTotal => (afterMoling - jifenMax).clamp(0.01, double.infinity).toDouble();

  double get _balance {
    final a = double.tryParse('${vip?['amount'] ?? 0}') ?? 0;
    final g = double.tryParse('${vip?['gift_balance'] ?? 0}') ?? 0;
    return a + g;
  }

  @override
  void initState() {
    super.initState();
    remarkCtrl.text = widget.initialRemark;
    vip = widget.vip;
    remarkOpen = widget.initialRemark.trim().isNotEmpty; // 已有备注自动展开显示
    PayMethods.load().then((o) {
      if (mounted) setState(() => methodOrder = o);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias, // 内容（头部/底部渐变）按圆角裁剪
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SizedBox(
        width: size.width * 0.95,
        height: size.height * 0.95,
        child: Column(children: [
          // ===== 头部（渐变） =====
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 14),
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFFFFF3ED), Colors.white], begin: Alignment.centerLeft, end: Alignment.centerRight),
              border: Border(bottom: BorderSide(color: PosTheme.line)),
            ),
            child: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [PosTheme.accent, PosTheme.accentDeep]),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.payments_outlined, size: 20, color: Colors.white),
              ),
              const SizedBox(width: 10),
              const Text('结账收款', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: const Color(0xFFFFF3ED), borderRadius: BorderRadius.circular(8)),
                child: Text('菜品合计 ¥${Fmt.money(widget.goodsTotal)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: PosTheme.accent)),
              ),
              const Spacer(),
              // 关闭按钮（v3.3.151 由底部「取消」移入右上角）
              InkWell(
                onTap: () => Navigator.pop(context),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.close, size: 20, color: PosTheme.textSub),
                ),
              ),
            ]),
          ),
          // ===== 左右卡片 =====
          Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // ---------- 左卡：优惠与费用（左右各约45%） ----------
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(26, 16, 22, 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _section('附加费用（选填）', Row(children: [
                    _feeField('开台费 ¥', kaitaiCtrl),
                    const SizedBox(width: 8),
                    _feeField('茶位费 ¥', teaCtrl),
                    const SizedBox(width: 8),
                    _feeField('服务费 ¥', serviceCtrl),
                    const SizedBox(width: 8),
                    _feeField('餐盒费 ¥', boxCtrl),
                  ])),
                  _section('整单折扣', Wrap(spacing: 8, runSpacing: 8, children: [10, 9.8, 9.5, 9, 8.8, 8].map((r) => _chip('$r 折', rate == r, () => setState(() => rate = r.toDouble()))).toList())),
                  _section('抹零', Wrap(spacing: 8, children: [
                    _chip('不抹零', moling == 0, () => setState(() => moling = 0)),
                    _chip('抹角', moling == 1, () => setState(() => moling = 1)),
                    _chip('抹元', moling == 2, () => setState(() => moling = 2)),
                  ])),
                  if (vip != null)
                    _section('积分抵扣（100 积分 = 1 元）', Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
                      child: Row(children: [
                        Text('会员「${vip!['name'] ?? vip!['phone'] ?? ''}」可用 ${_points} 分 · 可抵 ¥${Fmt.money(_points / 100)}',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _points > 0 ? PosTheme.accent : PosTheme.textHint)),
                        const Spacer(),
                        Switch(value: useJifen, activeColor: PosTheme.accent, onChanged: _points > 0 ? (v) => setState(() => useJifen = v) : null),
                      ]),
                    )),
                  // 整单备注（默认折叠，v3.3.144）
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      InkWell(
                        onTap: () => setState(() => remarkOpen = !remarkOpen),
                        borderRadius: BorderRadius.circular(8),
                        child: Row(children: [
                          const Text('整单备注（选填）', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                          const Spacer(),
                          if (remarkCtrl.text.trim().isNotEmpty)
                            Flexible(child: Text(remarkCtrl.text, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11.5, color: PosTheme.amber))),
                          Icon(remarkOpen ? Icons.expand_less : Icons.expand_more, size: 18, color: PosTheme.textHint),
                        ]),
                      ),
                      if (remarkOpen) ...[
                        const SizedBox(height: 6),
                        TextField(controller: remarkCtrl, maxLines: 2, onChanged: (_) => setState(() {})),
                      ],
                    ]),
                  ),
                  _section('发票（选填）', Column(children: [
                    TextField(controller: invoiceCtrl, decoration: const InputDecoration(hintText: '发票抬头', isDense: true)),
                    const SizedBox(height: 8),
                    TextField(controller: invoiceNoCtrl, decoration: const InputDecoration(hintText: '税号', isDense: true)),
                  ])),
                  const SizedBox(height: 4),
                ]),
              ),
            ),
            // 分隔线
            Container(width: 1, color: PosTheme.line),
            // ---------- 右卡：会员 + 应收 + 支付方式（左右各约45%） ----------
            Expanded(
              child: Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 26, 10),
              child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // 应收金额（渐变面板）
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFFFFF8F4), Color(0xFFFFF0E8)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFFE1D4)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Row(children: [
                      Icon(Icons.account_balance_wallet_outlined, size: 15, color: PosTheme.accent),
                      SizedBox(width: 5),
                      Text('应收金额', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: PosTheme.textSub)),
                    ]),
                    const SizedBox(height: 2),
                    Text('¥${Fmt.money(finalTotal)}', style: const TextStyle(fontSize: 42, color: PosTheme.accent, fontWeight: FontWeight.w800, height: 1.15)),
                    Text('费用 +¥${Fmt.money(fees)} · 折扣 $rate 折 · 抹零 -¥${Fmt.money(quiling)}${jifenMax > 0 ? ' · 积分 -¥${Fmt.money(jifenMax)}' : ''}',
                        style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                  ]),
                ),
                const SizedBox(height: 12),
                // 会员（v3.3.144：从已点账单底栏移入结账页）
                Row(children: [
                  const Text('会员', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                  const Spacer(),
                  if (vip != null)
                    InkWell(
                      onTap: _clearVip,
                      borderRadius: BorderRadius.circular(8),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Text('清除', style: TextStyle(fontSize: 11.5, color: PosTheme.red)),
                      ),
                    ),
                ]),
                const SizedBox(height: 6),
                if (vip == null)
                  InkWell(
                    onTap: _pickVip,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F8FA),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: PosTheme.line),
                      ),
                      child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.person_add_alt, size: 19, color: PosTheme.textSub),
                        SizedBox(width: 7),
                        Text('选择会员（余额支付 / 积分抵扣）',
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: PosTheme.textSub)),
                      ]),
                    ),
                  )
                else
                  InkWell(
                    onTap: _pickVip,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF2ED),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: PosTheme.accent.withOpacity(0.4)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.person, size: 18, color: PosTheme.accent),
                        const SizedBox(width: 7),
                        Expanded(child: Text('${vip!['name'] ?? vip!['phone'] ?? ''}　余额 ¥${Fmt.money(_balance)}',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: PosTheme.accent))),
                        // 充值入口（v3.3.164）：余额不足时当场扫码充值，成功后留在结账界面继续结算
                        InkWell(
                          onTap: _rechargeVip,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: PosTheme.accent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.savings_outlined, size: 14, color: Colors.white),
                              SizedBox(width: 4),
                              Text('充值', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.swap_horiz, size: 16, color: PosTheme.accent),
                      ]),
                    ),
                  ),
                const SizedBox(height: 12),
                const Text('支付方式', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                const SizedBox(height: 8),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 3.4,
                  children: _methods.map(_payCard).toList(),
                ),
                if (method == '会员余额') ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(color: const Color(0xFFFFF2ED), borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      '会员「${vip?['name'] ?? vip?['phone'] ?? ''}」余额 ¥${Fmt.money(_balance)}　扣款后 ¥${Fmt.money((_balance - finalTotal).clamp(0, double.maxFinite))}',
                      style: const TextStyle(fontSize: 12, color: PosTheme.accent),
                    ),
                  ),
                ],
                if (method == '挂账') ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(color: const Color(0xFFFFF1F0), borderRadius: BorderRadius.circular(10)),
                    child: const Text(
                      '挂账不收款，桌台释放；账款进入「挂账台账」，稍后核销收款',
                      style: TextStyle(fontSize: 12, color: PosTheme.red),
                    ),
                  ),
                ],
                // 现金找零面板（v3.3.150）：实收可收整钱，自动算找零
                if (method == '现金') ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FBF5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF22B573).withOpacity(0.3)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('实收现金', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textSub)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: cashCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF22B573)),
                        decoration: const InputDecoration(
                          hintText: '0.00', isDense: true,
                          prefixText: '¥ ',
                          prefixStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF22B573)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // 常用面额快捷键：直接按面额收，自动算找零
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        _cashQuick('刚好', finalTotal),
                        _cashQuick('¥50', 50),
                        _cashQuick('¥100', 100),
                        _cashQuick('¥200', 200),
                        _cashQuick('¥500', 500),
                      ]),
                      const SizedBox(height: 8),
                      if (_cash >= finalTotal)
                        Row(children: [
                          const Text('找零', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: PosTheme.textSub)),
                          const Spacer(),
                          Text('¥${Fmt.money(_cash - finalTotal)}',
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF22B573))),
                        ])
                      else
                        const Row(children: [
                          Icon(Icons.error_outline, size: 16, color: PosTheme.red),
                          SizedBox(width: 4),
                          Text('实收现金不足应收金额', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: PosTheme.red)),
                        ]),
                    ]),
                  ),
                ],
                // 微信/支付宝：扫码收款提示（v3.3.161 付款码收款）
                if (method == '微信支付' || method == '支付宝') ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F8FF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF1677FF).withOpacity(0.25)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(Icons.qr_code_scanner, size: 16, color: payColors[method]),
                        const SizedBox(width: 5),
                        Text('扫码收款 · 应收 ¥${Fmt.money(finalTotal)}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: PosTheme.textMain)),
                      ]),
                      const SizedBox(height: 4),
                      Text('点卡片即进入扫码模式：扫码枪扫顾客付款码，付款成功自动完成结账（取消则收回选中）',
                          style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                    ]),
                  ),
                ],
              ])),
              ),
            ),
          ])),
          // ===== 底部操作（大按钮适配触屏） =====
          Container(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Colors.white, Color(0xFFFFF3ED)], begin: Alignment.centerLeft, end: Alignment.centerRight),
              border: Border(top: BorderSide(color: PosTheme.line)),
            ),
            child: Row(children: [
              const Spacer(),
              // 大结算按钮：渐变 + 大字号 + 大热区（触屏友好）
              Builder(builder: (_) {
                final blocked = method == null || (method == '现金' && _cash < finalTotal); // 现金不足禁止确认
                return InkWell(
                onTap: blocked
                    ? null
                    : () => Navigator.pop(context, {
                          'final': finalTotal,
                          'kaitai_fee': _num(kaitaiCtrl),
                          'tea_fee': _num(teaCtrl),
                          'service_fee': _num(serviceCtrl),
                          'box_fee': _num(boxCtrl),
                          'discount_rate': rate,
                          'quiling': quiling,
                          'jifen_num': (jifenMax * 100).round(),
                          'jifen_deduct': jifenMax,
                          'invoice_title': invoiceCtrl.text.trim(),
                          'invoice_no': invoiceNoCtrl.text.trim(),
                          'order_remark': remarkCtrl.text.trim(),
                          'method': method,
                          'vip': vip,
                          'cash_received': method == '现金' ? _cash : 0.0,
                          'cash_change': method == '现金' ? (_cash - finalTotal).clamp(0, double.maxFinite).toDouble() : 0.0,
                        }),
                borderRadius: BorderRadius.circular(16),
                child: Opacity(
                  opacity: blocked ? 0.45 : 1,
                  child: Container(
                    height: 58,
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [PosTheme.accent, PosTheme.accentDeep]),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: blocked ? null : [
                        BoxShadow(color: PosTheme.accent.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 4)),
                      ],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.check_circle_outline, size: 22, color: Colors.white),
                      const SizedBox(width: 9),
                      Text(
                        method == null
                            ? '请选择支付方式'
                            : method == '现金' && _cash < finalTotal
                                ? '实收现金不足'
                                : '确认收款 · ¥${Fmt.money(finalTotal)}',
                        style: const TextStyle(fontSize: 17.5, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                    ]),
                  ),
                ),
                );
              }),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _section(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
        const SizedBox(height: 6),
        child,
      ]),
    );
  }

  /// 现金快捷面额：一键按面额实收（刚好 = 按应收金额）
  Widget _cashQuick(String label, double v) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => cashCtrl.text = v.toStringAsFixed(2)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF22B573).withOpacity(0.4)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF22B573))),
      ),
    );
  }

  /// 支付方式图标：微信支付/支付宝用官方品牌 logo，其余用 Material 图标
  Widget _payIcon(String m, bool on) {
    final c = payColors[m] ?? PosTheme.textSub;
    if (m == '微信支付') {
      // 官方微信支付 logo（气泡+对勾）；选中白色版在彩色渐变卡上依然清晰
      return WechatPayLogo(
          size: 28, color: on ? Colors.white : const Color(0xFF07C160));
    }
    if (m == '支付宝') {
      return AlipayLogo(size: 27, color: on ? Colors.white : const Color(0xFF1677FF));
    }
    return Icon(payIcons[m] ?? Icons.payments_outlined,
        size: 21, color: on ? Colors.white : c);
  }

  /// 支付方式大卡片：每种方式独立品牌色，选中整卡彩色渐变 + 白字（v3.3.146）
  Widget _payCard(String m) {
    final on = method == m;
    final c = payColors[m] ?? PosTheme.textSub;
    final cd = payDarks[m] ?? c;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _tapMethod(m),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          gradient: on ? LinearGradient(colors: [c, cd], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
          color: on ? null : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: on ? Colors.transparent : PosTheme.line),
          boxShadow: on ? [BoxShadow(color: c.withOpacity(0.32), blurRadius: 10, offset: const Offset(0, 3))] : null,
        ),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: on ? Colors.white.withOpacity(0.22) : c.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: _payIcon(m, on),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: on ? Colors.white : PosTheme.textMain)),
            const SizedBox(height: 1),
            Text(paySubs[m] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: on ? Colors.white.withOpacity(0.85) : PosTheme.textHint)),
          ])),
          // 微信/支付宝：扫码枪直达角标（点卡片即扫码，免确认）
          if (m == '微信支付' || m == '支付宝')
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: on ? Colors.white.withOpacity(0.22) : c.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('扫码枪', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: on ? Colors.white : c)),
            )
          else if (on)
            const Icon(Icons.check_circle, size: 20, color: Colors.white),
        ]),
      ),
    );
  }

  Widget _feeField(String label, TextEditingController c) {
    return Expanded(child: TextField(
      controller: c,
      keyboardType: TextInputType.number,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(hintText: label, isDense: true),
    ));
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          gradient: on ? const LinearGradient(colors: [PosTheme.accent, PosTheme.accentDeep]) : null,
          color: on ? null : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: on ? Colors.white : PosTheme.textSub)),
      ),
    );
  }
}
