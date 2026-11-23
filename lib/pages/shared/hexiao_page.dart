import 'package:flutter/material.dart';
import '../../core/api.dart';
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
  int platform = 0; // 0 小程序订单 1 抖音团购
  int statusTab = 0; // 0 未核销 1 已核销 2 退款
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
    super.dispose();
  }

  String get _dayStr => ['today', 'yesterday', 'week'][dayTab];
  String get _tabStr => ['undone', 'done', 'refund'][statusTab];
  String get _platformStr => platform == 0 ? 'mini' : 'douyin';

  Future<void> _load() async {
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
          child: Row(children: [
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
          child: platform == 0 && statusTab == 0
              ? _scanField() // 小程序未核销档：扫码枪核销入口
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
    if (platform == 1) {
      return statusTab == 0 ? '在上方输入或扫描顾客券码验券' : '暂无记录';
    }
    return ['暂无待核销订单', '暂无已核销订单', '暂无退款记录'][statusTab];
  }

  /// 扫码核销输入框（小程序未核销档）：扫码枪回车自动触发
  Widget _scanField() {
    return TextField(
      controller: scanCtrl,
      focusNode: scanFocus,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _scanVerify(),
      decoration: InputDecoration(
        isDense: true,
        hintText: '扫描顾客核销码 / 手动输入 6 位核销码后回车',
        prefixIcon: const Icon(Icons.qr_code_scanner, size: 20),
        suffixIcon: TextButton(
          onPressed: _scanVerify,
          child: const Text('核销', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _searchField() {
    return TextField(
      onChanged: (v) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 350), () {
          if (kw != v.trim()) {
            kw = v.trim();
            _load();
          }
        });
      },
      decoration: InputDecoration(
        isDense: true,
        hintText: platform == 0 ? '搜索订单号 / 手机号 / 顾客' : '搜索券码 / 团购标题 / 门店',
        prefixIcon: const Icon(Icons.search, size: 20),
      ),
    );
  }

  // ---------- 左列表行 ----------
  Widget _row(Map o) {
    final on = selected != null && '${selected!['id']}' == '${o['id']}';
    final title = platform == 0 ? '${o['order_no'] ?? ''}' : '${o['sku_title'] ?? ''}';
    final sub = platform == 0
        ? '${o['receiver'] ?? ''}${('${o['phone'] ?? ''}'.isNotEmpty) ? ' · ${o['phone']}' : ''}'
        : '券码 ${o['code'] ?? ''}';
    final amount = platform == 0 ? (double.tryParse('${o['total']}') ?? 0) : (double.tryParse('${o['amount']}') ?? 0);
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
    if (selected == null) {
      return AppCard(child: EmptyView(loading ? '加载中…' : '选择记录查看详情'));
    }
    return platform == 0 ? _miniDetail(selected!) : _dyDetail(selected!);
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
    final text = platform == 0 ? '${o['status_text'] ?? ''}' : '${o['status_text'] ?? ''}';
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
          TextField(
            controller: dyCodeCtrl,
            focusNode: dyCodeFocus,
            autofocus: dyShops.isNotEmpty,
            onSubmitted: (_) => _dyPrepare(),
            decoration: InputDecoration(
              isDense: true,
              hintText: '扫描顾客券码二维码 / 输入券码明文',
              prefixIcon: const Icon(Icons.qr_code_scanner, size: 20),
              suffixIcon: TextButton(onPressed: dyBusy ? null : _dyPrepare, child: const Text('验券', style: TextStyle(fontWeight: FontWeight.w700))),
            ),
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
