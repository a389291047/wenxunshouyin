import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/cloud_printer.dart';
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

  // 分页加载（v3.3.276b）：每页 10 条，底部分页按钮手动翻页（同餐饮堂食订单），减轻服务器压力
  int page = 1;
  int totalPages = 1;
  Map? summary; // 聚合统计 {count, total_amount}（后端 SQL 聚合，分页后总数/合计仍准确）

  // 会员搜索触屏键盘（v3.3.231）：复用收银页 TouchKeyboard，点键盘图标展开/收起
  final searchCtrl = TextEditingController();
  bool kbOpen = false;
  bool statsRevealed = false; // 统计卡默认隐藏数值，点击卡片才显示（再点隐藏）

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

  /// 拉取指定页（v3.3.276b 手动分页）：goto=0 用当前页，搜索时传 1 回到第一页
  Future<void> _load({int goto = 0}) async {
    setState(() => loading = true);
    try {
      // 搜索词去空格（v3.3.276b）：列表手机号分组显示（182 0019 2012），照显示输入也能搜到
      final k = kw.replaceAll(RegExp(r'\s+'), '');
      final p = goto > 0 ? goto : page;
      final r = await Api.vipPage(
        wenxunId: Session.wenxunId,
        page: p,
        limit: 10,
        kw: k,
      );
      if (!mounted) return;
      final l = (r['list'] ?? []) as List;
      final cnt = int.tryParse('${(r['summary'] ?? {})['count']}') ?? 0;
      setState(() {
        page = p;
        totalPages = cnt <= 0 ? 1 : (cnt + 9) ~/ 10;
        summary = r['summary'];
        list = l;
        loading = false;
      });
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

  /// 余额合计：用后端聚合值（分页后前端只有部分数据，本地 fold 会偏小）
  double _sumAmount() {
    final v = double.tryParse('${summary?['total_amount'] ?? ''}');
    return v ?? list.fold(0, (s, v) => s + (double.tryParse('${v['amount']}') ?? 0));
  }

  /// 总积分：同余额合计，优先后端聚合值（分页后本地 fold 会偏小）
  num _sumScore() {
    final v = num.tryParse('${summary?['total_score'] ?? ''}');
    return v ?? list.fold<num>(0, (s, v) => s + (num.tryParse('${v['score']}') ?? 0));
  }

  // ==================== 会员搜索触屏键盘（v3.3.231，复用收银页 TouchKeyboard） ====================
  /// 键盘写入：直接改 controller 并实时搜索（点键盘是离散点击，频率低，实时出结果）
  void _kbWrite(String text) {
    searchCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    kw = text.trim();
    _load(goto: 1); // 搜索词变化回到第一页
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
          'order': o, // v3.3.279：保留完整订单，点击弹窗看商品明细 + 补打小票
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
                      Expanded(child: PosField(
                        controller: searchCtrl,
                        compact: true,
                        cleanScan: true, // 支持扫码枪扫会员卡号/手机号
                        hint: '搜索手机号',
                        icon: Icons.search,
                        onChanged: (v) => kw = v.trim(),
                        onSubmitted: (_) => _load(goto: 1),
                      )),
                      const SizedBox(width: 10),
                      _kbBtn(),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18)),
                        onPressed: () => _load(goto: 1),
                        child: const Text('搜索'),
                      ),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: Row(children: [
                      // v3.3.282：统计数值默认隐藏（****），点击卡片切换显示/隐藏
                      Expanded(child: _statCard('总会员', statsRevealed ? '${summary?['count'] ?? list.length}' : '****', Icons.groups, PosTheme.blue)),
                      const SizedBox(width: 10),
                      Expanded(child: _statCard('总余额', statsRevealed ? '¥${Fmt.money(_sumAmount())}' : '¥****', Icons.account_balance_wallet_outlined, PosTheme.green)),
                      const SizedBox(width: 10),
                      Expanded(child: _statCard('总积分', statsRevealed ? '${_sumScore()}' : '****', Icons.stars_outlined, PosTheme.amber)),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: loading
                        ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                        : list.isEmpty
                            ? const EmptyView('暂无会员')
                            : Column(children: [
                                // 表头（v3.3.276b）：与订单页表头同款样式
                                _listHeader(),
                                Expanded(
                                  child: ListView.builder(
                                      padding: const EdgeInsets.fromLTRB(10, 2, 10, 12),
                                      itemCount: list.length,
                                      itemBuilder: (_, i) {
                                        final v = list[i];
                                        final on = selected != null && '${selected!['id']}' == '${v['id']}';
                                        // 卡片式行（v3.3.120）：固定圆角头像 + 姓名/昵称 + 手机号 + 余额
                                        // v3.3.276b：与订单页表头对齐——姓名居左省略、手机号居中分组美化、余额居中
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
                                              // 姓名(xm)/昵称：居左，超出省略号
                                              Expanded(
                                                child: Text(
                                                  _vipDisplay(v),
                                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              // 手机号：垂直居中 + 3-4-4 分组美化（182 0019 2012）
                                              Expanded(
                                                child: Text(
                                                  _fmtPhone('${v['phone'] ?? ''}'),
                                                  maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                                                  style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, letterSpacing: 0.3),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              // 可用余额：居中
                                              Expanded(
                                                child: Text(
                                                  '¥${Fmt.money(v['amount'])}',
                                                  maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
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
                  // 底部分页栏（v3.3.276b，同餐饮堂食订单样式）：手动点击翻页
                  if (!loading && list.isNotEmpty && totalPages > 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        IconButton.outlined(
                            onPressed: page > 1 ? () => _load(goto: page - 1) : null,
                            icon: const Icon(Icons.chevron_left, size: 20)),
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text('$page / $totalPages 页',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                        IconButton.outlined(
                            onPressed: page < totalPages ? () => _load(goto: page + 1) : null,
                            icon: const Icon(Icons.chevron_right, size: 20)),
                      ]),
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

  /// 显示名（v3.3.276b）：会员姓名(xm)在前，微信昵称在后；xm 为空只显示昵称
  String _vipDisplay(Map v) {
    final xm = '${v['xm'] ?? ''}'.trim();
    final nm = '${v['name'] ?? ''}'.trim();
    if (xm.isEmpty) return nm.isEmpty ? '未命名会员' : nm;
    return nm.isEmpty ? xm : '$xm　$nm';
  }

  /// 表头（v3.3.276b）：样式与订单页表头一致（灰底圆角卡 + 细字）
  /// 列对齐行布局：头像占位 + 姓名/昵称居左 + 手机号居中 + 可用余额居中
  Widget _listHeader() {
    const segStyle = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textSub);
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosTheme.line.withOpacity(0.7)),
      ),
      child: const Row(children: [
        SizedBox(width: 50), // 头像列占位（38 + 间距 12）
        Expanded(child: Text('姓名/昵称', style: segStyle)),
        Expanded(child: Text('手机号', textAlign: TextAlign.center, style: segStyle)),
        Expanded(child: Text('可用余额', textAlign: TextAlign.center, style: segStyle)),
      ]),
    );
  }

  /// 手机号分组美化（v3.3.276b）：11 位 → 182 0019 2012（3-4-4 空格分组）
  String _fmtPhone(String p) {
    final d = p.trim();
    if (d.length == 11 && RegExp(r'^\d{11}$').hasMatch(d)) {
      return '${d.substring(0, 3)} ${d.substring(3, 7)} ${d.substring(7)}';
    }
    return d;
  }

  Widget _detailPanel() {
    final v = selected!;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          VipAvatar(avatarUrl: vipAvatarUrl(v), radius: 28, rounded: true, fallbackText: vipAvatarChar(v), showRing: true),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // v3.3.276b：会员姓名(xm)显示在微信昵称前面
            Text(_vipDisplay(v), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
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
        // v3.3.261：注册时间（接口 /shouyin/vip/mac 返回整表 select，自带 create_time）
        Builder(builder: (_) {
          final ct = '${v['create_time'] ?? ''}'.trim();
          // 'YYYY-MM-DD HH:II:SS' 截到分钟；兼容时间戳秒
          String reg = ct;
          final ts = int.tryParse(ct);
          if (ts != null && ts > 0) {
            final d = DateTime.fromMillisecondsSinceEpoch(ts * (ct.length >= 13 ? 1 : 1000));
            reg = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
                '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
          } else if (reg.length > 16) {
            reg = reg.substring(0, 16);
          }
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(children: [
              Expanded(child: _kv('注册时间', reg.isEmpty ? '—' : reg, const Color(0xFF0891B2))),
            ]),
          );
        }),
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

  /// 消费明细弹窗（v3.3.279）：点击最近消费记录 → 商品清单 + 补打小票
  Future<void> _showConsumeDetail(Map<String, dynamic> o) async {
    final goods = CloudPrinter.parseGoods(o);
    String gName(Map g) => '${g['title'] ?? g['name'] ?? g['goods_name'] ?? ''}';
    double gPrice(Map g) => double.tryParse('${g['price'] ?? g['unit_price'] ?? 0}') ?? 0;
    double gQty(Map g) => double.tryParse('${g['quantity'] ?? g['num'] ?? 1}') ?? 1;
    double f(String k) => double.tryParse('${o[k] ?? 0}') ?? 0;
    final t = '${o['create_time'] ?? ''}';
    final time = t.length >= 16 ? t.substring(0, 16) : t;

    await showDialog(
      context: context,
      barrierDismissible: false, // 含补打等动作，防误点空白关闭
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
        contentPadding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
        actionsPadding: const EdgeInsets.fromLTRB(22, 4, 22, 14),
        title: Row(children: [
          const Text('消费明细', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (f('refund_amount') > 0 || (int.tryParse('${o['refund_status']}') ?? 0) == 2)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: PosTheme.blue.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
              child: const Text('已退款', style: TextStyle(fontSize: 11.5, color: PosTheme.blue, fontWeight: FontWeight.w700)),
            ),
        ]),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 单号/时间/支付方式
            Text('单号 ${o['order_number'] ?? ''}',
                style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
            const SizedBox(height: 3),
            Text('$time · ${o['payment_method'] ?? ''}',
                style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
            const Divider(height: 18),
            // 商品清单
            if (goods.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('暂无商品明细', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: PosTheme.textHint)),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final g in goods)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(child: Text(gName(g), maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                          const SizedBox(width: 10),
                          Text(gQty(g) == gQty(g).roundToDouble()
                              ? 'x${gQty(g).round()}'
                              : '${gQty(g).toStringAsFixed(3)}',
                              style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                          const SizedBox(width: 10),
                          SizedBox(width: 64,
                              child: Text('¥${Fmt.money(gPrice(g) * gQty(g))}', textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
                        ]),
                      ),
                  ]),
                ),
              ),
            const Divider(height: 18),
            // 金额行
            if (f('preferential_amount') > 0)
              _detailMoneyRow('优惠', -f('preferential_amount')),
            if (f('refund_amount') > 0) _detailMoneyRow('退款', -f('refund_amount')),
            _detailMoneyRow('实付', double.tryParse('${o['total']}') ?? 0, bold: true),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: PosTheme.accent, foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11)),
            icon: const Icon(Icons.print_outlined, size: 17),
            label: const Text('补打小票', style: TextStyle(fontWeight: FontWeight.w700)),
            onPressed: () async {
              loadingDialog(ctx, '发送云打印…');
              try {
                await CloudPrinter.printManual(CloudPrinter.orderTicket(o));
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) toast(context, '云打印已发送');
              } on ApiError catch (e) {
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) toast(context, e.message, error: true);
              } catch (e) {
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) toast(context, '打印失败：$e', error: true);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _detailMoneyRow(String label, double v, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Text(label, style: TextStyle(fontSize: 13, color: PosTheme.textSub, fontWeight: bold ? FontWeight.w800 : FontWeight.w400)),
        const Spacer(),
        Text('¥${Fmt.money(v)}',
            style: TextStyle(fontSize: bold ? 15.5 : 13.5,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                color: v < 0 ? PosTheme.blue : PosTheme.accent)),
      ]),
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
            onTap: () {
              // v3.3.279：消费记录点击弹窗（商品明细 + 补打小票）；充值记录保留按压反馈
              if (r['kind'] == '消费' && r['order'] != null) {
                _showConsumeDetail(Map<String, dynamic>.from(r['order'] as Map));
              }
            },
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
  /// v3.3.282：点击卡片切换数值显示/隐藏（默认 ****）
  Widget _statCard(String k, String v, IconData icon, Color c) {
    return GestureDetector(
      onTap: () => setState(() => statsRevealed = !statsRevealed),
      child: Container(
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
      ),
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
