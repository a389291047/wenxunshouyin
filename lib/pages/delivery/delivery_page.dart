import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

/// 订单配送：聚合 美团外卖 / 京东秒送 / 淘宝闪购 订单，零售版与餐饮版共用
/// 流程：平台配置（密钥/门店/授权token）→ 拉单入订单池 → 接单回传平台 → 配送状态流转
class DeliveryPage extends StatefulWidget {
  const DeliveryPage({super.key});
  @override
  State<DeliveryPage> createState() => _DeliveryPageState();
}

class _DeliveryPageState extends State<DeliveryPage> {
  List orders = [];
  List configs = []; // [{platform,title,configured,enabled,app_id,app_secret,store_id,has_token}]
  bool loading = false;
  String platform = '';       // ''=全部
  int statusFilter = -1;      // -1=全部
  bool pulling = false;

  static const platformMeta = {
    'meituan': ('美团外卖', Color(0xFFFFC300)),
    'jddj': ('京东秒送', Color(0xFFE1251B)),
    'shangou': ('淘宝闪购', Color(0xFF0089FF)),
  };
  static const statusMeta = {
    0: ('待接单', PosTheme.accent),
    1: ('已接单', PosTheme.blue),
    2: ('配送中', PosTheme.amber),
    3: ('已送达', PosTheme.green),
    9: ('已取消', PosTheme.textHint),
  };

  @override
  void initState() {
    super.initState();
    _loadConfigs();
    _load();
  }

  bool _platformEnabled(String p) {
    for (final c in configs) {
      if ('${c['platform']}' == p && '${c['enabled']}' == '1') return true;
    }
    return false;
  }

  Future<void> _loadConfigs() async {
    try {
      final r = await Api.deliveryConfigs(Session.wenxunId);
      if (mounted) setState(() => configs = r);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final r = await Api.deliveryOrders(Session.wenxunId, platform: platform);
      if (!mounted) return;
      setState(() { orders = r; loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      toast(context, e.message, error: true);
    }
  }

  /// 拉单：选中平台（空=所有已启用平台）
  Future<void> _pull() async {
    if (pulling) return;
    final targets = platform.isNotEmpty
        ? [platform]
        : configs.where((c) => '${c['enabled']}' == '1').map((c) => '${c['platform']}').toList();
    if (targets.isEmpty) {
      toast(context, '没有已启用的平台，请先配置平台', error: true);
      return;
    }
    setState(() => pulling = true);
    final errs = <String>[];
    final okMsgs = <String>[];
    for (final p in targets) {
      try {
        final r = await Api.deliveryPull(Session.wenxunId, p);
        okMsgs.add('${platformMeta[p]?.$1 ?? p}：${r['msg'] ?? '成功'}');
      } on ApiError catch (e) {
        errs.add('${platformMeta[p]?.$1 ?? p}：${e.message}');
      }
    }
    if (!mounted) return;
    setState(() => pulling = false);
    if (okMsgs.isNotEmpty) toast(context, okMsgs.join('\n'), error: false);
    if (errs.isNotEmpty) toast(context, errs.join('\n'), error: true);
    _load();
  }

  Future<void> _op(Map o, String action, String tip) async {
    final ok = await confirm(context, tip, '订单 ${o['platform_order_id']}，确认执行「$tip」？');
    if (!ok || !mounted) return;
    loadingDialog(context, '操作中…');
    try {
      await Api.deliveryOp(Session.wenxunId, int.tryParse('${o['id']}') ?? 0, action);
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '$tip成功');
      _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 平台配置弹窗 ====================
  Future<void> _openConfig() async {
    await showDialog(context: context, builder: (_) => _ConfigDialog(configs: configs));
    _loadConfigs();
    _load();
  }

  List get _filtered {
    return orders.where((o) => statusFilter == -1 || int.tryParse('${o['status']}') == statusFilter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final pending = orders.where((o) => '${o['status']}' == '0').length;
    final delivering = orders.where((o) => '${o['status']}' == '2').length;
    return Column(children: [
      PageHeader('订单配送', actions: [
        OutlinedButton.icon(
          onPressed: _openConfig,
          style: OutlinedButton.styleFrom(foregroundColor: PosTheme.blue, side: const BorderSide(color: PosTheme.blue), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
          icon: const Icon(Icons.settings_outlined, size: 18),
          label: const Text('平台配置'),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: pulling ? null : _pull,
          style: OutlinedButton.styleFrom(foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
          icon: pulling
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: PosTheme.accent))
              : const Icon(Icons.sync, size: 18),
          label: const Text('拉取平台订单'),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
        child: Row(children: [
          Expanded(child: StatTile(label: '待接单', value: '$pending', icon: Icons.notifications_active_outlined, color: PosTheme.accent)),
          const SizedBox(width: 10),
          Expanded(child: StatTile(label: '配送中', value: '$delivering', icon: Icons.local_shipping_outlined, color: PosTheme.amber)),
          const SizedBox(width: 10),
          Expanded(child: StatTile(label: '订单池', value: '${orders.length}', icon: Icons.receipt_long_outlined, color: PosTheme.blue)),
        ]),
      ),
      // 平台 + 状态筛选
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          _chip('全部平台', platform == '', () => setState(() { platform = ''; _load(); })),
          for (final e in platformMeta.entries)
            _chip('${e.value.$1}${_platformEnabled(e.key) ? '' : '（未启用）'}', platform == e.key,
                () => setState(() { platform = e.key; _load(); }),
                color: e.value.$2),
          const SizedBox(width: 8),
          _chip('全部状态', statusFilter == -1, () => setState(() => statusFilter = -1)),
          for (final e in statusMeta.entries)
            _chip(e.value.$1, statusFilter == e.key, () => setState(() => statusFilter = e.key), color: e.value.$2),
        ]),
      ),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
            : _filtered.isEmpty
                ? const EmptyView('暂无平台订单，点击右上角「拉取平台订单」同步')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _orderCard(_filtered[i]),
                  ),
      ),
    ]);
  }

  Widget _chip(String text, bool on, VoidCallback onTap, {Color color = PosTheme.accent}) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: on ? color : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: on ? color : PosTheme.line),
        ),
        child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  Widget _orderCard(Map o) {
    final st = int.tryParse('${o['status']}') ?? 0;
    final sm = statusMeta[st] ?? ('未知', PosTheme.textHint);
    final pm = platformMeta['${o['platform']}'] ?? ('其他', PosTheme.textHint);
    final items = (o['items'] ?? []) as List;
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: pm.$2.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
            child: Text(pm.$1, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: pm.$2)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text('单号 ${o['platform_order_id'] ?? ''}', style: const TextStyle(fontSize: 13, color: PosTheme.textSub), overflow: TextOverflow.ellipsis)),
          TagChip(sm.$1, color: sm.$2),
          const SizedBox(width: 12),
          Text('¥${o['amount'] ?? 0}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.accent)),
        ]),
        const SizedBox(height: 10),
        Text('${o['receiver'] ?? ''}　${o['phone'] ?? ''}　${o['address'] ?? ''}',
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
        if (items.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(items.map((it) => '${it['title']}×${it['quantity']}').join('　'),
              style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
        ],
        if ('${o['remark'] ?? ''}'.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('备注：${o['remark']}', style: const TextStyle(fontSize: 13, color: PosTheme.amber)),
        ],
        const SizedBox(height: 10),
        Row(children: [
          Text('${o['create_time'] ?? ''}', style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
          const Spacer(),
          if (st == 0)
            BigButton('接单（回传平台）', onTap: () => _op(o, 'accept', '接单'), width: 150, height: 40),
          if (st == 1)
            BigButton('开始配送', onTap: () => _op(o, 'delivering', '开始配送'), color: const Color(0xFFF0F5FF), textColor: PosTheme.blue, width: 130, height: 40),
          if (st == 2)
            BigButton('确认送达', onTap: () => _op(o, 'delivered', '确认送达'), color: const Color(0xFFEAF9F0), textColor: PosTheme.green, width: 130, height: 40),
        ]),
      ]),
    );
  }
}

// ==================== 平台配置弹窗 ====================
class _ConfigDialog extends StatefulWidget {
  final List configs;
  const _ConfigDialog({required this.configs});
  @override
  State<_ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<_ConfigDialog> {
  String platform = 'meituan';
  final appIdCtrl = TextEditingController();
  final secretCtrl = TextEditingController();
  final sourceCtrl = TextEditingController();
  final storeCtrl = TextEditingController();
  final tokenCtrl = TextEditingController();
  bool isTest = false; // 京东秒送：测试环境 newopen.ndev / 正式 newopen
  bool enabled = false;
  bool saving = false;
  Map? current;

  @override
  void initState() {
    super.initState();
    _pick('meituan');
  }

  void _pick(String p) {
    setState(() {
      platform = p;
      current = null;
      appIdCtrl.clear();
      secretCtrl.clear();
      sourceCtrl.clear();
      storeCtrl.clear();
      tokenCtrl.clear();
      isTest = false;
      enabled = false;
      for (final c in widget.configs) {
        if ('${c['platform']}' == p) {
          current = c;
          appIdCtrl.text = '${c['app_id'] ?? ''}';
          secretCtrl.text = '${c['app_secret'] ?? ''}'; // 已打码，不改则不覆盖
          sourceCtrl.text = '${c['source_id'] ?? ''}';
          storeCtrl.text = '${c['store_id'] ?? ''}';
          tokenCtrl.text = '${c['has_token'] == 1 ? '****' : ''}';
          isTest = '${c['env'] ?? 'prod'}' == 'test';
          enabled = '${c['enabled']}' == '1';
          break;
        }
      }
    });
  }

  Future<void> _save({bool silent = false}) async {
    if (saving) return;
    saving = true;
    try {
      await Api.deliveryConfigSave(
        wenxunId: Session.wenxunId,
        platform: platform,
        appId: appIdCtrl.text.trim(),
        appSecret: secretCtrl.text.trim(),
        sourceId: sourceCtrl.text.trim(),
        env: isTest ? 'test' : 'prod',
        storeId: storeCtrl.text.trim(),
        accessToken: tokenCtrl.text.trim(),
        enabled: enabled,
      );
      if (!mounted) return;
      if (silent) {
        toast(context, '配置已保存，正在测试…');
      } else {
        Navigator.pop(context);
        toast(context, '配置已保存');
      }
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('外卖平台配置'),
      content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, children: [
          for (final e in _DeliveryPageState.platformMeta.entries)
            ChoiceChip(
              label: Text(e.value.$1),
              selected: platform == e.key,
              selectedColor: e.value.$2.withOpacity(0.18),
              labelStyle: TextStyle(color: platform == e.key ? e.value.$2 : PosTheme.textSub, fontWeight: FontWeight.w600),
              onSelected: (_) => _pick(e.key),
            ),
        ]),
        const SizedBox(height: 14),
        PosField(controller: appIdCtrl, compact: true,
          label: platform == 'meituan' ? '开发者 app_id' : '开发者 app_key',
          hint: '开放平台开发者应用ID（全商户共用）',
        ),
        const SizedBox(height: 12),
        PosField(controller: secretCtrl, obscureText: true, compact: true,
          label: '应用密钥 app_secret',
          hint: '开发者应用密钥；留空或 **** 表示不修改',
        ),
        if (platform == 'jddj') ...[
          const SizedBox(height: 12),
          PosField(controller: sourceCtrl, compact: true,
            label: '商户 SourceID（绑定商户ID）',
            hint: '京东秒送「商户绑定」里该商户的商户ID，如 107713',
          ),
        ],
        const SizedBox(height: 12),
        PosField(controller: storeCtrl, compact: true,
          label: platform == 'jddj' ? '门店编号' : '平台门店ID',
          hint: platform == 'meituan'
              ? '美团授权门店 ePoiId'
              : platform == 'jddj'
                  ? '京东秒送联调/门店管理里的门店编号'
                  : '饿了么门店 shopId',
        ),
        if (platform == 'jddj') ...[
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('测试环境（newopen.ndev.imdada.cn）', style: TextStyle(fontSize: 14.5)),
            subtitle: Text(
              isTest
                  ? '当前：测试联调环境（达达只对报备 IP 开放，公网访问会 403，工具会自动回落正式域名）'
                  : '当前：正式环境 newopen.imdada.cn',
              style: const TextStyle(fontSize: 12, color: PosTheme.textSub),
            ),
            value: isTest,
            activeColor: PosTheme.amber,
            onChanged: (v) => setState(() => isTest = v),
          ),
        ],
        if (platform == 'shangou') ...[
          const SizedBox(height: 12),
          PosField(controller: tokenCtrl, obscureText: true, compact: true,
            label: 'OAuth access_token（淘宝闪购）',
            hint: '商户授权后取得；留空或 **** 表示不修改',
          ),
        ],
        const SizedBox(height: 10),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用该平台', style: TextStyle(fontSize: 14.5)),
          value: enabled,
          activeColor: PosTheme.accent,
          onChanged: (v) => setState(() => enabled = v),
        ),
      ])),
      actions: [
        TextButton(
          onPressed: saving ? null : () => _probe(context),
          child: const Text('测试连接'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
          onPressed: saving ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  /// 测试连接：先保存当前填写内容，再用真实配置请求平台，把原始响应给用户看
  Future<void> _probe(BuildContext ctx) async {
    await _save(silent: true);
    if (!mounted) return;
    loadingDialog(ctx, '正在请求平台…');
    try {
      final r = await Api.deliveryProbe(Session.wenxunId, platform);
      if (!mounted) return;
      Navigator.pop(ctx);
      final url = '${r['url'] ?? ''}';
      final status = '${r['http_status'] ?? 0}';
      final raw = '${r['raw'] ?? ''}';
      final note = '${r['note'] ?? ''}';
      final summary = '${r['summary'] ?? ''}';
      final ok = r['ok'] == true;
      showDialog(context: ctx, builder: (_) => AlertDialog(
        title: Row(children: [
          Icon(ok ? Icons.check_circle : Icons.error_outline, size: 22, color: ok ? PosTheme.green : PosTheme.red),
          const SizedBox(width: 8),
          Text(ok ? '连接正常' : '连接失败'),
        ]),
        content: SizedBox(width: 620, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (url.isNotEmpty) Text('请求地址：$url', style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
          const SizedBox(height: 4),
          Text('HTTP 状态：$status', style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
          if (summary.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(summary, style: TextStyle(fontSize: 13, height: 1.5, color: ok ? PosTheme.green : PosTheme.red)),
          ),
          if (note.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('提示：$note', style: const TextStyle(fontSize: 12.5, color: PosTheme.amber)),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(8)),
            child: SelectableText(raw, style: const TextStyle(fontSize: 12, height: 1.5, fontFamily: 'Menlo')),
          ),
        ]))),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
      ));
    } on ApiError catch (e) {
      if (!mounted) return;
      Navigator.pop(ctx);
      toast(ctx, e.message, error: true);
    }
  }
}
