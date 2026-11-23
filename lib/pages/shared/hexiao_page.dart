import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/elys.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';
import 'dart:async';

/// 核销管理（v3.3.262 左侧菜单「核销」）：零售 / 餐饮 / 生鲜三版通用
///
/// 平台切换：
///   小程序订单 —— 统一订单表 order_from=1：
///     未核销（status=20 待核销 / 配送中）· 已核销（40）· 退款（60/70）
///     操作：扫码枪/输入核销码核销（CAS 防重复）、退款审核（同意/拒绝，仅推进状态）
///   抖音团购 —— 抖音来客团购券（certificate prepare → verify → cancel）：
///     未核销档 = 扫码/输券码验券卡；已核销档 = 本地核销流水（1小时内可撤销）；退款档 = 已撤销记录
class HexiaoPage extends StatefulWidget {
  const HexiaoPage({super.key});
  @override
  State<HexiaoPage> createState() => _HexiaoPageState();
}

class _HexiaoPageState extends State<HexiaoPage> {
  int platform = 0; // 0 小程序订单 1 抖音团购 2 美团团购（无限聚核）
  int statusTab = 0; // 0 未核销 1 已核销 2 退款（美团档：0 核销工作台 1 核销记录）
  int dayTab = 0; // 0 今天 1 昨天 2 近7天
  List list = [];
  bool loading = true;
  String? error;
  Map? selected;
  String kw = '';
  Timer? _debounce;

  final TextEditingController scanCtrl = TextEditingController();
  final FocusNode scanFocus = FocusNode();

  // 抖音
  List dyShops = [];
  String dyPoi = '';
  String dyShopTip = '';
  final TextEditingController dyCodeCtrl = TextEditingController();
  final FocusNode dyCodeFocus = FocusNode();
  Map? dyPrepare; // {verify_token, certificates:[...]}
  bool dyBusy = false;

  // 美团（无限聚核，v3.3.271）
  Map mtCfg = {}; // {api_key_masked, shop_id, configured}
  final TextEditingController mtCodeCtrl = TextEditingController();
  final FocusNode mtCodeFocus = FocusNode();
  Map? mtPrepare; // parsePrepare 结果（含 ticketInfo 原文）
  Map? mtVerifyResult; // parseVerify 结果（credentials 撤销用）
  bool mtBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadShops();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    scanCtrl.dispose();
    scanFocus.dispose();
    dyCodeCtrl.dispose();
    dyCodeFocus.dispose();
    mtCodeCtrl.dispose();
    mtCodeFocus.dispose();
    super.dispose();
  }

  String get _dayStr => ['today', 'yesterday', 'week'][dayTab];
  String get _tabStr => ['undone', 'done', 'refund'][statusTab];
  String get _platformStr => platform == 0 ? 'mini' : 'douyin';

  Future<void> _load() async {
    // 美团购档：走无限聚核本地流水（/shouyin/elys/records），不走统一订单接口
    if (platform == 2) return _loadMt();
    setState(() { loading = true; error = null; });
    try {
      final r = await Api.hexiaoList(
        wenxunId: Session.wenxunId,
        platform: _platformStr,
        tab: _tabStr,
        day: _dayStr,
        kw: kw.trim(),
      );
      if (!mounted) return;
      setState(() {
        list = (r['list'] ?? []) as List;
        if (platform == 1 && '${r['tip'] ?? ''}'.isNotEmpty) dyShopTip = '${r['tip']}';
        loading = false;
        _ensureSelected();
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.message; list = []; });
    }
  }

  void _ensureSelected() {
    if (list.isEmpty) { selected = null; return; }
    final curId = selected == null ? -1 : int.tryParse('${selected!['id']}') ?? -1;
    final still = list.any((o) => (int.tryParse('${o['id']}') ?? -2) == curId);
    if (!still) selected = list.first;
  }

  // ==================== 美团（无限聚核） ====================

  Future<void> _loadMtCfg() async {
    try {
      final cfg = await Api.elysConfig(Session.wenxunId);
      if (!mounted) return;
      setState(() => mtCfg = cfg);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => mtCfg = {'configured': false, 'tip': e.message});
    }
  }

  Future<void> _loadMt() async {
    setState(() { loading = true; error = null; });
    try {
      final rows = await Api.elysRecords(wenxunId: Session.wenxunId, day: _dayStr);
      if (!mounted) return;
      setState(() {
        // 只显示已核销（status=1）；已撤销（status=2）不进列表
        list = rows.where((r) => int.tryParse('${r['status']}') == 1).toList();
        loading = false;
        _ensureSelected();
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.message; list = []; });
    }
  }

  /// 美团配置弹窗：API Key（留空=不修改）+ 门店 shopId
  Future<void> _showMtSettings() async {
    final keyCtrl = TextEditingController();
    final shopCtrl = TextEditingController(text: '${mtCfg['shop_id'] ?? ''}');
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('美团核销设置（无限聚核）', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('当前 Key：${mtCfg['api_key_masked'] ?? '未配置'}', style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
            const SizedBox(height: 10),
            PosField(
              controller: keyCtrl,
              cleanScan: true,
              obscureText: true,
              label: 'API Key',
              hint: '开发者中心获取；留空=保持不变',
              icon: Icons.key,
              compact: true,
            ),
            const SizedBox(height: 12),
            PosField(
              controller: shopCtrl,
              cleanScan: true,
              label: '门店 shopId',
              hint: '聚核系统门店 ID（具体门店，非商户号）',
              icon: Icons.store,
              compact: true,
            ),
            const SizedBox(height: 10),
            const Text('Key 仅保存在服务器，不会下发到收银机；配置后需在聚核完成美团门店授权。',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          BigButton('保存', onTap: () async {
            final shopId = shopCtrl.text.trim();
            if (shopId.isEmpty) {
              toast(dctx, '请填写门店 shopId', error: true);
              return;
            }
            try {
              await Api.elysSaveConfig(
                wenxunId: Session.wenxunId,
                shopId: shopId,
                apiKey: keyCtrl.text.trim(),
              );
              if (dctx.mounted) Navigator.pop(dctx, true);
            } on ApiError catch (e) {
              toast(dctx, e.message, error: true);
            }
          }, height: 44),
        ],
      ),
    );
    if (saved == true) {
      if (!mounted) return;
      toast(context, '已保存');
      await _loadMtCfg();
    }
  }

  /// 美团预核销（券码校验，只读）
  Future<void> _mtPrepare() async {
    final code = mtCodeCtrl.text.trim();
    if (code.isEmpty) {
      toast(context, '请扫描或输入美团券码', error: true);
      return;
    }
    if ('${mtCfg['configured'] ?? ''}' != 'true') {
      toast(context, '请先配置无限聚核 API Key 与门店 shopId', error: true);
      return;
    }
    setState(() => mtBusy = true);
    try {
      final data = await Api.elysPrepare(wenxunId: Session.wenxunId, code: code);
      if (!mounted) return;
      setState(() {
        mtPrepare = ElysLogic.parsePrepare(data);
        mtPrepare!['code'] = code;
        mtBusy = false;
        mtCodeCtrl.clear();
        mtCodeFocus.requestFocus();
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        mtBusy = false;
        mtPrepare = null;
        mtCodeCtrl.clear();
        mtCodeFocus.requestFocus();
      });
      toast(context, e.message, error: true);
    }
  }

  /// 美团核销（写操作）
  Future<void> _mtVerify() async {
    final p = mtPrepare;
    if (p == null) return;
    final ticketInfo = '${p['ticketInfo'] ?? ''}';
    if (ticketInfo.isEmpty) {
      toast(context, '核销凭证缺失，请重新验券', error: true);
      return;
    }
    final ok = await confirm(context, '确认核销',
        '${p['ticketName'] ?? '美团团购券'}\n实付 ¥${p['payAmountText'] ?? '0.00'}\n核销后券不可恢复（可凭凭证撤销）');
    if (!ok) return;
    setState(() => mtBusy = true);
    try {
      final resp = await Api.elysVerify(
        wenxunId: Session.wenxunId,
        code: '${p['code'] ?? ''}',
        ticketInfo: ticketInfo,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      final parsed = ElysLogic.parseVerify(resp);
      setState(() {
        mtBusy = false;
        mtPrepare = null;
        mtVerifyResult = parsed;
      });
      toast(context, '核销成功');
      _loadMt();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => mtBusy = false);
      toast(context, e.message, error: true);
    }
  }

  /// 美团撤销（写操作：后端按核销流水 id 取凭证）
  Future<void> _mtCancel(Map row) async {
    final ok = await confirm(context, '撤销核销',
        '${row['deal_title'] ?? row['ticket_name'] ?? ''}\n券码 ${row['code']}\n撤销后券回到待使用状态');
    if (!ok) return;
    try {
      await Api.elysCancel(
        wenxunId: Session.wenxunId,
        logId: int.tryParse('${row['id']}') ?? 0,
        platform: int.tryParse('${row['platform']}') ?? 1,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      toast(context, '撤销成功');
      _loadMt();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  void _switch(void Function() fn) {
    setState(fn);
    selected = null;
    _load();
  }

  Future<void> _loadShops() async {
    try {
      final shops = await Api.douyinShops(Session.wenxunId);
      if (!mounted) return;
      setState(() {
        dyShops = shops;
        dyShopTip = shops.isEmpty ? '尚未授权抖音门店：请在小程序「核销 → 抖音团购」完成门店授权' : '';
        if (dyPoi.isEmpty && shops.isNotEmpty) dyPoi = '${shops.first['poi_id'] ?? ''}';
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => dyShopTip = e.message);
    }
  }

  // ==================== 小程序：扫码核销 ====================

  Future<void> _scanVerify() async {
    final code = scanCtrl.text.trim();
    if (code.isEmpty) {
      toast(context, '请扫码或输入核销码', error: true);
      return;
    }
    try {
      final order = await Api.hexiaoCheck(wenxunId: Session.wenxunId, code: code);
      if (!mounted) return;
      // 弹确认卡（含商品摘要）
      final goods = (order['goods'] ?? []) as List;
      final gText = goods.take(3).map((g) => '${g['name']}×${g['quantity']}').join('、');
      final ok = await confirm(context, '确认核销',
          '订单 ${order['order_no']}\n${gText.isEmpty ? '' : '$gText\n'}合计 ¥${Fmt.money(order['total'])}\n核销后顾客即可取货');
      if (!ok) return;
      await Api.hexiaoVerifyMini(
        wenxunId: Session.wenxunId,
        id: int.tryParse('${order['id']}') ?? 0,
        code: code,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      toast(context, '核销成功');
      scanCtrl.clear();
      scanFocus.requestFocus();
      _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      // 核销码反查失败时清空，扫码枪连扫不卡输入框
      scanCtrl.clear();
      scanFocus.requestFocus();
      toast(context, e.message, error: true);
      _load();
    }
  }

  // ==================== 小程序：列表行核销 / 退款审核 ====================

  Future<void> _verifyRow(Map o) async {
    final ok = await confirm(context, '确认核销', '订单 ${o['order_no']}（¥${Fmt.money(o['total'])}）核销后顾客即可取货');
    if (!ok) return;
    try {
      await Api.hexiaoVerifyMini(
        wenxunId: Session.wenxunId,
        id: int.tryParse('${o['id']}') ?? 0,
        code: '${o['verify_code'] ?? ''}',
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      toast(context, '核销成功');
      _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  Future<void> _refundAudit(Map o, String action) async {
    final isAgree = action == 'agree';
    final ok = await confirm(context, isAgree ? '同意退款' : '拒绝退款',
        isAgree
            ? '订单 ${o['order_no']}（¥${Fmt.money(o['total'])}）同意后标记为已退款\n资金原路退回需在渠道后台确认'
            : '订单 ${o['order_no']} 拒绝后恢复为已完成');
    if (!ok) return;
    try {
      final msg = await Api.hexiaoRefundAudit(
        wenxunId: Session.wenxunId,
        id: int.tryParse('${o['id']}') ?? 0,
        action: action,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      toast(context, msg);
      _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  // ==================== 抖音：验券 / 核销 / 撤销 ====================

  Future<void> _dyPrepare() async {
    final raw = dyCodeCtrl.text.trim();
    if (raw.isEmpty) {
      toast(context, '请扫描或输入顾客券码', error: true);
      return;
    }
    if (dyPoi.isEmpty) {
      toast(context, '请先选择抖音门店', error: true);
      return;
    }
    setState(() => dyBusy = true);
    try {
      final r = await Api.douyinPrepare(wenxunId: Session.wenxunId, poiId: dyPoi, raw: raw);
      if (!mounted) return;
      setState(() {
        dyPrepare = r;
        dyBusy = false;
        dyCodeCtrl.clear();
        dyCodeFocus.requestFocus();
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        dyBusy = false;
        dyCodeCtrl.clear();
        dyCodeFocus.requestFocus();
      });
      toast(context, e.message, error: true);
    }
  }

  Future<void> _dyVerify() async {
    final p = dyPrepare;
    if (p == null) return;
    final certs = (p['certificates'] ?? []) as List;
    if (certs.isEmpty) return;
    // 默认核销第一张（一单多券时全部核销：抖音码同单必须一次请求核销）
    final codes = certs.map((c) => '${c['encrypted_code'] ?? ''}').where((s) => s.isNotEmpty).toList();
    if (codes.isEmpty) {
      toast(context, '券数据异常', error: true);
      return;
    }
    final first = certs.first;
    final ok = await confirm(context, '确认核销',
        '${first['sku_title'] ?? '抖音团购券'}\n¥${Fmt.money(first['pay_amount'])} × ${certs.length} 张\n核销后券不可恢复（1小时内可撤销）');
    if (!ok) return;
    setState(() => dyBusy = true);
    try {
      await Api.douyinVerify(
        wenxunId: Session.wenxunId,
        poiId: dyPoi,
        verifyToken: '${p['verify_token'] ?? ''}',
        encryptedCodes: codes,
        code: '',
        skuInfo: '{"sku_title":"${(first['sku_title'] ?? '').toString().replaceAll('"', '')}","sku_id":"${first['sku_id'] ?? ''}","pay_amount":${first['pay_amount'] ?? 0}}',
        operatorId: Session.staffId,
        operatorName: Session.staffName,
      );
      if (!mounted) return;
      setState(() { dyBusy = false; dyPrepare = null; });
      toast(context, '核销成功（${certs.length} 张）');
      // 核销完成切到已核销档让店员直接看到流水
      if (statusTab != 1) {
        _switch(() { statusTab = 1; });
      } else {
        _load();
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => dyBusy = false);
      toast(context, e.message, error: true);
    }
  }

  Future<void> _dyCancel(Map row) async {
    final ok = await confirm(context, '撤销核销',
        '${row['sku_title'] ?? ''}\n券码 ${row['code']}\n撤销后券回到待使用状态（仅验券1小时内可撤销）');
    if (!ok) return;
    try {
      await Api.douyinCancel(wenxunId: Session.wenxunId, logId: int.tryParse('${row['id']}') ?? 0, operatorName: Session.staffName);
      if (!mounted) return;
      toast(context, '撤销成功');
      _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader('核销管理', actions: [
        OutlinedButton.icon(
          onPressed: _load,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16), foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('刷新'),
        ),
      ]),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ---------- 左卡 ----------
            Expanded(flex: 6, child: _leftCard()),
            const SizedBox(width: 16),
            // ---------- 右卡 ----------
            Expanded(flex: 5, child: _rightCard()),
          ]),
        ),
      ),
    ]);
  }

  // ---------- 左卡：筛选 + 列表 ----------
  Widget _leftCard() {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        // 平台 + 状态筛选
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Row(children: [
            _seg('小程序订单', 0, platform, (v) => _switch(() { platform = v; })),
            const SizedBox(width: 8),
            _seg('抖音团购', 1, platform, (v) => _switch(() { platform = v; selected = null; dyPrepare = null; })),
            const SizedBox(width: 8),
            _seg('美团团购', 2, platform, (v) => _switch(() {
              platform = v; selected = null; mtPrepare = null; mtVerifyResult = null;
              _loadMtCfg(); // 美团档懒加载聚核配置
            })),
            const Spacer(),
            _timeSeg('今天', 0),
            const SizedBox(width: 6),
            _timeSeg('昨天', 1),
            const SizedBox(width: 6),
            _timeSeg('近7天', 2),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
          child: platform == 2
              ? Row(children: [
                  _seg('核销', 0, statusTab, (v) => _switch(() => statusTab = v)),
                  const SizedBox(width: 8),
                  _seg('已核销记录', 1, statusTab, (v) => _switch(() => statusTab = v)),
                ])
              : Row(children: [
                  _seg('未核销', 0, statusTab, (v) => _switch(() => statusTab = v)),
                  const SizedBox(width: 8),
                  _seg('已核销', 1, statusTab, (v) => _switch(() => statusTab = v)),
                  const SizedBox(width: 8),
                  _seg('退款', 2, statusTab, (v) => _switch(() => statusTab = v)),
                ]),
        ),
        // 搜索 / 扫码输入
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: (platform == 0 && statusTab == 0) || (platform == 2 && statusTab == 0)
              ? (platform == 2 ? _mtCodeField() : _scanField()) // 小程序/美团未核销档：扫码枪核销入口
              : _searchField(),
        ),
        const Divider(height: 14, color: PosTheme.line),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
              : error != null
                  ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: PosTheme.red))))
                  : list.isEmpty
                      ? EmptyView(_emptyText())
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          itemCount: list.length,
                          itemBuilder: (_, i) => _row(list[i]),
                        ),
        ),
      ]),
    );
  }

  String _emptyText() {
    if (platform == 2) {
      return statusTab == 0 ? '在上方输入或扫描美团券码验券（今日已核销记录见下）' : '暂无已核销记录';
    }
    if (platform == 1) {
      return statusTab == 0 ? '在上方输入或扫描顾客券码验券' : '暂无记录';
    }
    return ['暂无待核销订单', '暂无已核销订单', '暂无退款记录'][statusTab];
  }

  /// 美团购券码输入框：扫码枪回车自动验券
  Widget _mtCodeField() {
    return PosField(
      controller: mtCodeCtrl,
      focusNode: mtCodeFocus,
      autofocus: true,
      cleanScan: true,
      hint: '扫描顾客美团团购券码 / 手动输入后回车',
      icon: Icons.qr_code_scanner,
      onSubmitted: (_) => _mtPrepare(),
      suffix: TextButton(
        onPressed: mtBusy ? null : _mtPrepare,
        child: const Text('验券', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }

  /// 扫码核销输入框（小程序未核销档）：扫码枪回车自动触发
  Widget _scanField() {
    return PosField(
      controller: scanCtrl,
      focusNode: scanFocus,
      autofocus: true,
      textInputAction: TextInputAction.done,
      cleanScan: true, // 扫码枪扫核销码，脏字符自动清洗
      hint: '扫描顾客核销码 / 手动输入 6 位核销码后回车',
      icon: Icons.qr_code_scanner,
      onSubmitted: (_) => _scanVerify(),
      suffix: TextButton(
        onPressed: _scanVerify,
        child: const Text('核销', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _searchField() {
    return PosField(
      compact: true,
      cleanScan: true, // 支持扫码枪扫订单号/手机号搜索
      hint: platform == 0 ? '搜索订单号 / 手机号 / 顾客' : '搜索券码 / 团购标题 / 门店',
      icon: Icons.search,
      onChanged: (v) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 350), () {
          if (kw != v.trim()) {
            kw = v.trim();
            _load();
          }
        });
      },
    );
  }

  // ---------- 左列表行 ----------
  Widget _row(Map o) {
    final on = selected != null && '${selected!['id']}' == '${o['id']}';
    final title = platform == 0
        ? '${o['order_no'] ?? ''}'
        : platform == 2
            ? '${o['deal_title'] ?? o['ticket_name'] ?? ''}'
            : '${o['sku_title'] ?? ''}';
    final sub = platform == 0
        ? '${o['receiver'] ?? ''}${('${o['phone'] ?? ''}'.isNotEmpty) ? ' · ${o['phone']}' : ''}'
        : platform == 2
            ? '券码 ${o['code'] ?? ''}${('${o['operator_name'] ?? ''}'.isNotEmpty) ? ' · ${o['operator_name']}' : ''}'
            : '券码 ${o['code'] ?? ''}';
    final amount = platform == 0
        ? (double.tryParse('${o['total']}') ?? 0)
        : platform == 2
            ? (double.tryParse('${o['pay_amount']}') ?? 0)
            : (double.tryParse('${o['amount']}') ?? 0);
    final color = _statusColor(o);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => selected = o),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: on ? PosTheme.accent.withOpacity(0.06) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? PosTheme.accent.withOpacity(0.35) : Colors.transparent),
          ),
          child: Row(children: [
            // 状态点 + 标题
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
            ])),
            const SizedBox(width: 10),
            Text('${o['time'] ?? ''}'.substring(0, '${o['time'] ?? ''}'.length >= 16 ? 16 : '${o['time'] ?? ''}'.length),
                style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
            const SizedBox(width: 10),
            SizedBox(
              width: 76,
              child: Text('¥${Fmt.money(amount)}', textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
        ),
      ),
    );
  }

  Color _statusColor(Map o) {
    if (platform == 1) {
      return int.tryParse('${o['status']}') == 2 ? const Color(0xFFF59E0B) : PosTheme.green;
    }
    if (platform == 2) {
      // 美团流水：1 已核销（绿）2 已撤销（橙）
      return int.tryParse('${o['status']}') == 2 ? const Color(0xFFF59E0B) : PosTheme.green;
    }
    switch (int.tryParse('${o['display']}') ?? 0) {
      case 20: return PosTheme.accent; // 待核销
      case 30: return PosTheme.blue;
      case 60: return const Color(0xFFF59E0B); // 退款中
      case 70: return const Color(0xFFEF4444); // 已退款
      case 40: return PosTheme.green;
      default: return PosTheme.textSub;
    }
  }

  // ---------- 右卡 ----------
  Widget _rightCard() {
    if (platform == 1 && statusTab == 0) {
      return _dyWorkCard(); // 抖音未核销档 = 验券工作卡
    }
    if (platform == 2 && statusTab == 0) {
      return _mtWorkCard(); // 美团未核销档 = 验券工作卡
    }
    if (selected == null) {
      return AppCard(child: EmptyView(loading ? '加载中…' : '选择记录查看详情'));
    }
    if (platform == 2) return _mtDetail(selected!);
    return platform == 0 ? _miniDetail(selected!) : _dyDetail(selected!);
  }

  // ---------- 美团：验券工作卡（未核销档） ----------
  Widget _mtWorkCard() {
    final p = mtPrepare;
    return AppCard(
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('美团团购核销', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton.icon(
              onPressed: _showMtSettings,
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: const Text('美团设置', style: TextStyle(fontSize: 12.5)),
            ),
          ]),
          const SizedBox(height: 2),
          Text('顾客出示美团 App 团购券二维码，扫码枪扫描或输入券码后验券核销',
              style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
          const SizedBox(height: 14),
          // 配置状态
          if ('${mtCfg['configured'] ?? ''}' != 'true')
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFDBA74)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(mtCfg['tip'] ?? '尚未配置：点右上「美团设置」填入无限聚核 API Key 与门店 shopId',
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFF9A3412))),
                const SizedBox(height: 4),
                const Text('配置后还需在聚核开发者中心完成美团门店授权（授权链接可在设置页生成）',
                    style: TextStyle(fontSize: 11.5, color: Color(0xFF9A3412))),
              ]),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF0FDF4),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: PosTheme.green.withOpacity(0.35)),
              ),
              child: Text('门店 shopId ${mtCfg['shop_id'] ?? ''} · Key ${mtCfg['api_key_masked'] ?? ''}',
                  style: const TextStyle(fontSize: 12.5, color: PosTheme.green)),
            ),
          const SizedBox(height: 12),
          // 验券结果确认卡（核销凭证）
          if (p != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF0FDF4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: PosTheme.green.withOpacity(0.4)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p['ticketName'] ?? '美团团购券'}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Row(children: [
                  Text('¥${p['payAmountText'] ?? '0.00'}',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: PosTheme.green)),
                  const Spacer(),
                  Text('券码 ${p['code'] ?? ''}', style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
                ]),
                if (('${p['actualPayText'] ?? ''}').isNotEmpty && (double.tryParse('${p['actualPayText']}') ?? 0) > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('顾客实付 ¥${p['actualPayText']}${('${p['marketPriceText'] ?? ''}').isNotEmpty ? ' · 门市价 ¥${p['marketPriceText']}' : ''}',
                        style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
                  ),
                const SizedBox(height: 10),
                BigButton('确认核销', onTap: mtBusy ? () {} : _mtVerify, height: 48),
              ]),
            ),
            const SizedBox(height: 10),
          ],
          if (mtVerifyResult != null) ...[
            // 核销成功回执（含撤销入口）
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: PosTheme.blue.withOpacity(0.4)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('核销成功', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: PosTheme.blue)),
                const SizedBox(height: 6),
                for (final r in (mtVerifyResult!['rows'] ?? []) as List)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      Expanded(child: Text('${r['dealTitle']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13))),
                      Text('${r['receiptCode']}', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                      const SizedBox(width: 8),
                      Text('¥${r['payAmountText']}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                if ((mtVerifyResult!['credentials'] ?? []).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('已保存撤销凭证，如需撤销请到「已核销记录」选中该笔操作',
                      style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                ],
              ]),
            ),
            const SizedBox(height: 10),
          ],
          if (mtBusy) const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(color: PosTheme.accent))),
          const SizedBox(height: 8),
          Text('说明：先验券再核销；核销后可在「已核销记录」撤销（平台口径以聚核为准）；结果未知时请勿重复核销',
              style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        ]),
      ),
    );
  }

  // ---------- 美团流水详情（已核销记录档） ----------
  Widget _mtDetail(Map o) {
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _statusPill(o),
          const Spacer(),
          Text('¥${Fmt.money(o['pay_amount'])}', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: _statusColor(o))),
        ]),
        const SizedBox(height: 10),
        _kvRow('团购', '${o['deal_title'] ?? o['ticket_name'] ?? '—'}'),
        _kvRow('券码', '${o['code'] ?? '—'}'),
        _kvRow('门店 shopId', '${o['shop_id'] ?? '—'}'),
        _kvRow('张数', '${o['num'] ?? 1}'),
        _kvRow('操作员', '${o['operator_name'] ?? '—'}'),
        _kvRow('核销时间', '${o['create_time'] ?? '—'}'),
        if (int.tryParse('${o['status']}') == 2) _kvRow('撤销时间', '${o['cancel_time'] ?? '—'}'),
        const Spacer(),
        if ('${o['status']}' == '1' && o['has_credential'] == true)
          BigButton('撤销核销', onTap: () => _mtCancel(o), height: 50, color: const Color(0xFFEF4444))
        else if ('${o['status']}' == '1')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(child: Text('缺少撤销凭证，请到聚核后台处理', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint))),
          ),
        if (int.tryParse('${o['status']}') == 2)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(child: Text('该笔已撤销', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint))),
          ),
      ]),
    );
  }

  // ---------- 小程序详情 ----------
  Widget _miniDetail(Map o) {
    final display = int.tryParse('${o['display']}') ?? 0;
    final isPaid = display == 20;
    final isRefunding = display == 60;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _statusPill(o),
          const Spacer(),
          Text('¥${Fmt.money(o['total'])}', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: _statusColor(o))),
        ]),
        const SizedBox(height: 10),
        _kvRow('订单号', '${o['order_no'] ?? ''}'),
        _kvRow('顾客', '${o['receiver'] ?? ''}${('${o['phone'] ?? ''}'.isNotEmpty) ? ' · ${o['phone']}' : ''}'),
        _kvRow('核销码', '${o['verify_code'] ?? ''}'),
        _kvRow('核销时间', '${(o['verify_time'] ?? '').toString().isEmpty ? '—' : o['verify_time']}'),
        _kvRow('时间', '${o['time'] ?? ''}'),
        if (int.tryParse('${o['refund_status']}') == 2) ...[
          _kvRow('退款金额', '¥${Fmt.money(o['refund_amount'])}'),
          _kvRow('退款原因', '${o['refund_reason'] ?? '—'}'),
        ],
        const SizedBox(height: 10),
        // 商品清单
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: PosTheme.line.withOpacity(0.6)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('商品清单', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            ...((o['goods'] ?? []) as List).map((g) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Expanded(child: Text('${g['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                Text('×${g['quantity'] ?? 1}', style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
              ]),
            )),
          ]),
        ),
        const Spacer(),
        // 操作区
        if (isPaid)
          BigButton('确认核销', onTap: () => _verifyRow(o), height: 50)
        else if (isRefunding)
          Row(children: [
            Expanded(child: BigButton('同意退款', onTap: () => _refundAudit(o, 'agree'), height: 50)),
            const SizedBox(width: 12),
            Expanded(child: BigButton('拒绝退款', onTap: () => _refundAudit(o, 'reject'), height: 50, color: PosTheme.textSub)),
          ]),
        if (display == 40)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(child: Text('该订单已完成核销', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint))),
          ),
      ]),
    );
  }

  Widget _kvRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 72, child: Text(k, style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint))),
        Expanded(child: Text(v, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  Widget _statusPill(Map o) {
    final color = _statusColor(o);
    final text = platform == 2
        ? (int.tryParse('${o['status']}') == 2 ? '已撤销' : '已核销')
        : '${o['status_text'] ?? ''}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
    );
  }

  // ---------- 抖音：验券工作卡（未核销档） ----------
  Widget _dyWorkCard() {
    final certs = (dyPrepare?['certificates'] ?? []) as List;
    return AppCard(
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('抖音团购核销', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('顾客出示抖音 App 团购券二维码，扫码枪扫描或输入券码后验券',
              style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
          const SizedBox(height: 14),
          // 门店选择
          if (dyShops.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: dyPoi.isEmpty ? null : dyPoi,
              isDense: true,
              decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.store, size: 20), hintText: '选择抖音门店'),
              items: dyShops.map((s) => DropdownMenuItem<String>(
                value: '${s['poi_id'] ?? ''}',
                child: Text('门店 ${s['poi_id'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
              )).toList(),
              onChanged: (v) => setState(() { dyPoi = v ?? ''; dyPrepare = null; }),
            )
          else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFDBA74)),
              ),
              child: Text(dyShopTip.isEmpty ? '尚未授权抖音门店：请在小程序「核销 → 抖音团购」完成门店授权' : dyShopTip,
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF9A3412))),
            ),
          const SizedBox(height: 12),
          PosField(
            controller: dyCodeCtrl,
            focusNode: dyCodeFocus,
            autofocus: dyShops.isNotEmpty,
            cleanScan: true, // 扫码枪扫券码，脏字符自动清洗
            hint: '扫描顾客券码二维码 / 输入券码明文',
            icon: Icons.qr_code_scanner,
            onSubmitted: (_) => _dyPrepare(),
            suffix: TextButton(onPressed: dyBusy ? null : _dyPrepare, child: const Text('验券', style: TextStyle(fontWeight: FontWeight.w700))),
          ),
          const SizedBox(height: 14),
          // 验券结果
          if (certs.isNotEmpty) _dyCertCard(certs),
          if (dyBusy) const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(color: PosTheme.accent))),
          const SizedBox(height: 8),
          Text('说明：核销后 1 小时内可在「已核销」档撤销；一单多券一次全部核销',
              style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        ]),
      ),
    );
  }

  Widget _dyCertCard(List certs) {
    final first = certs.first as Map;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosTheme.green.withOpacity(0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${first['sku_title'] ?? '抖音团购券'}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Row(children: [
          Text('¥${Fmt.money(first['pay_amount'])}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: PosTheme.green)),
          const Spacer(),
          Text('共 ${certs.length} 张可用', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
        ]),
        const SizedBox(height: 10),
        BigButton('确认核销（${certs.length} 张）', onTap: dyBusy ? () {} : _dyVerify, height: 48),
      ]),
    );
  }

  // ---------- 抖音流水详情 ----------
  Widget _dyDetail(Map o) {
    final canCancel = o['can_cancel'] == true;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _statusPill(o),
          const Spacer(),
          Text('¥${Fmt.money(o['amount'])}', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: _statusColor(o))),
        ]),
        const SizedBox(height: 10),
        _kvRow('团购标题', '${o['sku_title'] ?? '—'}'),
        _kvRow('券码', '${o['code'] ?? '—'}'),
        _kvRow('门店', '${o['poi_id'] ?? '—'}'),
        _kvRow('操作员', '${o['operator'] ?? '—'}'),
        _kvRow('核销时间', '${o['verify_time'] ?? '—'}'),
        if (int.tryParse('${o['status']}') == 2) _kvRow('撤销时间', '${o['cancel_time'] ?? '—'}'),
        const Spacer(),
        if (canCancel)
          BigButton('撤销核销', onTap: () => _dyCancel(o), height: 50, color: const Color(0xFFEF4444))
        else if (int.tryParse('${o['status']}') == 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(child: Text('已超过 1 小时撤销窗口或缺少撤销凭据', style: TextStyle(fontSize: 12.5, color: PosTheme.textHint))),
          ),
      ]),
    );
  }

  // ---------- 通用小组件（与订单页同款式） ----------
  Widget _seg(String text, int v, int cur, ValueChanged<int> onSel) {
    final on = cur == v;
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () => onSel(v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  Widget _timeSeg(String text, int v) {
    final on = dayTab == v;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _switch(() => dayTab = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6.5),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line),
        ),
        child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: on ? PosTheme.accent : PosTheme.textHint)),
      ),
    );
  }
}
