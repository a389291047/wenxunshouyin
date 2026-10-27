import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

/// 零售版 · 会员页：列表/查询/添加/充值/扣款/最近消费
class MemberPage extends StatefulWidget {
  const MemberPage({super.key});
  @override
  State<MemberPage> createState() => _MemberPageState();
}

class _MemberPageState extends State<MemberPage> {
  List list = [];
  bool loading = true;
  String kw = '';
  Map? selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final r = kw.isEmpty
          ? await Api.vipList(Session.wenxunId)
          : await Api.vipSearch(Session.wenxunId, kw);
      if (!mounted) return;
      setState(() { list = r; loading = false; });
      if (list.isNotEmpty && selected == null) selected = list.first;
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      toast(context, e.message, error: true);
    }
  }

  double _sumAmount() => list.fold(0, (s, v) => s + (double.tryParse('${v['amount']}') ?? 0));

  /// 头像字符：姓名 → 手机号 → '?'，空串不能取 first（会抛 Bad state）
  String _avatarChar(Map v) {
    final n = '${v['name'] ?? ''}'.trim();
    if (n.isNotEmpty) return n.characters.first;
    final p = '${v['phone'] ?? ''}'.trim();
    if (p.isNotEmpty) return p.characters.first;
    return '?';
  }

  // ==================== 添加会员 ====================
  Future<void> _addVip() async {
    if (!Session.vipadd) {
      toast(context, '当前账号没有添加会员权限', error: true);
      return;
    }
    final phoneCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final r = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('添加会员'),
        content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: phoneCtrl, keyboardType: TextInputType.phone, maxLength: 11,
              decoration: const InputDecoration(hintText: '手机号（必填）', counterText: '')),
          const SizedBox(height: 12),
          TextField(controller: nameCtrl, decoration: const InputDecoration(hintText: '会员姓名（选填）')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (r != true || !mounted) return;
    final phone = phoneCtrl.text.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      toast(context, '手机号格式不正确', error: true);
      return;
    }
    loadingDialog(context, '添加中…');
    try {
      final resp = await Api.vipAdd(wenxunId: Session.wenxunId, phone: phone, name: nameCtrl.text.trim());
      if (!mounted) return;
      Navigator.pop(context);
      final code = int.tryParse('${resp['code']}') ?? 0;
      final msg = '${resp['msg'] ?? ''}';
      if (code == 200 && (msg.contains('成功') || msg.isEmpty || msg == 'ok')) {
        toast(context, '添加成功');
        _load();
      } else {
        toast(context, msg.isEmpty ? '添加失败' : msg, error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 充值 ====================
  Future<void> _recharge() async {
    if (selected == null) return;
    final amountCtrl = TextEditingController();
    final giftCtrl = TextEditingController(text: '0');
    String payMethod = '现金';
    final r = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text('会员充值 · ${selected!['name'] ?? selected!['phone']}'),
        content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('当前余额 ¥${Fmt.money(selected!['amount'])}　赠送余额 ¥${Fmt.money(selected!['gift_balance'])}',
              style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
          const SizedBox(height: 14),
          TextField(controller: amountCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), autofocus: true,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(hintText: '充值金额', prefixText: '¥ ')),
          const SizedBox(height: 12),
          TextField(controller: giftCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(hintText: '赠送金额', prefixText: '¥ ')),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: ['现金', '微信支付', '支付宝'].map((m) =>
            ChoiceChip(
              label: Text(m),
              selected: payMethod == m,
              selectedColor: PosTheme.accent.withOpacity(0.15),
              labelStyle: TextStyle(color: payMethod == m ? PosTheme.accent : PosTheme.textMain, fontWeight: FontWeight.w600),
              onSelected: (_) => setD(() => payMethod = m),
            )).toList(),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认充值'),
          ),
        ],
      )),
    );
    if (r != true || !mounted) return;
    final amount = double.tryParse(amountCtrl.text) ?? 0;
    if (amount <= 0) {
      toast(context, '请输入正确的充值金额', error: true);
      return;
    }
    final gift = double.tryParse(giftCtrl.text) ?? 0;
    loadingDialog(context, '充值中…');
    try {
      final resp = await Api.vipRecharge(
        vipId: int.tryParse('${selected!['id']}') ?? 0,
        czamount: amount, zengsong: gift, paymentMethod: payMethod,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${resp['code']}' == '200') {
        toast(context, '充值成功 ¥${Fmt.money(amount + gift)}');
        _load();
      } else {
        toast(context, '${resp['msg'] ?? '充值失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 扣款 ====================
  Future<void> _deduct() async {
    if (selected == null) return;
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final r = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('余额扣款'),
        content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('「${selected!['name'] ?? selected!['phone']}」当前余额 ¥${Fmt.money(selected!['amount'])}',
              style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
          const SizedBox(height: 14),
          TextField(controller: amountCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), autofocus: true,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(hintText: '扣款金额', prefixText: '¥ ')),
          const SizedBox(height: 12),
          TextField(controller: noteCtrl, decoration: const InputDecoration(hintText: '备注（选填）')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: PosTheme.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认扣款'),
          ),
        ],
      ),
    );
    if (r != true || !mounted) return;
    final amount = double.tryParse(amountCtrl.text) ?? 0;
    if (amount <= 0) {
      toast(context, '请输入正确的扣款金额', error: true);
      return;
    }
    loadingDialog(context, '扣款中…');
    try {
      final resp = await Api.vipDeduct(
        wenxunId: Session.wenxunId,
        vipId: int.tryParse('${selected!['id']}') ?? 0,
        kcamount: amount, beizhu: noteCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${resp['code']}' == '200') {
        toast(context, '扣款成功');
        _load();
      } else {
        toast(context, '${resp['msg'] ?? '扣款失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 最近消费 ====================
  Future<void> _showOrders() async {
    if (selected == null) return;
    loadingDialog(context, '查询中…');
    List orders = [];
    String? err;
    try {
      orders = await Api.vipOrders(int.tryParse('${selected!['id']}') ?? 0);
    } on ApiError catch (e) {
      err = e.message;
    }
    if (!mounted) return;
    Navigator.pop(context);
    showDialog(context: context, builder: (_) => AlertDialog(
      title: Text('最近消费 · ${selected!['name'] ?? selected!['phone']}'),
      content: SizedBox(width: 520, height: 380, child: err != null
          ? Center(child: Text(err, style: const TextStyle(color: PosTheme.red)))
          : orders.isEmpty
              ? const EmptyView('暂无消费记录')
              : ListView.separated(
                  itemCount: orders.length,
                  separatorBuilder: (_, __) => const Divider(color: PosTheme.line),
                  itemBuilder: (_, i) {
                    final o = orders[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${o['order_number'] ?? ''}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                      subtitle: Text('${Fmt.date(o['create_time'])} · ${o['payment_method'] ?? ''}', style: const TextStyle(fontSize: 12.5)),
                      trailing: Text('¥${Fmt.money(o['total'])}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                    );
                  },
                )),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader('会员管理', actions: [
        OutlinedButton.icon(
          onPressed: Session.vipadd ? _addVip : null,
          style: OutlinedButton.styleFrom(foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
          icon: const Icon(Icons.person_add_alt, size: 18),
          label: Text('添加会员', style: TextStyle(color: Session.vipadd ? PosTheme.accent : PosTheme.textHint)),
        ),
      ]),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 左：列表
            Expanded(
              flex: 5,
              child: AppCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Expanded(child: TextField(
                        onChanged: (v) => kw = v.trim(),
                        onSubmitted: (_) => _load(),
                        decoration: const InputDecoration(isDense: true, hintText: '手机号 / 姓名搜索后回车', prefixIcon: Icon(Icons.search, size: 20)),
                      )),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18)),
                        onPressed: _load,
                        child: const Text('搜索'),
                      ),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(children: [
                      Expanded(child: StatTile(label: '会员总数', value: '${list.length}', icon: Icons.groups, color: PosTheme.blue)),
                      const SizedBox(width: 10),
                      Expanded(child: StatTile(label: '余额合计', value: '¥${Fmt.money(_sumAmount())}', icon: Icons.account_balance_wallet_outlined, color: PosTheme.green)),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: loading
                        ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                        : list.isEmpty
                            ? const EmptyView('暂无会员')
                            : ListView.builder(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                itemCount: list.length,
                                itemBuilder: (_, i) {
                                  final v = list[i];
                                  final on = selected != null && '${selected!['id']}' == '${v['id']}';
                                  return InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    onTap: () => setState(() => selected = v),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: on ? const Color(0xFFFFF2ED) : Colors.transparent,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(children: [
                                        CircleAvatar(radius: 17, backgroundColor: (on ? PosTheme.accent : PosTheme.blue).withOpacity(0.14),
                                            child: Text(_avatarChar(v),
                                                style: TextStyle(fontSize: 14, color: on ? PosTheme.accent : PosTheme.blue, fontWeight: FontWeight.w600))),
                                        const SizedBox(width: 12),
                                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                          Text('${v['name'] ?? ''}', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                                          Text('${v['phone'] ?? ''}', style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
                                        ])),
                                        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                          Text('¥${Fmt.money(v['amount'])}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                                          Text('积分 ${v['score'] ?? 0}', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                                        ]),
                                      ]),
                                    ),
                                  );
                                },
                              ),
                  ),
                ]),
              ),
            ),
            const SizedBox(width: 16),
            // 右：详情
            Expanded(
              flex: 4,
              child: selected == null
                  ? const AppCard(child: EmptyView('选择会员查看详情'))
                  : _detailPanel(),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _detailPanel() {
    final v = selected!;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          CircleAvatar(radius: 26, backgroundColor: PosTheme.accent.withOpacity(0.12),
              child: const Icon(Icons.person, color: PosTheme.accent, size: 28)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${v['name'] ?? '未命名会员'}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('${v['phone'] ?? ''}　${v['chepai'] ?? ''}', style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
          ])),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: _kv('可用余额', '¥${Fmt.money(v['amount'])}', PosTheme.accent)),
          Expanded(child: _kv('赠送余额', '¥${Fmt.money(v['gift_balance'])}', PosTheme.green)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _kv('积分', '${v['score'] ?? 0}', PosTheme.blue)),
          Expanded(child: _kv('累计充值', '¥${Fmt.money(v['accumulation_recharge'])}', PosTheme.textMain)),
        ]),
        const Spacer(),
        BigButton('充值', onTap: _recharge, height: 50),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: BigButton('余额扣款', onTap: _deduct, color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 46)),
          const SizedBox(width: 10),
          Expanded(child: BigButton('消费记录', onTap: _showOrders, color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 46)),
        ]),
      ]),
    );
  }

  Widget _kv(String k, String v, Color c) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
        const SizedBox(height: 3),
        Text(v, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c)),
      ]),
    );
  }
}
