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

  /// 会员等级缓存：进页面就预取（v3.3.216）。
  /// 之前是点「添加会员」弹窗打开后才请求，弹窗里转圈再突然变大，
  /// 在 Windows 上表现为遮罩丢帧 → 黑屏一闪；预取后弹窗一次成型。
  List _levels = [];
  bool _levelsLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadLevels();
  }

  Future<void> _loadLevels() async {
    if (_levelsLoading) return;
    _levelsLoading = true;
    try {
      final r = await Api.vipLevels(Session.wenxunId);
      if (!mounted) return;
      _levels = r;
    } catch (_) {
      // 静默失败：打开弹窗时再重试并提示
    }
    _levelsLoading = false;
    if (mounted) setState(() {});
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

  // ==================== 添加会员（触屏版，v3.3.216） ====================
  Future<void> _addVip() async {
    if (!Session.vipadd) {
      toast(context, '当前账号没有添加会员权限', error: true);
      return;
    }
    // 等级没缓存就先取一次（正常情况下进页面已预取好，弹窗即开即用）
    if (_levels.isEmpty && !_levelsLoading) await _loadLevels();
    if (_levels.isEmpty) {
      toast(context, '会员等级加载失败，请检查网络后重试', error: true);
      return;
    }

    // 自定义过渡：遮罩 20% 黑 + 120ms 快速淡入。
    // 默认 showDialog 是黑 54% 淡入，低配收银机丢帧时会整屏黑一下
    final r = await showGeneralDialog<Map>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x33000000),
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (_, __, ___) => _AddVipDialog(levels: _levels),
      transitionBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
        child: child,
      ),
    );
    if (r == null || !mounted) return;
    loadingDialog(context, '添加中…');
    try {
      final resp = await Api.vipAdd(
        wenxunId: Session.wenxunId,
        phone: '${r['phone'] ?? ''}',
        name: '${r['name'] ?? ''}',
        lvId: int.tryParse('${r['lvId']}') ?? 0,
        levelName: '${r['lvTitle'] ?? ''}',
        amount: ('${r['amount'] ?? ''}'.trim().isEmpty) ? '0' : '${r['amount']}'.trim(),
        score: ('${r['score'] ?? ''}'.trim().isEmpty) ? '0' : '${r['score']}'.trim(),
        shika: '${r['shika'] ?? ''}',
        chepai: '${r['chepai'] ?? ''}',
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

// ==================== 添加会员弹窗（触屏版 v3.3.216） ====================
/// - 手机号/初始金额/初始积分/实体卡号：点击选中后用右侧 12 宫格数字键盘录入，不调系统键盘
/// - 会员姓名/会员车牌：中文输入保留系统键盘 TextField
/// - 会员等级：大触点弹出菜单选择
enum _VipField { phone, amount, score, card }

class _AddVipDialog extends StatefulWidget {
  final List levels; // 进弹窗前已预取好，弹窗固定尺寸一次成型（避免黑屏一闪）
  const _AddVipDialog({required this.levels});
  @override
  State<_AddVipDialog> createState() => _AddVipDialogState();
}

class _AddVipDialogState extends State<_AddVipDialog> {
  final nameCtrl = TextEditingController();
  final chepaiCtrl = TextEditingController();
  _VipField active = _VipField.phone;
  String phone = '', amount = '', score = '', card = '';
  int? lvId;
  String lvTitle = '';
  bool more = false;
  String? err;

  // ---------- 数字键盘 ----------
  void _key(String k) {
    setState(() {
      err = null;
      if (k == 'C') {
        _setActive('');
        return;
      }
      if (k == 'B') {
        final cur = _activeVal();
        if (cur.isNotEmpty) _setActive(cur.substring(0, cur.length - 1));
        return;
      }
      if (k == '.') {
        if (active != _VipField.amount) return;
        if (amount.isEmpty) { amount = '0.'; return; }
        if (!amount.contains('.')) amount = '$amount.';
        return;
      }
      switch (active) {
        case _VipField.phone:
          if (phone.length < 11) phone += k;
          break;
        case _VipField.amount:
          final dot = amount.indexOf('.');
          if (dot == -1) {
            if (amount.length < 7) amount += k;
          } else if (amount.length - dot - 1 < 2) {
            amount += k;
          }
          break;
        case _VipField.score:
          if (score.length < 7) score += k;
          break;
        case _VipField.card:
          if (card.length < 18) card += k;
          break;
      }
    });
  }

  String _activeVal() => switch (active) { _VipField.phone => phone, _VipField.amount => amount, _VipField.score => score, _VipField.card => card };
  void _setActive(String v) => switch (active) { _VipField.phone => phone = v, _VipField.amount => amount = v, _VipField.score => score = v, _VipField.card => card = v };

  // ---------- 触控数字框 ----------
  Widget _numBox(_VipField f, String label, String value, {String hint = ''}) {
    final on = active == f;
    return InkWell(
      onTap: () => setState(() { active = f; err = null; }),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFFF4EE) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line, width: on ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: on ? PosTheme.accent : PosTheme.textSub)),
          const SizedBox(height: 3),
          Text(value.isEmpty ? hint : value,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                  color: value.isEmpty ? PosTheme.textHint : (on ? PosTheme.accent : PosTheme.textMain))),
        ]),
      ),
    );
  }

  Future<void> _save() async {
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) { setState(() => err = '请输入正确的手机号码'); return; }
    if (nameCtrl.text.trim().isEmpty) { setState(() => err = '请输入会员姓名'); return; }
    if (lvId == null) { setState(() => err = '请选择会员等级'); return; }
    Navigator.pop(context, {
      'phone': phone,
      'name': nameCtrl.text.trim(),
      'lvId': lvId,
      'lvTitle': lvTitle,
      'amount': amount.trim(),
      'score': score.trim(),
      'shika': card.trim(),
      'chepai': chepaiCtrl.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: 760,
        height: 520,
        padding: const EdgeInsets.all(22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ---- 标题 ----
          Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [Color(0xFFFF8A4C), Color(0xFFFF5B2E)]),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.person_add_alt, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
                Text('添加会员', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                SizedBox(height: 1),
                Text('手机号 / 金额 / 积分 / 卡号 点一下再用右侧键盘输入',
                    style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              ]),
            ),
            InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(18),
              child: const SizedBox(width: 36, height: 36, child: Icon(Icons.close, size: 22, color: PosTheme.textHint)),
            ),
          ]),
          const SizedBox(height: 14),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // ---- 左：表单 ----
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(right: 4, bottom: 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(child: _numBox(_VipField.phone, '手机号码 *', phone, hint: '点击后输入 11 位手机号')),
                      const SizedBox(width: 12),
                      Expanded(child: _levelSelector()),
                    ]),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      maxLength: 10,
                      onChanged: (_) { if (err != null) setState(() => err = null); },
                      decoration: const InputDecoration(
                        labelText: '会员姓名 *', hintText: '请输入会员姓名', counterText: '',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: _numBox(_VipField.amount, '初始金额 (¥)', amount, hint: '0.00')),
                      const SizedBox(width: 12),
                      Expanded(child: _numBox(_VipField.score, '初始积分', score, hint: '0')),
                    ]),
                    const SizedBox(height: 4),
                    InkWell(
                      onTap: () => setState(() => more = !more),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(more ? '收起附加信息 ∧' : '更多信息（实体卡号 / 车牌） ∨',
                            style: const TextStyle(fontSize: 13, color: PosTheme.accent, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    if (more) ...[
                      Row(children: [
                        Expanded(child: _numBox(_VipField.card, '实体卡号', card, hint: '点击后输入')),
                        const SizedBox(width: 12),
                        Expanded(child: TextField(
                          controller: chepaiCtrl,
                          maxLength: 8,
                          decoration: const InputDecoration(
                            labelText: '会员车牌', hintText: '如 粤A12345', counterText: '',
                          ),
                        )),
                      ]),
                    ],
                  ]),
                ),
              ),
              const SizedBox(width: 16),
              // ---- 右：数字键盘 ----
              SizedBox(width: 252, child: _keypad()),
            ]),
          ),
          if (err != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(err!, style: const TextStyle(fontSize: 12.5, color: PosTheme.red)),
          ),
          const SizedBox(height: 10),
          // ---- 底部按钮 ----
          Row(children: [
            SizedBox(
              width: 120, height: 52,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                    foregroundColor: PosTheme.textSub, side: const BorderSide(color: PosTheme.line)),
                child: const Text('取消', style: TextStyle(fontSize: 15.5)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: BigButton('保存', onTap: _save, height: 52)),
          ]),
        ]),
      ),
    );
  }

  // 会员等级：大触点选择框 + 弹出菜单
  Widget _levelSelector() {
    final on = lvId != null;
    return PopupMenuButton<int>(
      initialValue: lvId,
      offset: const Offset(0, 8),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (_) => widget.levels.map((lv) => PopupMenuItem<int>(
        value: int.tryParse('${lv['id']}'),
        height: 52,
        child: Text('${lv['title'] ?? ''}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      )).toList(),
      onSelected: (v) => setState(() {
        lvId = v;
        err = null;
        final hit = widget.levels.where((e) => int.tryParse('${e['id']}') == v).toList();
        lvTitle = hit.isNotEmpty ? '${hit.first['title'] ?? ''}' : '';
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFFF4EE) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line, width: on ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('会员等级 *', style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600,
              color: on ? PosTheme.accent : PosTheme.textSub)),
          const SizedBox(height: 3),
          Row(children: [
            Expanded(
              child: Text(lvTitle.isEmpty ? '点击选择等级' : lvTitle,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800,
                      color: lvTitle.isEmpty ? PosTheme.textHint : (on ? PosTheme.accent : PosTheme.textMain))),
            ),
            const Icon(Icons.expand_more, size: 20, color: PosTheme.textHint),
          ]),
        ]),
      ),
    );
  }

  // 12 宫格触屏数字键盘：7 8 9 / 4 5 6 / 1 2 3 / . 0 ⌫ + 清空
  Widget _keypad() {
    Widget key(String label, VoidCallback? onTap, {Color? color}) {
      final dis = onTap == null;
      return Expanded(
        child: Material(
          color: dis ? const Color(0xFFF2F3F7) : (color ?? Colors.white),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            splashColor: PosTheme.accent.withOpacity(0.12),
            highlightColor: PosTheme.accent.withOpacity(0.06),
            child: Container(
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: dis ? Colors.transparent : PosTheme.line),
              ),
              child: Text(label, style: TextStyle(
                  fontSize: label.length > 1 ? 13.5 : 20,
                  fontWeight: FontWeight.w700,
                  color: dis ? PosTheme.textHint : (label == '清空' ? PosTheme.red : PosTheme.textMain))),
            ),
          ),
        ),
      );
    }

    final dotOn = active == _VipField.amount;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosTheme.line),
      ),
      child: Column(children: [
        Row(children: [
          Text('数字键盘', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: PosTheme.textHint)),
          const Spacer(),
          Text(switch (active) {
            _VipField.phone => '手机号码',
            _VipField.amount => '初始金额',
            _VipField.score => '初始积分',
            _VipField.card => '实体卡号',
          }, style: const TextStyle(fontSize: 11.5, color: PosTheme.accent, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        for (var row in [['7', '8', '9'], ['4', '5', '6'], ['1', '2', '3']]) ...[
          Row(children: [for (final k in row) key(k, () => _key(k))]),
          const SizedBox(height: 6),
        ],
        Row(children: [
          key('.', dotOn ? () => _key('.') : null),
          key('0', () => _key('0')),
          key('⌫', () => _key('B')),
        ]),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity, height: 40,
          child: OutlinedButton.icon(
            onPressed: () => _key('C'),
            style: OutlinedButton.styleFrom(
                foregroundColor: PosTheme.red, side: BorderSide(color: PosTheme.red.withOpacity(0.35))),
            icon: const Icon(Icons.backspace_outlined, size: 16),
            label: const Text('清空该字段', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }
}
