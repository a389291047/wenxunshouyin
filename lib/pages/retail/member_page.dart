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

  /// 会员头像地址：微信头像（wx_vip.avatar），空/相对路径归一化
  String _avatarUrl(Map v) {
    final raw = '${v['avatar'] ?? ''}'.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http')) return raw;
    return Api.base + (raw.startsWith('/') ? '' : '/') + raw;
  }

  // ==================== 添加会员（与微信小程序 pages/vip/add 一致） ====================
  Future<void> _addVip() async {
    if (!Session.vipadd) {
      toast(context, '当前账号没有添加会员权限', error: true);
      return;
    }
    final phoneCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final scoreCtrl = TextEditingController();
    final shikaCtrl = TextEditingController();
    final chepaiCtrl = TextEditingController();
    int? lvId;                  // 选中的会员等级 id（用 id 匹配，避免 Map 实例不一致）
    String lvTitle = '';        // 选中的等级名称
    bool more = false;          // 附加信息（实体卡号/车牌）展开
    final levelsFuture = Api.vipLevels(Session.wenxunId); // 只创建一次，避免每次 setState 重新请求

    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('添加会员'),
        content: SizedBox(
          width: 420,
          child: FutureBuilder<List>(
            future: levelsFuture,
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 44),
                  child: Center(child: CircularProgressIndicator(color: PosTheme.accent)),
                );
              }
              if (snap.hasError) {
                return Text('会员等级加载失败：${snap.error}', style: const TextStyle(color: PosTheme.red, fontSize: 13));
              }
              final levels = snap.data ?? [];
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(controller: phoneCtrl, keyboardType: TextInputType.phone, maxLength: 11,
                    decoration: const InputDecoration(labelText: '手机号码 *', hintText: '请输入手机号码', counterText: '')),
                const SizedBox(height: 12),
                TextField(controller: nameCtrl, maxLength: 10,
                    decoration: const InputDecoration(labelText: '会员姓名 *', hintText: '请输入会员姓名', counterText: '')),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  value: lvId,
                  isDense: true,
                  decoration: const InputDecoration(labelText: '会员等级 *', hintText: '请选择会员等级'),
                  items: levels.map<DropdownMenuItem<int>>((lv) => DropdownMenuItem<int>(
                      value: int.tryParse('${lv['id']}'),
                      child: Text('${lv['title'] ?? ''}', style: const TextStyle(fontSize: 14)))).toList(),
                  onChanged: (v) => setD(() {
                    lvId = v;
                    final hit = levels.where((e) => int.tryParse('${e['id']}') == v).toList();
                    lvTitle = hit.isNotEmpty ? '${hit.first['title'] ?? ''}' : '';
                  }),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: amountCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: '初始金额', hintText: '0.00', prefixText: '¥ '))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: scoreCtrl, keyboardType: const TextInputType.numberWithOptions(),
                      decoration: const InputDecoration(labelText: '初始积分', hintText: '0'))),
                ]),
                const SizedBox(height: 6),
                InkWell(
                  onTap: () => setD(() => more = !more),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(more ? '收起附加信息 ∧' : '更多信息（实体卡号 / 车牌） ∨',
                        style: TextStyle(fontSize: 12.5, color: PosTheme.accent)),
                  ),
                ),
                if (more) ...[
                  TextField(controller: shikaCtrl, keyboardType: TextInputType.number, maxLength: 18,
                      decoration: const InputDecoration(labelText: '实体卡号', hintText: '请输入实体卡号', counterText: '')),
                  const SizedBox(height: 12),
                  TextField(controller: chepaiCtrl, maxLength: 8,
                      decoration: const InputDecoration(labelText: '会员车牌', hintText: '请输入会员车牌', counterText: '')),
                ],
              ]);
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
            onPressed: () {
              final phone = phoneCtrl.text.trim();
              final name = nameCtrl.text.trim();
              if (!RegExp(r'^1\d{10}$').hasMatch(phone)) { toast(context, '请输入正确的手机号码', error: true); return; }
              if (name.isEmpty) { toast(context, '请输入会员姓名', error: true); return; }
              if (lvId == null) { toast(context, '请选择会员等级', error: true); return; }
              Navigator.pop(ctx, true);
            },
            child: const Text('保存'),
          ),
        ],
      )),
    );
    if (r != true || !mounted) return;
    loadingDialog(context, '添加中…');
    try {
      final resp = await Api.vipAdd(
        wenxunId: Session.wenxunId,
        phone: phoneCtrl.text.trim(),
        name: nameCtrl.text.trim(),
        lvId: lvId ?? 0,
        levelName: lvTitle,
        amount: amountCtrl.text.trim().isEmpty ? '0' : amountCtrl.text.trim(),
        score: scoreCtrl.text.trim().isEmpty ? '0' : scoreCtrl.text.trim(),
        shika: shikaCtrl.text.trim(),
        chepai: chepaiCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context);
      final code = int.tryParse('${resp['code']}') ?? 0;
      final msg = '${resp['msg'] ?? ''}';
      if (code == 200) {
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

  // ==================== 充值（与微信小程序充值页一致：档次 + 扫付款码） ====================
  Future<void> _recharge() async {
    if (selected == null) return;
    final v = selected!;
    final codeCtrl = TextEditingController();
    Map? tier;            // 选中的充值档次 {id, amount, zengsong}
    bool submitting = false;
    final tiersFuture = Api.vipRechargeTiers(Session.wenxunId); // 只创建一次

    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text('会员充值 · ${v['name'] ?? v['phone']}'),
        content: SizedBox(
          width: 440,
          child: FutureBuilder<List>(
            future: tiersFuture,
            builder: (_, snap) {
              final tiers = snap.data ?? [];
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('当前余额 ¥${Fmt.money(v['amount'])}　赠送余额 ¥${Fmt.money(v['gift_balance'])}　积分 ${v['score'] ?? 0}',
                    style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                const SizedBox(height: 14),
                if (snap.connectionState != ConnectionState.done)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 28), child: Center(child: CircularProgressIndicator(color: PosTheme.accent)))
                else if (tiers.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 22),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
                    child: const Text('暂无充值活动，请联系店长配置充值档次', style: TextStyle(fontSize: 13, color: PosTheme.textHint)),
                  )
                else
                  Wrap(spacing: 10, runSpacing: 10, children: [
                    for (final t in tiers)
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => setD(() => tier = t as Map),
                        child: Container(
                          width: 128,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: '${tier?['id']}' == '${t['id']}' ? const Color(0xFFFFF2ED) : Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: '${tier?['id']}' == '${t['id']}' ? PosTheme.accent : PosTheme.line, width: '${tier?['id']}' == '${t['id']}' ? 1.5 : 1),
                          ),
                          child: Column(children: [
                            Text('¥${t['amount'] ?? 0}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                            const SizedBox(height: 2),
                            Text('送 ¥${t['zengsong'] ?? 0}', style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
                          ]),
                        ),
                      ),
                  ]),
                const SizedBox(height: 16),
                TextField(
                  controller: codeCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  maxLength: 30,
                  enabled: !submitting,
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                  decoration: const InputDecoration(
                    labelText: '顾客付款码',
                    hintText: '扫码枪扫描顾客付款码，或手动输入',
                    counterText: '',
                    prefixIcon: Icon(Icons.qr_code_scanner, size: 20),
                  ),
                ),
              ]);
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
            onPressed: () {
              if (tier == null) { toast(context, '请选择充值档次', error: true); return; }
              final code = codeCtrl.text.trim();
              if (!RegExp(r'^\d{18,30}$').hasMatch(code)) { toast(context, '请输入有效的付款码（18-30位数字）', error: true); return; }
              Navigator.pop(ctx, true);
            },
            child: const Text('确认充值'),
          ),
        ],
      )),
    );
    if (r != true || !mounted) return;
    final amount = double.tryParse('${tier?['amount'] ?? ''}') ?? 0;
    if (amount <= 0) {
      toast(context, '请选择充值档次', error: true);
      return;
    }
    loadingDialog(context, '等待顾客支付…');
    try {
      final resp = await Api.rechargeCodePay(
        wenxunId: Session.wenxunId,
        amount: amount,
        code: codeCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context);
      final outerCode = '${resp['code']}';
      final data = (resp['data'] ?? {}) as Map;
      final ok = outerCode == '0' && ('${data['code'] ?? ''}' == '000000' || data['success'] == true);
      if (ok) {
        toast(context, '充值成功 ¥${Fmt.money(amount)}（送 ¥${tier?['zengsong'] ?? 0}）');
        _load();
      } else {
        toast(context, '${data['msg'] ?? resp['message'] ?? '支付未完成，请确认'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 最近消费（仅最近 5 条） ====================
  Future<void> _showOrders() async {
    if (selected == null) return;
    loadingDialog(context, '查询中…');
    List orders = [];
    String? err;
    try {
      final all = await Api.vipOrders(int.tryParse('${selected!['id']}') ?? 0);
      orders = all.take(5).toList();
    } on ApiError catch (e) {
      err = e.message;
    }
    if (!mounted) return;
    Navigator.pop(context);
    showDialog(context: context, builder: (_) => AlertDialog(
      title: Text('最近消费 · ${selected!['name'] ?? selected!['phone']}（最近5条）'),
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
                                        _VipAvatar(avatarUrl: _avatarUrl(v), radius: 17, fallbackText: _avatarChar(v), highlight: on),
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
          _VipAvatar(avatarUrl: _avatarUrl(v), radius: 28, fallbackText: _avatarChar(v), showRing: true),
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
        BigButton('消费记录（最近5条）', onTap: _showOrders, color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 46),
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

// ==================== 会员头像（微信头像 → 默认头像图） ====================
/// 优先显示微信头像（wx_vip.avatar），加载中显示姓名首字占位，
/// 无头像 / 加载失败回退到 assets/avatar_default.png 默认头像图
class _VipAvatar extends StatefulWidget {
  final String avatarUrl;
  final double radius;
  final String fallbackText;
  final bool highlight; // 列表选中态：默认头像底色带主题色
  final bool showRing;  // 详情面板：外圈描边
  const _VipAvatar({
    required this.avatarUrl,
    required this.radius,
    required this.fallbackText,
    this.highlight = false,
    this.showRing = false,
  });
  @override
  State<_VipAvatar> createState() => _VipAvatarState();
}

class _VipAvatarState extends State<_VipAvatar> {
  bool failed = false;

  /// 默认头像图（圆裁 + 选中态淡主题描边）
  Widget _defaultAvatar() {
    final img = ClipOval(
      child: Image.asset('assets/avatar_default.png', fit: BoxFit.cover,
          width: widget.radius * 2, height: widget.radius * 2),
    );
    if (!widget.showRing) return img;
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: PosTheme.accent.withOpacity(0.35), width: 1.6),
      ),
      child: img,
    );
  }

  /// 姓名首字占位（加载中 / 微信头像为空前的兜底）
  Widget _charAvatar() {
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: (widget.highlight ? PosTheme.accent : PosTheme.blue).withOpacity(0.14),
      child: Text(
        widget.fallbackText,
        style: TextStyle(
          fontSize: widget.radius * 0.82,
          color: widget.highlight ? PosTheme.accent : PosTheme.blue,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.avatarUrl;
    if (url.isEmpty || failed) return _defaultAvatar();
    return ClipOval(
      child: SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : _charAvatar(),
          errorBuilder: (_, __, ___) {
            // 加载失败 → 下一帧切到默认头像图
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => failed = true);
            });
            return _defaultAvatar();
          },
        ),
      ),
    );
  }
}
