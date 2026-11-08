import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/print_prefs.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';
import '../../ui/xyf_scan_pay.dart';

/// 餐饮点餐方式扩展（v3.3.63）：
/// 不开台点餐 / 排队取号叫号 / 预约列表 / 挂账台账 / 选桌扫码
/// 外卖点餐已移除（v3.3.119），点餐码入口已移除（顶栏不再显示）

// ==================== 不开台点餐（快餐/外带 · 即点即收） ====================

class DirectOrderDialog extends StatefulWidget {
  const DirectOrderDialog({super.key});
  @override
  State<DirectOrderDialog> createState() => _DirectOrderDialogState();
}

class _DirectOrderDialogState extends State<DirectOrderDialog> {
  List cats = [];
  List dishes = [];
  int catId = -1;
  bool loading = true;
  final List<Map<String, dynamic>> cart = [];
  Map? vip; // 会员余额支付用

  double get total =>
      cart.fold(0, (s, g) => s + (g['unit_price'] as double) * (g['quantity'] as int));

  @override
  void initState() {
    super.initState();
    _loadCats();
  }

  Future<void> _loadCats() async {
    try {
      final c = await Api.goodsCats(Session.wenxunId);
      if (!mounted) return;
      setState(() {
        cats = c;
        loading = false;
        if (c.isNotEmpty) catId = int.tryParse('${c.first['id']}') ?? -1;
      });
      _loadDishes();
    } on ApiError {
      if (!mounted) return;
      setState(() => loading = false);
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

  void _add(Map g) {
    final id = '${g['id']}';
    for (final c in cart) {
      if ('${c['goods_id']}' == id) {
        setState(() => c['quantity'] = (c['quantity'] as int) + 1);
        return;
      }
    }
    setState(() => cart.add({
          'goods_id': g['id'],
          'goods_name': g['title'],
          'goods_image': g['goods_image'] ?? '',
          'unit_price': double.tryParse('${g['amount'] ?? g['price']}') ?? 0,
          'quantity': 1,
        }));
  }

  Future<void> _pickVip() async {
    final v = await showDialog<Map>(context: context, builder: (_) => const _DirectVipPicker());
    if (v != null && mounted) setState(() => vip = v);
  }

  Future<void> _checkout(String method,
      {String xyfOrderNo = '', int xyfChannel = 0}) async {
    if (cart.isEmpty) {
      toast(context, '请先点选菜品', error: true);
      return;
    }
    if (method == '会员余额') {
      if (vip == null) {
        await _pickVip();
        if (vip == null || !mounted) return;
      }
      final bal = (double.tryParse('${vip!['amount'] ?? 0}') ?? 0) +
          (double.tryParse('${vip!['gift_balance'] ?? 0}') ?? 0);
      if (bal < total) {
        toast(context, '会员余额不足（¥${Fmt.money(bal)}）', error: true);
        return;
      }
    }
    final ok = await confirm(context, '不开台收款', '${method}收款 ¥${Fmt.money(total)}，共 ${cart.length} 项菜品，确认？');
    if (!ok || !mounted) return;
    loadingDialog(context, '收款中…');
    try {
      final r = await Api.directSettle(
        wenxunId: Session.wenxunId,
        operatorId: Session.staffId,
        operatorName: Session.staffName,
        goodsTotal: total,
        finalTotal: total,
        pay1Type: method,
        pay1Money: total,
        cart: cart,
        vipId: method == '会员余额' ? (int.tryParse('${vip!['id']}') ?? 0) : 0,
        phone: method == '会员余额' ? '${vip!['phone'] ?? ''}' : '',
        payOrderNo: xyfOrderNo,
        payChannel: xyfChannel,
      );
      if (!mounted) return;
      Navigator.pop(context); // loading
      if ('${r['code']}' == '200') {
        final orderSn = '${r['data']?['order_sn'] ?? ''}';
        final payMethod = method;
        final items = cart.map((c) => {'goods_name': c['goods_name'], 'unit_price': c['unit_price'], 'quantity': c['quantity']}).toList();
        final amt = total;
        Navigator.pop(context, {'amount': amt}); // 关闭本弹窗
        if (await PrintPrefs.on('dining')) {
          CloudPrinter.print(CloudPrinter.diningReceipt(
            orderSn: orderSn,
            tableTitle: '不开台（外带/快餐）',
            peopleNum: 1,
            payMethod: payMethod,
            goodsTotal: amt,
            finalTotal: amt,
            cart: items,
          )).catchError((_) => <String, dynamic>{});
        }
      } else {
        toast(context, '${r['msg'] ?? '收款失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 880, height: 620,
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('不开台点餐', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFF0F5FF), borderRadius: BorderRadius.circular(20)),
              child: const Text('快餐 / 外带 · 即点即收', style: TextStyle(fontSize: 12, color: PosTheme.blue)),
            ),
            const Spacer(),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 12),
          Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 左：分类 + 菜品
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                height: 42,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final c in cats)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _catChip(c),
                    ),
                ]),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                    : GridView.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 150, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.95,
                        ),
                        itemCount: dishes.length,
                        itemBuilder: (_, i) => _dishCard(dishes[i]),
                      ),
              ),
            ])),
            const SizedBox(width: 16),
            // 右：购物车
            Container(
              width: 300,
              decoration: BoxDecoration(color: PosTheme.bg, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  alignment: Alignment.centerLeft,
                  child: Text('已点 ${cart.length} 项', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                ),
                Expanded(
                  child: cart.isEmpty
                      ? const Center(child: Text('点击左侧菜品加单', style: TextStyle(color: PosTheme.textHint)))
                      : ListView(children: [
                          for (final g in cart) _cartRow(g),
                        ]),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                  child: Column(children: [
                    Row(children: [
                      const Text('合计', style: TextStyle(fontSize: 14, color: PosTheme.textSub)),
                      const Spacer(),
                      Text('¥${Fmt.money(total)}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: PosTheme.accent)),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: BigButton('现金收款', onTap: () => _checkout('现金'), color: PosTheme.green, height: 46)),
                      const SizedBox(width: 8),
                      Expanded(child: BigButton('扫码收款（星驿付）', onTap: () => _pickScanPay(), color: PosTheme.blue, height: 46)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: BigButton(
                        vip == null ? '会员余额（选会员）' : '会员余额 · ${vip!['name'] ?? vip!['phone']}',
                        onTap: () => _checkout('会员余额'),
                        color: PosTheme.accent, height: 46,
                      )),
                    ]),
                  ]),
                ),
              ]),
            ),
          ])),
        ]),
      ),
    );
  }

  Widget _catChip(Map c) {
    final on = catId == int.tryParse('${c['id']}');
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () { setState(() => catId = int.tryParse('${c['id']}') ?? -1); _loadDishes(); },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Text('${c['title'] ?? c['name'] ?? ''}',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  Widget _dishCard(Map g) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _add(g),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(border: Border.all(color: PosTheme.line), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: ('${g['goods_image'] ?? ''}').isNotEmpty
                ? ClipRRect(borderRadius: BorderRadius.circular(6),
                    child: Image.network(Api.base + ('${g['goods_image']}'.startsWith('/') ? '' : '/') + '${g['goods_image']}',
                        width: double.infinity, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.restaurant, color: PosTheme.textHint)))
                : const Icon(Icons.restaurant, color: PosTheme.textHint)),
            const SizedBox(height: 4),
            Text('${g['title'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            Text('¥${Fmt.money(double.tryParse('${g['amount'] ?? g['price']}') ?? 0)}',
                style: const TextStyle(fontSize: 12, color: PosTheme.accent, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }

  Widget _cartRow(Map g) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Expanded(child: Text('${g['goods_name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5))),
        InkWell(onTap: () { setState(() { if ((g['quantity'] as int) > 1) { g['quantity'] = (g['quantity'] as int) - 1; } else { cart.remove(g); } }); }, child: const Icon(Icons.remove_circle_outline, size: 22, color: PosTheme.textHint)),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('${g['quantity']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
        InkWell(onTap: () => setState(() => g['quantity'] = (g['quantity'] as int) + 1), child: const Icon(Icons.add_circle_outline, size: 22, color: PosTheme.accent)),
        SizedBox(width: 64, child: Text('¥${Fmt.money((g['unit_price'] as double) * (g['quantity'] as int))}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  /// 扫码收款（v3.3.161）：星驿付付款码支付，扫码枪扫顾客付款码
  /// 微信/支付宝/云闪付自动识别，无需先选通道；成功后按「扫码收款」落单
  /// 预生成我方单号：支付流水与结算单 pay_order_no 关联，退款按此原路退（v3.3.162）
  Future<void> _pickScanPay() async {
    final myNo = 'XYFD${DateTime.now().millisecondsSinceEpoch}'
        '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
    final pay = await showXyfScanPayDialog(context,
        amount: total, title: '扫码收款', bizType: 'dining', orderNo: myNo);
    if (pay == null || !mounted) return;
    final ch = int.tryParse('${pay['order']?['pay_channel'] ?? 0}') ?? 0;
    _checkout('扫码收款',
        xyfOrderNo: '${pay['orderNo'] ?? myNo}', xyfChannel: ch);
  }
}

/// 不开台点餐 · 会员选择（手机号搜索）
class _DirectVipPicker extends StatefulWidget {
  const _DirectVipPicker();
  @override
  State<_DirectVipPicker> createState() => _DirectVipPickerState();
}

class _DirectVipPickerState extends State<_DirectVipPicker> {
  final phoneCtrl = TextEditingController();
  List result = [];
  bool searching = false;

  Future<void> _search() async {
    final kw = phoneCtrl.text.trim();
    if (kw.isEmpty) return;
    setState(() => searching = true);
    try {
      final l = await Api.vipSearch(Session.wenxunId, kw);
      if (!mounted) return;
      setState(() { result = l; searching = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => searching = false);
      toast(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择会员', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: TextField(
            controller: phoneCtrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '输入会员手机号', isDense: true),
            onSubmitted: (_) => _search(),
          )),
          const SizedBox(width: 8),
          BigButton('搜索', onTap: _search, width: 84, height: 40),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 240,
          child: searching
              ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
              : result.isEmpty
                  ? const Center(child: Text('暂无结果', style: TextStyle(color: PosTheme.textHint)))
                  : ListView(children: [
                      for (final v in result)
                        ListTile(
                          dense: true,
                          title: Text('${v['name'] ?? ''} ${v['phone'] ?? ''}', style: const TextStyle(fontSize: 14)),
                          subtitle: Text('余额 ¥${Fmt.money(double.tryParse('${v['amount'] ?? 0}') ?? 0)}',
                              style: const TextStyle(fontSize: 12.5, color: PosTheme.accent)),
                          onTap: () => Navigator.pop(context, v as Map),
                        ),
                    ]),
        ),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
    );
  }
}

// ==================== 排队点餐（取号 + 叫号） ====================

class PaihaoDialog extends StatefulWidget {
  const PaihaoDialog({super.key});
  @override
  State<PaihaoDialog> createState() => _PaihaoDialogState();
}

class _PaihaoDialogState extends State<PaihaoDialog> {
  List list = [];
  int waiting = 0;
  bool loading = true;
  int persons = 1;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.paihaoLst();
      if (!mounted) return;
      setState(() {
        list = (r['list'] ?? []) as List;
        waiting = int.tryParse('${r['waiting']}') ?? 0;
        loading = false;
      });
    } on ApiError {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  Future<void> _speak(String text) async {
    // 语音播报已停用（Windows 7 兼容，移除 flutter_tts）
  }

  Future<void> _take() async {
    setState(() => busy = true);
    try {
      final r = await Api.paihaoAdd(persons: persons);
      if (!mounted) return;
      setState(() => busy = false);
      if ('${r['code']}' == '200') {
        final number = int.tryParse('${r['data']?['number']}') ?? 0;
        final p = int.tryParse('${r['data']?['persons']}') ?? persons;
        toast(context, '已取号：${number} 号（$p 位）');
        // 打印排队号票
        final sb = StringBuffer();
        sb.writeln('<FS2><center>排队号</center></FS2>');
        sb.writeln('--------------------------------');
        sb.writeln('您的号码：');
        sb.writeln('<FS2><center>** $number **</center></FS2>');
        sb.writeln('$p 位 · 前方 $waiting 桌');
        sb.writeln('时间: ${DateTime.now().toString().substring(0, 19)}');
        sb.writeln('请留意叫号，过号重排');
        if (await PrintPrefs.on('queue')) {
          CloudPrinter.print(sb.toString()).catchError((_) => <String, dynamic>{});
        }
        _load();
      } else {
        toast(context, '${r['msg'] ?? '取号失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => busy = false);
      toast(context, e.message, error: true);
    }
  }

  Future<void> _call(Map row) async {
    try {
      final r = await Api.paihaoCall(id: int.tryParse('${row['id']}') ?? 0);
      if (!mounted) return;
      if ('${r['code']}' == '200') {
        final number = int.tryParse('${r['data']?['number']}') ?? 0;
        final p = int.tryParse('${r['data']?['persons']}') ?? 1;
        toast(context, '已叫号：$number 号');
        _speak('请 $number 号，$p 位顾客，到店入座');
        _load();
      } else {
        toast(context, '${r['msg'] ?? '叫号失败'}', error: true);
      }
    } on ApiError catch (e) {
      toast(context, e.message, error: true);
    }
  }

  Future<void> _mark(Map row, int status) async {
    try {
      final r = await Api.paihaoMark(id: int.tryParse('${row['id']}') ?? 0, status: status);
      if (!mounted) return;
      if ('${r['code']}' == '200') {
        _load();
      } else {
        toast(context, '${r['msg'] ?? '操作失败'}', error: true);
      }
    } on ApiError catch (e) {
      toast(context, e.message, error: true);
    }
  }

  String _statusText(int s) => const {0: '等待', 1: '已叫号', 2: '完成', 3: '过号'}[s] ?? '';
  Color _statusColor(int s) => const {0: PosTheme.amber, 1: PosTheme.green, 2: PosTheme.textHint, 3: PosTheme.textHint}[s] ?? PosTheme.textHint;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 560, height: 600,
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('排队取号', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFFFF2ED), borderRadius: BorderRadius.circular(20)),
              child: Text('等待中 $waiting 桌', style: const TextStyle(fontSize: 12, color: PosTheme.accent)),
            ),
            const Spacer(),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 12),
          // 取号区
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: PosTheme.bg, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Text('用餐人数', style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
              const SizedBox(width: 10),
              InkWell(onTap: persons > 1 ? () => setState(() => persons--) : null, child: const Icon(Icons.remove_circle_outline, color: PosTheme.textHint)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Text('$persons', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
              InkWell(onTap: () => setState(() => persons++), child: const Icon(Icons.add_circle_outline, color: PosTheme.accent)),
              const Spacer(),
              BigButton('取号', onTap: busy ? null : _take, width: 130, height: 44),
            ]),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                : list.isEmpty
                    ? const Center(child: Text('今日暂无排队', style: TextStyle(color: PosTheme.textHint)))
                    : ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: PosTheme.line),
                        itemBuilder: (_, i) {
                          final row = list[i] as Map;
                          final st = int.tryParse('${row['status']}') ?? 0;
                          final t = '${row['create_time'] ?? ''}';
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                            leading: Container(
                              width: 56, height: 40, alignment: Alignment.center,
                              decoration: BoxDecoration(color: PosTheme.bg, borderRadius: BorderRadius.circular(8)),
                              child: Text('${row['number']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: PosTheme.accent)),
                            ),
                            title: Text('${row['persons']} 位 · ${st == 0 ? '前方尚有排队' : _statusText(st)}',
                                style: const TextStyle(fontSize: 13.5)),
                            subtitle: Text('${t.length >= 16 ? t.substring(11, 16) : t} · ${row['operator_name'] ?? ''}',
                                style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(color: _statusColor(st).withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                                child: Text(_statusText(st), style: TextStyle(fontSize: 12, color: _statusColor(st), fontWeight: FontWeight.w600)),
                              ),
                              if (st == 0) ...[
                                const SizedBox(width: 8),
                                BigButton('叫号', onTap: () => _call(row), color: PosTheme.green, width: 74, height: 36),
                                const SizedBox(width: 6),
                                BigButton('过号', onTap: () => _mark(row, 3), color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, width: 74, height: 36),
                              ] else if (st == 1) ...[
                                const SizedBox(width: 8),
                                BigButton('完成', onTap: () => _mark(row, 2), color: PosTheme.accent, width: 74, height: 36),
                              ],
                            ]),
                          );
                        },
                      ),
          ),
        ]),
      ),
    );
  }
}

// ==================== 预约列表（预约点餐入口） ====================

class BookListDialog extends StatelessWidget {
  final List tables;
  final void Function(Map table) onArrival;
  final void Function(Map table) onCancelBook;
  const BookListDialog({super.key, required this.tables, required this.onArrival, required this.onCancelBook});

  @override
  Widget build(BuildContext context) {
    final booked = tables.where((t) => '${t['status']}' == '1').toList();
    return Dialog(
      child: Container(
        width: 560, height: 520,
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('预约点餐', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFFFF8EC), borderRadius: BorderRadius.circular(20)),
              child: Text('今日预约 ${booked.length} 桌', style: const TextStyle(fontSize: 12, color: PosTheme.amber)),
            ),
            const Spacer(),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(color: const Color(0xFFFFF8EC), borderRadius: BorderRadius.circular(10)),
            child: const Text('预约新桌：关闭本窗口，点击空闲桌台 → 开台弹窗内点「预点餐」保存即预约；预点菜顾客到店一键开台',
                style: TextStyle(fontSize: 12.5, color: PosTheme.amber)),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: booked.isEmpty
                ? const Center(child: Text('暂无预约桌台', style: TextStyle(color: PosTheme.textHint)))
                : ListView.separated(
                    itemCount: booked.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: PosTheme.line),
                    itemBuilder: (_, i) {
                      final t = booked[i] as Map;
                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                        leading: Container(
                          width: 64, height: 44, alignment: Alignment.center,
                          decoration: BoxDecoration(color: const Color(0xFFFFF8EC), borderRadius: BorderRadius.circular(8)),
                          child: Text('${t['title'] ?? ''}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.amber)),
                        ),
                        title: Text('${t['booked_user'] ?? t['book_operator_name'] ?? '顾客'}',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        subtitle: Text('${t['quyu'] ?? ''} ${t['renshu'] ?? ''} 人桌 · ${t['booked_time'] ?? t['book_time'] ?? ''}',
                            style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          BigButton('到店开台', onTap: () { Navigator.pop(context); onArrival(t); }, width: 108, height: 38),
                          const SizedBox(width: 6),
                          BigButton('取消预约', onTap: () { Navigator.pop(context); onCancelBook(t); }, color: const Color(0xFFFFF1F0), textColor: PosTheme.red, width: 108, height: 38),
                        ]),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

// ==================== 挂账台账（列表 + 核销收款） ====================

class GuazhangDialog extends StatefulWidget {
  const GuazhangDialog({super.key});
  @override
  State<GuazhangDialog> createState() => _GuazhangDialogState();
}

class _GuazhangDialogState extends State<GuazhangDialog> {
  int tab = 0; // 0-未结 1-已结
  List list = [];
  int unsettled = 0;
  double unsettledSum = 0;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final r = await Api.guazhangLst();
      if (!mounted) return;
      setState(() {
        list = (r['list'] ?? []) as List;
        unsettled = int.tryParse('${r['unsettled']}') ?? 0;
        unsettledSum = double.tryParse('${r['unsettled_sum']}') ?? 0;
        loading = false;
      });
    } on ApiError {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  Future<void> _settle(Map row) async {
    final pay = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('挂账核销', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: SizedBox(width: 280, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('挂账人：${row['name'] ?? ''} ${row['phone'] ?? ''}', style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
          const SizedBox(height: 6),
          Text('金额 ¥${Fmt.money(double.tryParse('${row['amount']}') ?? 0)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: PosTheme.accent)),
          const SizedBox(height: 14),
          BigButton('现金收款', onTap: () => Navigator.pop(context, '现金'), color: PosTheme.green, height: 46),
          const SizedBox(height: 8),
          BigButton('扫码收款（星驿付）', onTap: () => Navigator.pop(context, '扫码收款'), color: PosTheme.blue, height: 46),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
      ),
    );
    if (pay == null || !mounted) return;
    // 扫码收款：先星驿付真实收款，成功后再核销（v3.3.161）
    if (pay == '扫码收款') {
      final scan = await showXyfScanPayDialog(context,
          amount: double.tryParse('${row['amount']}') ?? 0, title: '挂账核销 · 扫码收款', bizType: 'dining');
      if (scan == null || !mounted) return;
    }
    final ok = await confirm(context, '确认收款', '挂账 ¥${Fmt.money(double.tryParse('${row['amount']}') ?? 0)} 已收到（$pay），核销本笔？');
    if (!ok || !mounted) return;
    loadingDialog(context, '核销中…');
    try {
      final r = await Api.guazhangSettle(id: int.tryParse('${row['id']}') ?? 0, payType: pay);
      if (!mounted) return;
      Navigator.pop(context); // loading
      if ('${r['code']}' == '200') {
        toast(context, '核销成功 ¥${Fmt.money(double.tryParse('${row['amount']}') ?? 0)}');
        // 打印结清小票
        final d = (r['data'] ?? {}) as Map;
        if (await PrintPrefs.on('dining')) {
          final gzName = '${row['name'] ?? ''}'.trim();
          final gzPhone = '${row['phone'] ?? ''}'.trim();
          CloudPrinter.print(CloudPrinter.diningReceipt(
          orderSn: '${d['order_sn'] ?? row['order_sn'] ?? ''}',
          tableTitle: '${row['table_title'] ?? ''}（挂账结清）',
          peopleNum: 1,
          payMethod: pay,
          goodsTotal: double.tryParse('${row['amount']}') ?? 0,
          finalTotal: double.tryParse('${row['amount']}') ?? 0,
          cart: const [],
          extraLines: gzName.isEmpty
              ? const []
              : ['挂账人: $gzName${gzPhone.isNotEmpty ? '　电话: $gzPhone' : ''}'],
          )).catchError((_) => <String, dynamic>{});
        }
        _load();
      } else {
        toast(context, '${r['msg'] ?? '核销失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = list.where((r) => int.tryParse('${r['status']}') == tab).toList();
    return Dialog(
      child: Container(
        width: 620, height: 600,
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('挂账台账', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _tabChip('未结账', unsettled, 0),
            const SizedBox(width: 8),
            _tabChip('已核销', list.where((r) => '${r['status']}' == '1').length, 1),
            const Spacer(),
            if (tab == 0)
              Text('未结合计 ¥${Fmt.money(unsettledSum)}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.red)),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                : shown.isEmpty
                    ? Center(child: Text(tab == 0 ? '暂无未结挂账' : '暂无核销记录', style: TextStyle(color: PosTheme.textHint)))
                    : ListView.separated(
                        itemCount: shown.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: PosTheme.line),
                        itemBuilder: (_, i) {
                          final row = shown[i] as Map;
                          final t = '${row['create_time'] ?? ''}';
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                            leading: const Icon(Icons.receipt_long, color: PosTheme.textHint),
                            title: Text('${row['name'] ?? ''}${'${row['phone'] ?? ''}'.isEmpty ? '' : ' · ${row['phone']}'}　${row['table_title'] ?? ''}',
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            subtitle: Text('单号 ${row['order_sn'] ?? ''} · ${t.length >= 16 ? t.substring(0, 16) : t}${tab == 1 ? ' · ${row['pay_type'] ?? ''} 核销' : ''}',
                                style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text('¥${Fmt.money(double.tryParse('${row['amount']}') ?? 0)}',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: tab == 0 ? PosTheme.red : PosTheme.textHint)),
                              if (tab == 0) ...[
                                const SizedBox(width: 10),
                                BigButton('核销收款', onTap: () => _settle(row), width: 104, height: 38),
                              ],
                            ]),
                          );
                        },
                      ),
          ),
        ]),
      ),
    );
  }

  Widget _tabChip(String label, int count, int v) {
    final on = tab == v;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => tab = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Text('$label $count', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
      ),
    );
  }
}

// ==================== 选桌弹窗（扫码点餐 / 自助点餐入口） ====================

class TablePickDialog extends StatelessWidget {
  final List tables;
  final String title;
  const TablePickDialog({super.key, required this.tables, this.title = '选择桌台'});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 620, height: 560,
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 6),
          const Text('点击桌台生成/查看该桌的点餐二维码，顾客微信扫码即可自助点餐',
              style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
          const SizedBox(height: 10),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.4,
              ),
              itemCount: tables.length,
              itemBuilder: (_, i) {
                final t = tables[i] as Map;
                final st = int.tryParse('${t['status']}') ?? 0;
                final stText = const {0: '空闲', 1: '已预定', 2: '就餐中', 3: '扫码点餐', 4: '待清台'}[st] ?? '';
                final stColor = const {0: PosTheme.green, 1: PosTheme.amber, 2: PosTheme.accent, 3: PosTheme.blue, 4: PosTheme.textHint}[st] ?? PosTheme.textHint;
                return Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.pop(context, t),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(border: Border.all(color: PosTheme.line), borderRadius: BorderRadius.circular(12)),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text('${t['title'] ?? ''}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text('${t['quyu'] ?? ''} ${t['renshu'] ?? ''}人桌', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(color: stColor.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                          child: Text(stText, style: TextStyle(fontSize: 11.5, color: stColor, fontWeight: FontWeight.w600)),
                        ),
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

// ==================== 挂账信息登记（结账弹窗选「挂账」时） ====================

/// 返回 {'name': 姓名, 'phone': 电话, 'vip_id': 0}；取消返回 null
Future<Map<String, String>?> showGuazhangInfoDialog(BuildContext context) async {
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  return showDialog<Map<String, String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('挂账登记', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      content: SizedBox(width: 340, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(color: const Color(0xFFFFF2ED), borderRadius: BorderRadius.circular(10)),
          child: const Text('挂账后桌台释放，账款进入「挂账台账」，稍后在餐饮页 → 挂账点餐 中核销收款',
              style: TextStyle(fontSize: 12.5, color: PosTheme.accent)),
        ),
        const SizedBox(height: 12),
        TextField(controller: nameCtrl, autofocus: true, decoration: const InputDecoration(labelText: '挂账人姓名（必填）', isDense: true)),
        const SizedBox(height: 10),
        TextField(controller: phoneCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: '联系电话（选填）', isDense: true)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ElevatedButton(
          onPressed: () {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) {
              toast(ctx, '请填写挂账人姓名', error: true);
              return;
            }
            Navigator.pop(ctx, {'name': name, 'phone': phoneCtrl.text.trim()});
          },
          style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
          child: const Text('确认挂账'),
        ),
      ],
    ),
  );
}

// ==================== 开台点餐 · 人数数字键盘弹窗（v3.3.67） ====================
/// 收银员点桌台图 → 弹窗显示该桌台名称 → 数字键盘输人数 → 确认开台
/// 仅屏上数字键盘录入（1-9 / 0 / 00 / 清空），无文本框、不响应物理键盘

class KaitaiKeypadDialog extends StatefulWidget {
  final Map table; // 开台的桌台（点桌台图传入）
  final Future<void> Function(Map table, String kaitaiId) onOpened;
  final Future<void> Function(Map table)? onPreorder; // 打开预点餐/改菜（v3.3.90）
  const KaitaiKeypadDialog({super.key, required this.table, required this.onOpened, this.onPreorder});
  @override
  State<KaitaiKeypadDialog> createState() => _KaitaiKeypadDialogState();
}

class _KaitaiKeypadDialogState extends State<KaitaiKeypadDialog> {
  String people = '';
  Map<String, dynamic>? preorder; // 该桌预点单（v3.3.90：点空闲桌台弹窗显示）

  Map get table => widget.table;
  int get _peopleNum => int.tryParse(people) ?? 0;
  bool get _canOpen => _peopleNum >= 1;

  @override
  void initState() {
    super.initState();
    _loadPreorder();
  }

  Future<void> _loadPreorder() async {
    try {
      final r = await Api.preorderGet(wenxunId: Session.wenxunId, tableId: int.tryParse('${table['id']}') ?? 0);
      if (!mounted) return;
      if ('${r['code']}' == '200') {
        final list = (r['list'] ?? []) as List;
        setState(() {
          preorder = {
            'count': list.length,
            'total': '${r['total'] ?? '0.00'}',
            'remark': '${r['remark'] ?? ''}',
          };
        });
      }
    } on ApiError {
      // 查询失败不影响开台
    }
  }

  void _key(String k) {
    if (k == 'C') {
      setState(() => people = '');
      return;
    }
    if (people.length >= 3) return;
    // 禁止 0 / 00 开头（0、00、01 等无效人数，10、20 等正常输入不受影响）
    if (people.isEmpty && k.startsWith('0')) return;
    setState(() => people = people + k);
  }

  Future<void> _open() async {
    if (!_canOpen) return;
    loadingDialog(context, '开台中…');
    try {
      final r = await Api.tableOpen(
        wenxunId: Session.wenxunId,
        tableId: int.tryParse('${table['id']}') ?? 0,
        peopleNum: _peopleNum,
        operatorId: Session.staffId,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      Navigator.pop(context); // loading
      if ('${r['code']}' == '200') {
        final kaitaiId = '${r['data']?['kaitai_id'] ?? ''}';
        Navigator.pop(context); // 本弹窗
        widget.onOpened(table, kaitaiId.isEmpty ? '${table['kaitai_id'] ?? ''}' : kaitaiId);
      } else {
        toast(context, '${r['msg'] ?? '开台失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: 520,
        padding: const EdgeInsets.fromLTRB(26, 22, 26, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 头部：标题居中
          SizedBox(
            height: 34,
            child: Stack(children: [
              Align(
                alignment: Alignment.center,
                child: Text('开台点餐 · ${table['title']}', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: InkWell(
                  onTap: () => Navigator.pop(context),
                  borderRadius: BorderRadius.circular(18),
                  child: const Padding(padding: EdgeInsets.all(6), child: Icon(Icons.close, size: 24, color: PosTheme.textHint)),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          // 预点单摘要（v3.3.90：该桌已提前预点时展示）
          if (preorder != null && ((preorder!['count'] as int) > 0 || '${preorder!['remark']}'.trim().isNotEmpty)) ...[
            InkWell(
              onTap: widget.onPreorder == null ? null : () async { Navigator.pop(context); await widget.onPreorder!(table); },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: const Color(0xFFFFF8EC), borderRadius: BorderRadius.circular(12), border: Border.all(color: PosTheme.amber.withOpacity(0.35))),
                child: Row(children: [
                  const Icon(Icons.receipt_long, size: 18, color: PosTheme.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      (preorder!['count'] as int) > 0
                          ? '已预点 ${(preorder!['count'])} 项 · ¥${preorder!['total']}${('${preorder!['remark']}'.trim().isNotEmpty) ? ' · ${preorder!['remark']}' : ''}'
                          : '该桌已预约 · ${preorder!['remark']}',
                      style: const TextStyle(fontSize: 12.5, color: PosTheme.amber, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.onPreorder != null) ...[
                    const SizedBox(width: 6),
                    const Text('修改 ›', style: TextStyle(fontSize: 12.5, color: PosTheme.amber, fontWeight: FontWeight.w700)),
                  ],
                ]),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // 显示区：人数大字
          _display(),
          const SizedBox(height: 14),
          // 数字键盘 1-9 / 清空 / 0 / 00
          _keypad(),
          const SizedBox(height: 16),
          // 底部大按钮
          _actionButton(),
        ]),
      ),
    );
  }

  // ==================== 显示区（桌名已在标题显示，此处只显人数） ====================
  Widget _display() {
    return Container(
      height: 110,
      decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(16)),
      child: Center(
        child: people.isEmpty
            ? const Text('请输入人数', style: TextStyle(fontSize: 18, color: PosTheme.textHint, fontWeight: FontWeight.w600))
            : Text('$people 人', style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w800, color: PosTheme.accent)),
      ),
    );
  }

  // ==================== 数字键盘 ====================
  Widget _keypad() {
    Widget key(String label, {bool isClear = false}) {
      return Expanded(
        child: Material(
          color: isClear ? const Color(0xFFFFF1F0) : const Color(0xFFF5F6FA),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _key(isClear ? 'C' : label),
            child: Container(
              height: 62,
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: isClear ? PosTheme.red : PosTheme.textMain,
                ),
              ),
            ),
          ),
        ),
      );
    }
    Widget gap() => const SizedBox(width: 10);
    Widget rowGap() => const SizedBox(height: 10);
    return Column(children: [
      Row(children: [key('1'), gap(), key('2'), gap(), key('3')]),
      rowGap(),
      Row(children: [key('4'), gap(), key('5'), gap(), key('6')]),
      rowGap(),
      Row(children: [key('7'), gap(), key('8'), gap(), key('9')]),
      rowGap(),
      Row(children: [key('清空', isClear: true), gap(), key('0'), gap(), key('00')]),
    ]);
  }

  // ==================== 底部按钮 ====================
  Widget _actionButton() {
    return SizedBox(
      height: 56,
      child: ElevatedButton(
        onPressed: _canOpen ? _open : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: PosTheme.accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFE8E9EF),
          disabledForegroundColor: PosTheme.textHint,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        child: const Text('确认开台'),
      ),
    );
  }
}
