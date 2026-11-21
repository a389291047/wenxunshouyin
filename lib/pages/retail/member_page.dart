import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/touch_keyboard.dart';
import '../../ui/vip_avatar.dart';
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

  // 会员搜索触屏键盘（v3.3.231）：复用收银页 TouchKeyboard，点键盘图标展开/收起
  final searchCtrl = TextEditingController();
  bool kbOpen = false;

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
      if (list.isNotEmpty && selected == null) {
        selected = list.first;
        _loadRecords(); // 默认选中第一个会员时同步拉记录
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      toast(context, e.message, error: true);
    }
  }

  double _sumAmount() => list.fold(0, (s, v) => s + (double.tryParse('${v['amount']}') ?? 0));

  // ==================== 会员搜索触屏键盘（v3.3.231，复用收银页 TouchKeyboard） ====================
  /// 键盘写入：直接改 controller 并实时搜索（点键盘是离散点击，频率低，实时出结果）
  void _kbWrite(String text) {
    searchCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    kw = text.trim();
    _load();
  }

  void _kbInput(String ch) => _kbWrite(searchCtrl.text + ch);

  void _kbBackspace() {
    final t = searchCtrl.text;
    if (t.isEmpty) return;
    _kbWrite(t.substring(0, t.length - 1));
  }

  void _kbClear() => _kbWrite('');

  /// 键盘开合按钮（同收银页样式）
  Widget _kbBtn() {
    return SizedBox(
      width: 44, height: 44,
      child: Material(
        color: kbOpen ? PosTheme.accentLive : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: kbOpen ? Colors.transparent : PosTheme.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => kbOpen = !kbOpen),
          child: Icon(Icons.keyboard_alt_outlined,
              size: 22, color: kbOpen ? Colors.white : PosTheme.textSub),
        ),
      ),
    );
  }

  /// 头像字符/地址：v3.3.251 抽到 lib/ui/vip_avatar.dart 共用（收银页也显示微信头像）

  // ==================== 添加会员（触屏版，v3.3.231 改版） ====================
  /// v3.3.231：等级不再手选——自动取「10折」等级，没有则提示无法添加会员；
  /// 姓名移除（后端缺省用手机号）；提交走 v3.Vip/addVip
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

    // 自动匹配 10 折等级（discount=10）
    Map? lv10;
    for (final e in _levels) {
      if ((double.tryParse('${e['discount']}') ?? 0) == 10) { lv10 = e; break; }
    }
    if (lv10 == null) {
      toast(context, '无法添加会员：未找到10折会员等级，请先在会员等级设置里添加', error: true);
      return;
    }
    final lv10Id = int.tryParse('${lv10['id']}') ?? 0;
    final lv10Title = '${lv10['title'] ?? ''}';

    // 自定义过渡：遮罩 20% 黑 + 120ms 快速淡入。
    // 默认 showDialog 是黑 54% 淡入，低配收银机丢帧时会整屏黑一下
    final r = await showGeneralDialog<Map>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x33000000),
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (_, __, ___) => _AddVipDialog(lvId: lv10Id, lvTitle: lv10Title),
      transitionBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
        child: child,
      ),
    );
    if (r == null || !mounted) return;
    loadingDialog(context, '添加中…');
    try {
      final resp = await Api.vipAddV3(
        wenxunId: Session.wenxunId,
        phone: '${r['phone'] ?? ''}',
        amount: ('${r['amount'] ?? ''}'.trim().isEmpty) ? '0' : '${r['amount']}'.trim(),
        score: ('${r['score'] ?? ''}'.trim().isEmpty) ? '0' : '${r['score']}'.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context);
      final code = int.tryParse('${resp['code']}') ?? 0;
      final msg = '${resp['msg'] ?? ''}';
      if (code == 200) {
        // 显示后端文案：「添加会员成功」或「该手机号已是本店会员…」（不误导）
        toast(context, msg.isEmpty ? '添加成功' : msg);
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
  void dispose() {
    searchCtrl.dispose();
    super.dispose();
  }

  // ==================== 近期消费/充值记录（v3.3.250 会员详情右侧记录卡） ====================
  String recTab = '全部';
  List recConsume = [];
  List recRecharge = [];
  bool recLoading = false;

  Future<void> _loadRecords() async {
    final v = selected;
    if (v == null) return;
    final vid = int.tryParse('${v['id']}') ?? 0;
    if (vid <= 0) return;
    setState(() => recLoading = true);
    try {
      final r = await Api.vipRecentRecords(vipId: vid, wenxunId: Session.wenxunId);
      if (!mounted) return;
      setState(() {
        recConsume = r['consume']!;
        recRecharge = r['recharge']!;
        recLoading = false;
      });
    } catch (_) {
      // 接口未部署/网络异常：记录卡显示空态，不影响详情
      if (!mounted) return;
      setState(() => recLoading = false);
    }
  }

  void _select(Map v) {
    setState(() => selected = v);
    _loadRecords();
  }

  /// 按当前 tab 合并取最近 5 条（时间倒序）
  List<Map<String, dynamic>> _mergedRecords() {
    final items = <Map<String, dynamic>>[];
    if (recTab != '充值') {
      for (final o in recConsume) {
        final refunded = (int.tryParse('${o['refund_status']}') ?? 0) == 2 ||
            (double.tryParse('${o['refund_amount'] ?? 0}') ?? 0) > 0;
        items.add({
          'kind': '消费',
          'time': '${o['create_time'] ?? ''}',
          'amount': double.tryParse('${o['total']}') ?? 0,
          'sub': '${o['payment_method'] ?? ''}${refunded ? ' · 已退款' : ''}',
        });
      }
    }
    if (recTab != '消费') {
      for (final r in recRecharge) {
        final refunded = int.tryParse('${r['pay_status']}') == 2;
        final gift = double.tryParse('${r['zengsong'] ?? 0}') ?? 0;
        items.add({
          'kind': '充值',
          'time': '${r['pay_time'] ?? r['create_time'] ?? ''}',
          'amount': double.tryParse('${r['czamount']}') ?? 0,
          'sub': '${'${r['pay_type'] ?? ''}' == 'cash' ? '现金' : '扫码'}'
              '${gift > 0 ? ' · 送¥${Fmt.money(gift)}' : ''}'
              '${refunded ? ' · 已退款' : ''}',
        });
      }
    }
    items.sort((a, b) => '${b['time']}'.compareTo('${a['time']}'));
    return items.take(5).toList();
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
                        controller: searchCtrl,
                        onChanged: (v) => kw = v.trim(),
                        onSubmitted: (_) => _load(),
                        decoration: const InputDecoration(isDense: true, hintText: '手机号搜索后回车', prefixIcon: Icon(Icons.search, size: 20)),
                      )),
                      const SizedBox(width: 10),
                      _kbBtn(),
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
                                    onTap: () => _select(v),
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
                                        VipAvatar(avatarUrl: vipAvatarUrl(v), radius: 19, rounded: true, fallbackText: vipAvatarChar(v), highlight: on),
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
      // 搜索触屏键盘（v3.3.231）：展开时贴在页面底部
      if (kbOpen)
        TouchKeyboard(
          keyHeight: MediaQuery.of(context).size.height < 680 ? 34 : 40,
          hintText: searchCtrl.text.isEmpty
              ? '输入手机号后回车或点搜索'
              : '已输入「${searchCtrl.text}」· 匹配 ${list.length} 位会员',
          onInput: _kbInput,
          onBackspace: _kbBackspace,
          onClear: _kbClear,
          onClose: () => setState(() => kbOpen = false),
        ),
    ]);
  }

  Widget _detailPanel() {
    final v = selected!;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          VipAvatar(avatarUrl: vipAvatarUrl(v), radius: 28, rounded: true, fallbackText: vipAvatarChar(v), showRing: true),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${v['name'] ?? '未命名会员'}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            // v3.3.250：手机号粗体加大，收银员一眼核对
            Text('${v['phone'] ?? ''}${('${v['chepai'] ?? ''}'.trim().isNotEmpty) ? '　${v['chepai']}' : ''}',
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
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
        const SizedBox(height: 14),
        // v3.3.250：右侧空白区改为近期记录卡（全部/消费/充值 切换，最近5条）
        Expanded(child: _recordsCard()),
        const SizedBox(height: 12),
        BigButton('充值', onTap: _recharge, height: 50),
      ]),
    );
  }

  /// 近期记录卡（v3.3.250）：全部/消费/充值 三个切换卡边 + 最近5条
  /// v3.3.251：每条固定高度（按 5 条平分区域算出），2条/1条不撑满；
  /// 类型「消费/充值」前置为圆角胶囊标签
  Widget _recordsCard() {
    const tabs = ['全部', '消费', '充值'];
    final rows = _mergedRecords();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosTheme.line.withOpacity(0.6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Text('最近记录', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
          const Spacer(),
          for (final t in tabs) ...[
            const SizedBox(width: 6),
            _recChip(t),
          ],
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: recLoading
              ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: PosTheme.accent)))
              : rows.isEmpty
                  ? const Center(child: Text('暂无记录', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)))
                  // 固定卡高 = 区域高度按 5 条平分（含间距），条数少时同高不撑满，多于 5 条可滚动
                  : LayoutBuilder(builder: (ctx, box) {
                      final cardH = ((box.maxHeight - 4 * 8) / 5).clamp(56.0, 88.0);
                      return SingleChildScrollView(
                        child: Column(
                          children: [
                            for (int i = 0; i < rows.length; i++)
                              _recRow(rows[i], last: i == rows.length - 1, height: cardH),
                          ],
                        ),
                      );
                    }),
        ),
      ]),
    );
  }

  Widget _recChip(String t) {
    final on = recTab == t;
    return InkWell(
      onTap: () => setState(() => recTab = t),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Text(t, style: TextStyle(
            fontSize: 12.5,
            fontWeight: on ? FontWeight.w700 : FontWeight.w400,
            color: on ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  /// 单条记录卡片（v3.3.251）：前置圆角胶囊类型标签（充值/消费）+ 时间/说明 + 金额，
  /// Material+InkWell 触屏按压墨水纹；固定高度，不随条数撑满
  Widget _recRow(Map<String, dynamic> r, {bool last = false, required double height}) {
    final isCz = r['kind'] == '充值';
    final c = isCz ? PosTheme.green : PosTheme.accent;
    final t = '${r['time']}';
    final time = t.length >= 16 ? t.substring(0, 16) : (t.isEmpty ? '—' : t);
    final sub = '${r['sub']}'.trim();
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 8),
      child: SizedBox(
        height: height,
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {}, // 占位：保留触屏按压反馈
            splashColor: c.withOpacity(0.10),
            highlightColor: c.withOpacity(0.05),
            hoverColor: c.withOpacity(0.04),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: PosTheme.line.withOpacity(0.55)),
              ),
              child: Row(children: [
                // 前置类型胶囊标签（充值/消费）
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: c,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${r['kind']}',
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
                const SizedBox(width: 10),
                // 时间 + 说明
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(time, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                    if (sub.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: PosTheme.textHint)),
                      ),
                  ]),
                ),
                const SizedBox(width: 8),
                // 金额
                Text('${isCz ? '+' : '-'}¥${Fmt.money(r['amount'])}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: c)),
              ]),
            ),
          ),
        ),
      ),
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

// ==================== 添加会员弹窗（v3.3.231 改版二） ====================
/// - 键盘：无码商品弹窗同款纯数字键盘（1-9 / 清空 0 ⌫，无小数点），内置弹窗底部，无标题栏
/// - 移除姓名、会员等级选择（自动10折）、车牌、实体卡号；保留初始金额 / 初始积分
enum _VipField { phone, amount, score }

class _AddVipDialog extends StatefulWidget {
  final int lvId;      // 自动匹配到的 10 折等级 ID（仅展示用，提交由后端自动取）
  final String lvTitle;
  const _AddVipDialog({required this.lvId, required this.lvTitle});
  @override
  State<_AddVipDialog> createState() => _AddVipDialogState();
}

class _AddVipDialogState extends State<_AddVipDialog> {
  _VipField active = _VipField.phone; // 默认手机号，弹窗打开即输
  String phone = '', amount = '', score = '';
  String? err;

  // ---------- 数字键盘写入（只数字；无小数点） ----------
  void _key(String k) {
    setState(() {
      err = null;
      if (k == 'C') { _setActive(''); return; }
      if (k == 'B') {
        final cur = _activeVal();
        if (cur.isNotEmpty) _setActive(cur.substring(0, cur.length - 1));
        return;
      }
      switch (active) {
        case _VipField.phone:
          if (phone.length < 11) phone += k;
          break;
        case _VipField.amount:
          if (amount.length < 7) amount += k;
          break;
        case _VipField.score:
          if (score.length < 7) score += k;
          break;
      }
    });
  }

  String _activeVal() => switch (active) { _VipField.phone => phone, _VipField.amount => amount, _VipField.score => score };
  void _setActive(String v) => switch (active) { _VipField.phone => phone = v, _VipField.amount => amount = v, _VipField.score => score = v };

  // ---------- 触控数字框 ----------
  Widget _numBox(_VipField f, String label, String value, {String hint = ''}) {
    final on = active == f;
    return InkWell(
      onTap: () => setState(() { active = f; err = null; }),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFFF4EE) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line, width: on ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(label, style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: on ? PosTheme.accent : PosTheme.textSub)),
            const Spacer(),
            if (on) Container(width: 7, height: 7,
                decoration: BoxDecoration(color: PosTheme.accent, shape: BoxShape.circle)),
          ]),
          const SizedBox(height: 4),
          Text(value.isEmpty ? hint : value,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: value.isEmpty ? PosTheme.textHint : (on ? PosTheme.accent : PosTheme.textMain))),
        ]),
      ),
    );
  }

  /// 会员等级只读展示（自动 10 折，不可点）
  Widget _levelBox() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4EE),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosTheme.accent, width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('会员等级（自动）', style: TextStyle(
            fontSize: 12.5, fontWeight: FontWeight.w600, color: PosTheme.accent)),
        const SizedBox(height: 4),
        Text(widget.lvTitle.isEmpty ? '10折' : widget.lvTitle,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 22, fontWeight: FontWeight.w800, color: PosTheme.accent)),
      ]),
    );
  }

  Future<void> _save() async {
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) { setState(() => err = '请输入正确的11位手机号'); return; }
    Navigator.pop(context, {
      'phone': phone,
      'amount': amount.trim(),
      'score': score.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 640,
        padding: const EdgeInsets.all(26),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ---- 标题 ----
          Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [Color(0xFFFF8A4C), Color(0xFFFF5B2E)]),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.person_add_alt, size: 23, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
                Text('添加会员', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                SizedBox(height: 2),
                Text('等级自动10折 · 点输入块后用下方键盘输入', style: TextStyle(fontSize: 13, color: PosTheme.textHint)),
              ]),
            ),
            InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(20),
              child: const SizedBox(width: 40, height: 40, child: Icon(Icons.close, size: 24, color: PosTheme.textHint)),
            ),
          ]),
          const SizedBox(height: 18),
          // ---- 表单：手机号 + 等级 ----
          Row(children: [
            Expanded(child: _numBox(_VipField.phone, '手机号码 *', phone, hint: '点击后输入 11 位手机号')),
            const SizedBox(width: 14),
            Expanded(child: _levelBox()),
          ]),
          const SizedBox(height: 14),
          // ---- 表单：金额 + 积分 ----
          Row(children: [
            Expanded(child: _numBox(_VipField.amount, '初始金额 (¥)', amount, hint: '0')),
            const SizedBox(width: 14),
            Expanded(child: _numBox(_VipField.score, '初始积分', score, hint: '0')),
          ]),
          const SizedBox(height: 16),
          // ---- 无码弹窗同款数字键盘：1-9 / 清空 0 ⌫（无小数点，无标题栏） ----
          _keypad(),
          const SizedBox(height: 16),
          if (err != null) Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(err!, style: const TextStyle(fontSize: 13, color: PosTheme.red)),
          ),
          // ---- 底部按钮（仅保存） ----
          BigButton('保存', onTap: _save, height: 52),
        ]),
      ),
    );
  }

  /// 12 宫格：1-9 / 清空 0 ⌫（无码弹窗同款，无小数点）
  Widget _keypad() {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['C', '0', '⌫'],
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosTheme.line),
      ),
      child: Column(children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              for (int i = 0; i < row.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: _keyBtn(row[i])),
              ],
            ]),
          ),
      ]),
    );
  }

  Widget _keyBtn(String k) {
    final isClear = k == 'C';
    final isBack = k == '⌫';
    return InkWell(
      onTap: () => _key(k),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          color: isClear ? const Color(0xFFFFF0EF) : (isBack ? const Color(0xFFE9EBF0) : const Color(0xFFF7F8FA)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: (isClear || isBack) ? Colors.transparent : PosTheme.line.withOpacity(0.6)),
        ),
        child: Center(
          child: isClear
              ? const Text('清空', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.red))
              : Text(k, style: TextStyle(
                    fontSize: isBack ? 20 : 22,
                    fontWeight: FontWeight.w700,
                    color: isBack ? PosTheme.textMain : PosTheme.textMain)),
        ),
      ),
    );
  }
}
