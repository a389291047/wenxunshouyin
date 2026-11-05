import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/vip_recharge.dart';
import '../../ui/widgets.dart';

/// 零售版 · 会员页：列表/查询/添加/充值（v3.3.120 消费记录入口已移除）
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

  // ==================== 充值（v3.3.118 换用完整版弹窗：现金充值需权限码 / 付款码免密） ====================
  Future<void> _recharge() async {
    if (selected == null) return;
    final r = await showVipRechargeDialog(context, vip: selected!);
    if (r == null || !mounted) return;
    toast(context, '充值成功 ¥${Fmt.money(r['amount'])}（送 ¥${Fmt.money(r['gift'])}）');
    _load();
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
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: Row(children: [
                      Expanded(child: _statCard('会员总数', '${list.length}', Icons.groups, PosTheme.blue)),
                      const SizedBox(width: 10),
                      Expanded(child: _statCard('余额合计', '¥${Fmt.money(_sumAmount())}', Icons.account_balance_wallet_outlined, PosTheme.green)),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: loading
                        ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                        : list.isEmpty
                            ? const EmptyView('暂无会员')
                            : ListView.builder(
                                padding: const EdgeInsets.fromLTRB(10, 2, 10, 12),
                                itemCount: list.length,
                                itemBuilder: (_, i) {
                                  final v = list[i];
                                  final on = selected != null && '${selected!['id']}' == '${v['id']}';
                                  // 卡片式行（v3.3.120）：固定圆角头像 + 昵称/手机号/金额三段平分
                                  return InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () => setState(() => selected = v),
                                    child: Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                                      decoration: BoxDecoration(
                                        gradient: on
                                            ? const LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [Color(0xFFFFF1E8), Color(0xFFFFF8F3)])
                                            : null,
                                        color: on ? null : Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: on ? PosTheme.accent.withOpacity(0.4) : PosTheme.line.withOpacity(0.7),
                                          width: on ? 1.4 : 1,
                                        ),
                                        boxShadow: on
                                            ? [BoxShadow(color: PosTheme.accent.withOpacity(0.10), blurRadius: 10, offset: const Offset(0, 3))]
                                            : null,
                                      ),
                                      child: Row(children: [
                                        _VipAvatar(avatarUrl: _avatarUrl(v), radius: 19, rounded: true, fallbackText: _avatarChar(v), highlight: on),
                                        const SizedBox(width: 12),
                                        // 昵称 / 手机号 / 金额 三段平分（超出省略号）
                                        Expanded(
                                          child: Text(
                                            '${v['name'] ?? ''}',
                                            maxLines: 1, overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            '${v['phone'] ?? ''}',
                                            maxLines: 1, overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 13, color: PosTheme.textSub),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            '¥${Fmt.money(v['amount'])}',
                                            maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right,
                                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.accent),
                                          ),
                                        ),
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
          _VipAvatar(avatarUrl: _avatarUrl(v), radius: 28, rounded: true, fallbackText: _avatarChar(v), showRing: true),
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
          const SizedBox(width: 12),
          Expanded(child: _kv('赠送余额', '¥${Fmt.money(v['gift_balance'])}', PosTheme.green)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _kv('积分', '${v['score'] ?? 0}', PosTheme.blue)),
          const SizedBox(width: 12),
          Expanded(child: _kv('累计充值', '¥${Fmt.money(v['accumulation_recharge'])}', const Color(0xFF7C3AED))),
        ]),
        const Spacer(),
        BigButton('充值', onTap: _recharge, height: 50),
      ]),
    );
  }

  /// 左侧统计卡（v3.3.120）：同色渐变底 + 浅描边 + 圆角图标块
  Widget _statCard(String k, String v, IconData icon, Color c) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.withOpacity(0.12), c.withOpacity(0.04)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withOpacity(0.18)),
      ),
      child: Row(children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [c, c.withOpacity(0.75)]),
            borderRadius: BorderRadius.circular(9),
            boxShadow: [BoxShadow(color: c.withOpacity(0.25), blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: const TextStyle(fontSize: 11.5, color: PosTheme.textSub)),
          const SizedBox(height: 2),
          Text(v, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: c)),
        ])),
      ]),
    );
  }

  /// 详情数据卡（v3.3.118）：按数值色渐变底 + 同色浅描边，卡片间留间隙
  Widget _kv(String k, String v, Color c) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.withOpacity(0.12), c.withOpacity(0.04)],
        ),
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
}

// ==================== 会员头像（微信头像 → 默认头像图） ====================
/// 优先显示微信头像（wx_vip.avatar），加载中显示姓名首字占位，
/// 无头像 / 加载失败回退到 assets/avatar_default.png 默认头像图
/// rounded=true 时为固定圆角方形（微信样式），否则圆形
class _VipAvatar extends StatefulWidget {
  final String avatarUrl;
  final double radius;
  final String fallbackText;
  final bool highlight; // 列表选中态：默认头像底色带主题色
  final bool showRing;  // 详情面板：外圈描边
  final bool rounded;   // 圆角方形（v3.3.120），false=圆形
  const _VipAvatar({
    required this.avatarUrl,
    required this.radius,
    required this.fallbackText,
    this.highlight = false,
    this.showRing = false,
    this.rounded = false,
  });
  @override
  State<_VipAvatar> createState() => _VipAvatarState();
}

class _VipAvatarState extends State<_VipAvatar> {
  bool failed = false;

  /// 圆角半径：圆角方形 = 边长 × 0.28（微信头像比例）
  double get _cornerRadius => widget.radius * 2 * 0.28;

  /// 按形状裁切
  Widget _clip(Widget child) {
    if (!widget.rounded) return ClipOval(child: child);
    return ClipRRect(
      borderRadius: BorderRadius.circular(_cornerRadius),
      child: child,
    );
  }

  /// 默认头像图（裁切 + 选中态淡主题描边）
  Widget _defaultAvatar() {
    final img = _clip(
      Image.asset('assets/avatar_default.png', fit: BoxFit.cover,
          width: widget.radius * 2, height: widget.radius * 2),
    );
    if (!widget.showRing) return img;
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: widget.rounded ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: widget.rounded ? BorderRadius.circular(_cornerRadius + 2.5) : null,
        border: Border.all(color: PosTheme.accent.withOpacity(0.35), width: 1.6),
      ),
      child: img,
    );
  }

  /// 姓名首字占位（加载中 / 微信头像为空前的兜底）
  Widget _charAvatar() {
    final box = Container(
      width: widget.radius * 2,
      height: widget.radius * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: (widget.highlight ? PosTheme.accent : PosTheme.blue).withOpacity(0.14),
        shape: widget.rounded ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: widget.rounded ? BorderRadius.circular(_cornerRadius) : null,
      ),
      child: Text(
        widget.fallbackText,
        style: TextStyle(
          fontSize: widget.radius * 0.82,
          color: widget.highlight ? PosTheme.accent : PosTheme.blue,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    return widget.rounded ? box : CircleAvatar(
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
    return _clip(
      SizedBox(
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
