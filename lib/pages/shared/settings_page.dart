import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/bt_printer.dart';
import '../../core/cart_prefs.dart';
import '../../core/cash_drawer.dart';
import '../../core/clear_pin.dart';
import '../../core/cloud_printer.dart';
import '../../core/customer_display.dart';
import '../../core/display_prefs.dart';
import '../../core/layout_prefs.dart';
import '../../core/no_code_common.dart';
import '../../core/pay_methods.dart';
import '../../core/print_prefs.dart';
import '../../core/printer_route.dart';
import '../../core/scale.dart';
import '../../core/search_focus.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/theme_prefs.dart';
import '../../core/usb_printer.dart';
import '../../core/updater.dart';
import '../../core/voice.dart';
import '../../core/window_prefs.dart';
import '../../ui/activity_admin.dart';
import '../../ui/receipt_preview.dart';
import '../../ui/update_dialog.dart';
import '../../ui/widgets.dart';
import '../customer_screen_page.dart';
import '../login_page.dart';
import 'kefu_page.dart';

/// 设置页（零售/餐饮共用）：店铺信息、云打印、USB打印、账号、关于
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List printers = [];
  bool loading = true;

  // USB 打印机
  bool usbLoading = false;
  bool usbEnabled = false;
  int usbPaper = 58;
  String usbSpec = 'pos58'; // pos58/pos80/dot/a4
  String usbMode = 'auto'; // auto=自动打印 manual=手动打印
  Map<String, dynamic>? usbSelected;
  List<Map<String, dynamic>> usbPrinters = [];
  // 每规格自定义配置缓存（v3.3.159）：key → {pageMm, offMm}
  Map<String, Map<String, double>> usbCfgs = const {};

  // 蓝牙打印机（v3.3.185）
  bool btLoading = false;
  bool btEnabled = false;
  String btSpec = 'pos58'; // pos58/pos80
  Map<String, dynamic>? btSelected;
  List<Map<String, dynamic>> btDevices = [];
  List<Map<String, dynamic>> btScanResults = []; // Android 扫描结果（含未配对）
  bool btScanning = false;

  // 钱箱（v3.3.202）：现金结算自动弹箱，走 USB/蓝牙小票打印机 RJ11 口
  bool drawerEnabled = false;
  String drawerChannel = 'usb'; // usb | bt
  bool drawerTesting = false;
  String drawerPrinterName = ''; // 当前通道已选打印机名称（测试排障提示用）

  // 功能设置（v3.3.187）
  bool searchFocusOn = false; // 搜索框始终聚焦
  String cartSide = 'right'; // 购物车显示位置（left/right）

  // 语音播报
  bool voiceEnabled = true;

  // 云打印总开关（v3.3.157，商户自选：打印 / 不打印）
  bool cloudEnabled = true;

  // 支付方式排序（v3.3.163）：结账弹窗展示顺序，商户自定义
  List<String> payOrder = PayMethods.defaultOrder;

  // 小票打印开关（云打印/USB 通用，v3.3.77）
  Map<String, bool> printOn = {};

  // 权限密码管理（商户专属）：员工列表
  List<Map<String, dynamic>> staffs = [];
  bool staffLoading = false;

  // 打印机绑定（v3.3.124，餐饮版）：按机配置在「云打印机」页直接绑定（角色/出票方式/分类）
  bool riceFrontOnly = false;
  List cats = []; // 商品分类（后厨绑定配置用）
  bool routeLoading = false;
  Map<String, PrinterCfg> printerCfgs = {}; // machine_code → 绑定配置
  Map<String, bool> kitchenTicketOpts = {}; // 后厨小票明细行开关（v3.3.135 云端）
  List<String> zuofaItems = []; // 常用做法列表（v3.3.141 云端，商户自定义）
  final zuofaCtrl = TextEditingController();
  bool cloudSyncing = false; // 正在与云端同步
  bool cloudSyncOk = true; // 上次云端同步结果（false=断网，仅本机生效）

  @override
  void initState() {
    super.initState();
    _load();
    _loadUsb();
    _loadBt();
    _loadDrawer();
    _loadFunc();
    _loadVoice();
    _loadPrintPrefs();
    _loadStaffs();
    _loadRoute();
    _loadCloudOn();
    _loadNoCode();
    // 显示自定义设置（v3.3.193）：改完即时反映到设置页自身（整体字体缩放直接生效）
    DisplayPrefs.fontScale.addListener(_onDisplayChanged);
    DisplayPrefs.fontWeight.addListener(_onDisplayChanged);
    DisplayPrefs.goodsFont.addListener(_onDisplayChanged);
    DisplayPrefs.goodsCols.addListener(_onDisplayChanged);
    DisplayPrefs.goodsImage.addListener(_onDisplayChanged);
    ThemePrefs.skinId.addListener(_onDisplayChanged); // 主体风格（v3.3.194）
    PayMethods.load().then((o) {
      if (mounted) setState(() => payOrder = o);
    });
  }

  void _onDisplayChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    DisplayPrefs.fontScale.removeListener(_onDisplayChanged);
    DisplayPrefs.fontWeight.removeListener(_onDisplayChanged);
    DisplayPrefs.goodsFont.removeListener(_onDisplayChanged);
    DisplayPrefs.goodsCols.removeListener(_onDisplayChanged);
    DisplayPrefs.goodsImage.removeListener(_onDisplayChanged);
    ThemePrefs.skinId.removeListener(_onDisplayChanged);
    super.dispose();
  }

  // 无码商品常用（v3.3.181）：本机配置，自动记录最近 5 条名称，只可删除不可手工添加
  List<String> noCodeItems = [];

  Future<void> _loadNoCode() async {
    final l = await NoCodeCommon.load();
    if (mounted) setState(() => noCodeItems = l);
  }

  /// 无码商品常用：只记名称（和常用做法同样的标签样式），支付/加菜成功自动记录，仅可删除
  Widget _noCodeCard() {
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.bookmark_border, '无码商品常用'),
      const SizedBox(height: 4),
      Text('收银时点「无码商品/无码菜品」名称框右侧「常用」，选名称一键带入（单价仍需手输）。'
          '零售/生鲜支付成功、餐饮加菜成功的无码项名称自动记录，最多 ${NoCodeCommon.max} 条（新的顶掉最旧的），此处只可删除。',
          style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8, runSpacing: 8,
        children: noCodeItems.asMap().entries.map((en) => Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: PosTheme.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(en.value, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: PosTheme.textMain)),
            const SizedBox(width: 6),
            InkWell(
              onTap: () async {
                await NoCodeCommon.removeAt(en.key);
                await _loadNoCode();
              },
              borderRadius: BorderRadius.circular(20),
              child: const Icon(Icons.cancel_outlined, size: 17, color: PosTheme.textHint),
            ),
          ]),
        )).toList(),
      ),
      if (noCodeItems.isEmpty)
        Text('暂无常用项。收银时用过的无码项名称会自动出现在这里（最近 ${NoCodeCommon.max} 条）。',
            style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
    ]));
  }

  /// 加载打印机绑定配置：先与云端同步（换电脑/换账号自动拉取），再读本机缓存
  Future<void> _loadRoute() async {
    if (Session.hangye != 2) return;
    final wid = '${Session.wenxunId}';
    if (mounted) setState(() => cloudSyncing = true);
    final ok = await PrinterRoute.syncFromCloud(wid);
    final rf = await PrinterRoute.riceFrontOnly(wid);
    final pcs = await PrinterRoute.printerCfgs(wid);
    final kt = await PrinterRoute.kitchenTicketOpts(wid);
    final zf = await PrinterRoute.zuofaList(wid);
    if (!mounted) return;
    setState(() {
      riceFrontOnly = rf;
      printerCfgs = pcs;
      kitchenTicketOpts = kt;
      zuofaItems = zf;
      cloudSyncOk = ok;
      cloudSyncing = false;
    });
    // 商品分类（后厨绑定配置选择用）
    try {
      final c = await Api.goodsCats(Session.wenxunId);
      if (mounted) setState(() => cats = c);
    } on ApiError {
      // 分类加载失败不阻塞，仅提示无法分配
    }
  }

  Future<bool> _savePrinterCfg(String code, PrinterCfg cfg) async {
    final next = Map<String, PrinterCfg>.from(printerCfgs);
    if (cfg.role.isEmpty) {
      next.remove(code);
    } else {
      next[code] = cfg;
    }
    setState(() => printerCfgs = next);
    final ok = await PrinterRoute.setPrinterCfgs('${Session.wenxunId}', next);
    if (mounted) setState(() => cloudSyncOk = ok);
    return ok;
  }

  Future<void> _loadPrintPrefs() async {
    final m = <String, bool>{};
    final keys = <String>{for (final it in PrintPrefs.items) it['key']!};
    // 合并组的成员 key 也要加载（v3.3.137/139：如 booking），否则组开关显示不准
    for (final g in PrintPrefs.diningGroups) {
      keys.addAll(g['members']!.split(','));
    }
    for (final k in keys) {
      m[k] = await PrintPrefs.on(k);
    }
    if (mounted) setState(() => printOn = m);
  }

  /// 小票打印设置卡片（v3.3.78，v3.3.137 合并组化）：餐饮按组合并（同类小票一行），零售保持逐项
  Widget _printPrefsCard() {
    final rows = <Widget>[];

    void addHeader(String header) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Row(children: [
          Container(width: 3, height: 12, decoration: BoxDecoration(color: PosTheme.accent, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Text(header, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textMain)),
        ]),
      ));
    }

    Widget ticketRow({
      required String label,
      required String desc,
      required bool on,
      required String previewKey,
      String? settingsLabel,
      VoidCallback? onSettings,
      required Future<void> Function(bool) onToggle,
    }) {
      return Container(
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 7),
            Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: on ? PosTheme.textMain : PosTheme.textHint)),
            const SizedBox(height: 1),
            Text(desc, style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            const SizedBox(height: 7),
          ])),
          // 「设置」按钮：仅对有专属配置项的组显示（v3.3.136），点开弹窗逐项设置
          if (onSettings != null)
            TextButton.icon(
              onPressed: onSettings,
              style: TextButton.styleFrom(foregroundColor: PosTheme.accent, padding: const EdgeInsets.symmetric(horizontal: 8)),
              icon: const Icon(Icons.tune, size: 15),
              label: Text(settingsLabel ?? '设置'),
            ),
          TextButton.icon(
            onPressed: () => _previewTicket(previewKey, label),
            style: TextButton.styleFrom(foregroundColor: PosTheme.blue, padding: const EdgeInsets.symmetric(horizontal: 10)),
            icon: const Icon(Icons.visibility_outlined, size: 15),
            label: const Text('预览'),
          ),
          Switch(
            value: on,
            activeColor: PosTheme.accent,
            onChanged: (v) => onToggle(v),
          ),
        ]),
      );
    }

    if (Session.hangye == 2) {
      // 餐饮：同类小票合并为一组（v3.3.137），组开关整组生效，出票逻辑仍按单个 key 判断
      addHeader('餐饮小票');
      for (final g in PrintPrefs.diningGroups) {
        final members = g['members']!;
        final keys = members.split(',');
        final isKitchenGroup = keys.contains('kitchen');
        rows.add(ticketRow(
          label: g['label']!,
          desc: g['desc']!,
          on: keys.every((k) => printOn[k] ?? true),
          previewKey: g['preview']!,
          onSettings: isKitchenGroup ? () => _showKitchenDetailDialog(g['label']!) : null,
          onToggle: (v) async {
            setState(() {
              for (final k in keys) {
                printOn[k] = v;
              }
            });
            await PrintPrefs.setGroup(members, v);
          },
        ));
      }
      // 通用小票（餐饮版只显示交班单）
      addHeader('通用小票');
      for (final it in PrintPrefs.itemsForHangye(Session.hangye).where((x) => (x['scope'] ?? 'all') == 'all')) {
        final key = it['key']!;
        final on = printOn[key] ?? true;
        rows.add(ticketRow(
          label: it['label']!,
          desc: it['desc']!,
          on: on,
          previewKey: key,
          onToggle: (v) async {
            setState(() => printOn[key] = v);
            await PrintPrefs.set(key, v);
          },
        ));
      }
    } else {
      // 零售/生鲜：保持逐项设置
      String? lastScope;
      for (final it in PrintPrefs.itemsForHangye(Session.hangye)) {
        final scope = it['scope'] ?? 'all';
        if (scope != lastScope) {
          addHeader(switch (scope) {
            'retail' => '零售小票',
            _ => '通用小票',
          });
          lastScope = scope;
        }
        final key = it['key']!;
        final on = printOn[key] ?? true;
        rows.add(ticketRow(
          label: it['label']!,
          desc: it['desc']!,
          on: on,
          previewKey: key,
          onToggle: (v) async {
            setState(() => printOn[key] = v);
            await PrintPrefs.set(key, v);
          },
        ));
      }
    }
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.receipt_long_outlined, '小票打印设置'),
      const SizedBox(height: 4),
      Text(Session.hangye == 2
          ? '同类小票已合并为一组，整组控制「打印 / 不打印」；组内「设置」可逐项配置明细，云打印与 USB 直连同时生效。'
          : '按小票类型控制「打印 / 不打印」，云打印与 USB 直连同时生效。关闭后对应小票不再输出。',
          style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      const SizedBox(height: 10),
      ...rows,
    ]));
  }

  /// 常用做法卡片（v3.3.141，仅餐饮版）：商户自定义做法候选项，存云端随门店同步。
  /// 点餐长按菜品 / 账单行「做」按钮的弹窗候选项即此列表。
  Widget _zuofaCard() {
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.restaurant_menu, '常用做法'),
      const SizedBox(height: 4),
      Text('收银员点餐时点击菜品「做」字从候选项选择，做法随菜品打到后厨小票，后厨照单出餐。候选项在此自定义，设置随门店云端同步。',
          style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      const SizedBox(height: 10),
      if (!cloudSyncOk)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('上次云端同步失败（断网），当前仅本机生效，联网后会自动补传。',
              style: const TextStyle(fontSize: 11.5, color: PosTheme.red)),
        ),
      Wrap(
        spacing: 8, runSpacing: 8,
        children: zuofaItems.map((s) => Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: PosTheme.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(s, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: PosTheme.textMain)),
            const SizedBox(width: 6),
            InkWell(
              onTap: () => _zuofaRemove(s),
              borderRadius: BorderRadius.circular(20),
              child: const Icon(Icons.cancel_outlined, size: 17, color: PosTheme.textHint),
            ),
          ]),
        )).toList(),
      ),
      if (zuofaItems.isEmpty)
        Text('暂无做法候选项，可在下方添加（如：少辣、中辣、微辣）',
            style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
      const SizedBox(height: 14),
      Row(children: [
        SizedBox(
          width: 220,
          child: TextField(
            controller: zuofaCtrl,
            decoration: const InputDecoration(hintText: '输入做法名称，如：微辣', isDense: true),
            onSubmitted: (_) => _zuofaAdd(),
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: _zuofaAdd,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加'),
        ),
        const SizedBox(width: 10),
        TextButton(onPressed: _zuofaReset, child: const Text('恢复默认')),
      ]),
    ]));
  }

  Future<void> _zuofaSave(List<String> next) async {
    setState(() => zuofaItems = next);
    final ok = await PrinterRoute.setZuofaList('${Session.wenxunId}', next);
    if (mounted) setState(() => cloudSyncOk = ok);
    if (!ok) toast(context, '已在本机生效，云端同步失败（联网后会自动补传）', error: true);
  }

  Future<void> _zuofaAdd() async {
    final v = zuofaCtrl.text.trim();
    if (v.isEmpty) return;
    if (zuofaItems.contains(v)) {
      toast(context, '做法「$v」已存在');
      return;
    }
    if (zuofaItems.length >= 30) {
      toast(context, '做法候选项最多 30 个', error: true);
      return;
    }
    zuofaCtrl.clear();
    await _zuofaSave([...zuofaItems, v]);
  }

  Future<void> _zuofaRemove(String s) async {
    await _zuofaSave(zuofaItems.where((e) => e != s).toList());
  }

  Future<void> _zuofaReset() async {
    zuofaCtrl.clear();
    await _zuofaSave(List<String>.from(PrinterRoute.defaultZuofa));
  }

  /// 后厨单组 · 明细行开关弹窗（菜品行、做法备注必打无开关；存云端随门店同步）
  Future<void> _showKitchenDetailDialog(String label) async {
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        Widget opt(String k, String title, String desc) {
          final on = kitchenTicketOpts[k] ?? true;
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
            decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SizedBox(height: 7),
                Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600,
                    color: on ? PosTheme.textMain : PosTheme.textHint)),
                Text(desc, style: const TextStyle(fontSize: 11, color: PosTheme.textHint)),
                const SizedBox(height: 7),
              ])),
              Switch(
                value: on,
                activeColor: PosTheme.accent,
                onChanged: (v) async {
                  setD(() {
                    final next = Map<String, bool>.from(kitchenTicketOpts);
                    next[k] = v;
                    kitchenTicketOpts = next;
                  });
                  final ok = await PrinterRoute.setKitchenTicketOpts('${Session.wenxunId}', kitchenTicketOpts);
                  if (mounted) {
                    setState(() => cloudSyncOk = ok);
                    if (!ok) toast(context, '已在本机生效，云端同步失败（联网后会自动补传）', error: true);
                  }
                },
              ),
            ]),
          );
        }

        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
          title: Text('$label · 明细行设置', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('菜品行、做法备注必打（无开关）；以下各行按需开关，设置随门店云端同步。',
                  style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              const SizedBox(height: 10),
              opt('table', '桌台行', '如「桌台: 茶楼3 (茶楼)」'),
              opt('time', '时间行', '如下单时间'),
              opt('staff', '点单人行', '如「点单: 张三」'),
              opt('count', '合计件数行', '如「合计件数: 4」'),
              opt('merge', '同名菜品合并', '同一菜加 N 份只打一张「xN」省纸；关闭则每份一张'),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('完成', style: TextStyle(color: PosTheme.accent, fontWeight: FontWeight.w600)),
            ),
          ],
        );
      }),
    );
  }

  /// 生成各类小票的示例内容（预览 / 测试打印共用）
  /// 某角色（front/kitchen）已绑定机的字体设置，供小票预览按真实配置呈现（v3.3.127）
  String _fontOfRole(String role) {
    for (final c in printerCfgs.values) {
      if (c.role == role) return c.font;
    }
    return '';
  }

  String _sampleTicket(String key) {
    final now = DateTime.now().toString().substring(0, 19);
    switch (key) {
      case 'retail':
        return CloudPrinter.retailReceipt(orderNo: 'DD$now示例', payMethod: '微信支付', total: 58,
          cart: [
            {'name': '示例商品 A', 'price': '18.00', 'quantity': 2},
            {'name': '示例商品 B', 'price': '22.00', 'quantity': 1},
          ]);
      case 'dining':
        return CloudPrinter.diningReceipt(orderSn: 'DD$now示例', tableTitle: '大厅8', peopleNum: 4,
          payMethod: '微信支付', goodsTotal: 128.00, finalTotal: 118.00,
          cart: [
            {'goods_name': '水煮牛肉', 'unit_price': '58.00', 'quantity': 1, 'remark': '少辣'},
            {'goods_name': '米饭', 'unit_price': '2.00', 'quantity': 4},
          ],
          extraLines: ['茶位费: ¥4.00', '整单折扣: 9.5 折', '抹零: -¥0.50']);
      case 'kitchen':
        return CloudPrinter.kitchenTicket(tableTitle: '大厅8', tableQuyu: '大厅', isAdd: true, cart: [
          {'goods_name': '水煮牛肉', 'quantity': 1, 'remark': '少辣'},
          {'goods_name': '米饭', 'quantity': 4},
        ], font: _fontOfRole('kitchen'),
          showTable: kitchenTicketOpts['table'] ?? true, showTime: kitchenTicketOpts['time'] ?? true,
          showStaff: kitchenTicketOpts['staff'] ?? true, showCount: kitchenTicketOpts['count'] ?? true);
      case 'front':
        return CloudPrinter.kitchenTicket(tableTitle: '大厅8', tableQuyu: '大厅', cart: [
          {'goods_name': '水煮牛肉', 'quantity': 1, 'remark': '少辣'},
          {'goods_name': '清蒸鲈鱼', 'quantity': 1},
          {'goods_name': '米饭', 'quantity': 4},
        ], title: '前台单', font: _fontOfRole('front'));
      case 'prebill':
        return CloudPrinter.prebillTicket(tableTitle: '大厅8', peopleNum: 4, goodsTotal: 128.00, cart: [
          {'goods_name': '水煮牛肉', 'unit_price': '58.00', 'quantity': 1, 'remark': '少辣'},
          {'goods_name': '米饭', 'unit_price': '2.00', 'quantity': 4},
        ], extraLines: ['茶位费: ¥4.00'], font: _fontOfRole('front'));
      case 'reorder':
        // 订单补打小票：从已结算堂食订单行重组（含附加费/优惠明细）
        return CloudPrinter.diningReprintTicket({
          'order_sn': 'CT$now示例',
          'table_title': '大厅8',
          'people_num': 4,
          'create_time': now,
          'goods_list': [
            {'goods_title': '水煮牛肉', 'unit_price': '58.00', 'quantity': 1, 'remark': '少辣'},
            {'goods_title': '米饭', 'unit_price': '2.00', 'quantity': 4},
          ],
          'goods_total': '66.00',
          'kaitai_fee': '10.00',
          'tea_fee': '4.00',
          'discount_amount': '6.60',
          'quiling': '0.40',
          'final_total': '73.00',
          'pay1_type': '微信支付',
          'order_remark': '不要香菜',
        });
      case 'retreat':
        return CloudPrinter.kitchenTicket(tableTitle: '大厅8', tableQuyu: '大厅',
          cart: const [{'goods_name': '水煮牛肉', 'quantity': 1}], title: '退菜单', font: _fontOfRole('kitchen'),
          showTable: kitchenTicketOpts['table'] ?? true, showTime: kitchenTicketOpts['time'] ?? true,
          showStaff: kitchenTicketOpts['staff'] ?? true, showCount: kitchenTicketOpts['count'] ?? true);
      case 'urge':
        return CloudPrinter.kitchenTicket(tableTitle: '大厅8', tableQuyu: '大厅',
          cart: const [{'goods_name': '清蒸鲈鱼', 'quantity': 1}], title: '催菜单', font: _fontOfRole('kitchen'),
          showTable: kitchenTicketOpts['table'] ?? true, showTime: kitchenTicketOpts['time'] ?? true,
          showStaff: kitchenTicketOpts['staff'] ?? true, showCount: kitchenTicketOpts['count'] ?? true);
      case 'reprint':
        return CloudPrinter.kitchenTicket(tableTitle: '大厅8', tableQuyu: '大厅',
          cart: const [{'goods_name': '水煮牛肉', 'quantity': 1}, {'goods_name': '米饭', 'quantity': 4}], title: '后厨单重打', font: _fontOfRole('kitchen'),
          showTable: kitchenTicketOpts['table'] ?? true, showTime: kitchenTicketOpts['time'] ?? true,
          showStaff: kitchenTicketOpts['staff'] ?? true, showCount: kitchenTicketOpts['count'] ?? true);
      case 'queue':
        return '<FS2><center>排队号</center></FS2>\n--------------------------------\n您的号码：\n<FS2><center>** 12 **</center></FS2>\n2 位 · 前方 3 桌\n时间: $now\n请留意叫号，过号重排\n';
      case 'booking':
        // 预约单样票（v3.3.139）：顾客扫码提交预约后自动/手动出单备菜核对
        return CloudPrinter.preorderTicket(
          name: '漫满Love糊™',
          phone: '18200192012',
          peopleNum: 4,
          arriveTime: '今天 12:00',
          createTime: now,
          remark: '靠窗位置',
          items: const [
            {'goods_name': '麻婆豆腐', 'unit_price': '5.00', 'quantity': 1, 'sub_total': '5.00'},
            {'goods_name': '土豆丝', 'unit_price': '8.00', 'quantity': 1, 'sub_total': '8.00'},
            {'goods_name': '海带汤', 'unit_price': '9.00', 'quantity': 1, 'sub_total': '9.00'},
            {'goods_name': '紫菜蛋花汤', 'unit_price': '9.00', 'quantity': 1, 'sub_total': '9.00'},
          ],
          total: 31.00,
        );
      case 'shift':
        return CloudPrinter.shiftReceipt(zongyingye: 3268.50, bishu: 42, vip: 860.00, xianjin: 1208.50, saoma: 1200.00, refundAmount: 66.00, refundCount: 1);
      case 'order':
        return CloudPrinter.orderTicket({
          'order_number': 'SO$now示例', 'create_time': now, 'cashier_name': Session.staffName,
          'goods_list': [
            {'title': '示例商品 A', 'price': '18.00', 'quantity': 2},
            {'title': '示例商品 B', 'price': '22.00', 'quantity': 1},
          ],
          'total': '58.00', 'payment_method': '微信支付',
        });
      case 'refund':
        return CloudPrinter.orderTicket({
          'order_number': 'SO$now示例', 'create_time': now, 'cashier_name': Session.staffName,
          'goods_list': [
            {'title': '示例商品 A', 'price': '18.00', 'quantity': 2},
          ],
          'refund_amount': '36.00', 'payment_method': '微信支付', 'refund_reason': '客人不想要了',
        }, isRefund: true);
      case 'vipcz':
        return CloudPrinter.vipRechargeTicket(
          vipName: '示例会员', phone: '138****8888', orderSn: 'CZ$now示例',
          amount: 100, gift: 10, payMethod: '扫码支付', balance: 258);
      case 'vipczrefund':
        return CloudPrinter.vipRechargeTicket(
          vipName: '示例会员', phone: '138****8888', orderSn: 'CZ$now示例',
          amount: 100, gift: 10, payMethod: '现金（线下退回）',
          balance: 158, refund: true, reason: '顾客要求退款');
      default:
        return '';
    }
  }

  Future<void> _previewTicket(String key, String label) async {
    final content = _sampleTicket(key);
    if (content.isEmpty) return;
    await showDialog(context: context, builder: (_) => ReceiptPreviewDialog(title: label, content: content));
  }

  Future<void> _loadStaffs() async {
    if (Session.isCashierOnly) return; // 收银员登录不显示权限密码管理
    setState(() => staffLoading = true);
    try {
      final list = await Api.staffList();
      if (mounted) {
        setState(() {
          staffs = list.cast<Map<String, dynamic>>();
          staffLoading = false;
        });
      }
    } on ApiError {
      if (mounted) setState(() => staffLoading = false);
    }
  }

  /// 权限密码卡片（仅商户登录可见）：
  /// 为每个收银员分配 6 位数字权限密码（现金订单退款 / 现金充值时输入）
  Widget _refundPwdCard() {
    if (Session.isCashierOnly) return const SizedBox.shrink();
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.lock_outline, '权限密码（退款 / 现金充值）'),
      const SizedBox(height: 4),
      Text('收银员执行「订单退款」或「现金充值」时需输入权限密码。由商户在此分配，收银员本人不可修改。',
          style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      const SizedBox(height: 12),
      if (staffLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Center(child: SizedBox(
            width: 22, height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: PosTheme.accent),
          )),
        )
      else if (staffs.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('暂无收银员，请先在「收银员管理」中添加',
              style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
        )
      else
        ...staffs.map(_staffPwdRow),
    ]));
  }

  Widget _staffPwdRow(Map<String, dynamic> s) {
    final set = s['has_quanxian'] == true;
    final name = '${s['renyuan'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: PosTheme.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosTheme.line),
      ),
      child: Row(children: [
        Container(
          width: 34, height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: PosTheme.accent.withOpacity(0.1),
            borderRadius: BorderRadius.circular(17),
          ),
          child: Text(name.isEmpty ? '?' : name.characters.first,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: PosTheme.accent)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 1),
          Text('${s['role_name'] ?? ''} · ${s['phone'] ?? ''}',
              style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: set ? const Color(0xFFEAF7EE) : const Color(0xFFFDF3E7),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(set ? '已设置' : '未设置',
              style: TextStyle(fontSize: 11,
                  color: set ? const Color(0xFF2E9E5B) : const Color(0xFFD07B1F),
                  fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 92,
          child: BigButton(set ? '修改' : '设置密码', onTap: () => _editStaffPwd(s),
              color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 40),
        ),
      ]),
    );
  }

  /// 设置/修改某收银员的权限密码（商户操作）
  Future<void> _editStaffPwd(Map<String, dynamic> s) async {
    final name = '${s['renyuan'] ?? ''}';
    final pwdCtl = TextEditingController();
    final pwd2Ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('设置权限密码 · $name', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('该收银员执行「订单退款」「现金充值」时需输入此密码。',
                style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
            const SizedBox(height: 14),
            TextField(
              controller: pwdCtl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(fontSize: 18, letterSpacing: 6, fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                counterText: '',
                labelText: '权限密码（6位数字）',
                prefixIcon: Icon(Icons.lock_outline, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pwd2Ctl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(fontSize: 18, letterSpacing: 6, fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                counterText: '',
                labelText: '确认密码',
                prefixIcon: Icon(Icons.lock, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('确认设置')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final pwd = pwdCtl.text.trim();
    if (pwd.length != 6 || int.tryParse(pwd) == null) {
      toast(context, '权限密码须为6位数字', error: true);
      return;
    }
    if (pwd != pwd2Ctl.text.trim()) {
      toast(context, '两次输入的密码不一致', error: true);
      return;
    }
    loadingDialog(context, '保存中…');
    try {
      final r = await Api.setStaffQuanxian(staffId: int.tryParse('${s['id']}') ?? 0, password: pwd);
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        toast(context, '$name 的权限密码已更新');
        _loadStaffs();
      } else {
        toast(context, '${r['msg'] ?? '保存失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, e.message, error: true);
    }
  }

  /// 单台云打印机绑定配置弹窗（v3.3.124，仅餐饮版）：
  /// 出票角色（前台单/后厨单/不参与）+ 每台独立的出票方式 + 后厨分类分工 + 兜底双打
  Future<void> _showPrinterCfgDialog(Map p) async {
    final code = '${p['machine_code']}';
    final old = printerCfgs[code];
    var cfg = PrinterCfg(
      role: old?.role ?? '',
      mode: old?.mode ?? 'whole',
      cats: List<String>.from(old?.cats ?? const <String>[]),
      allCats: old?.allCats ?? false,
      font: old?.font ?? '',
    );
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        Widget modeOpt(String value, String label, String desc) {
          final sel = cfg.mode == value;
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setD(() => cfg.mode = value),
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: sel ? PosTheme.accent.withOpacity(0.08) : const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: sel ? PosTheme.accent : PosTheme.line, width: sel ? 1.5 : 1),
              ),
              child: Row(children: [
                Icon(sel ? Icons.radio_button_checked : Icons.radio_button_off,
                    size: 17, color: sel ? PosTheme.accent : PosTheme.textHint),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: sel ? PosTheme.accent : PosTheme.textMain)),
                  Text(desc, style: const TextStyle(fontSize: 11, color: PosTheme.textHint)),
                ])),
              ]),
            ),
          );
        }
        Widget roleOpt(String value, String label, String desc, IconData icon, Color color) {
          final sel = cfg.role == value;
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setD(() => cfg.role = value),
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: sel ? color.withOpacity(0.08) : const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: sel ? color : PosTheme.line, width: sel ? 1.5 : 1),
              ),
              child: Row(children: [
                Icon(icon, size: 18, color: sel ? color : PosTheme.textHint),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: sel ? color : PosTheme.textMain)),
                  Text(desc, style: const TextStyle(fontSize: 11, color: PosTheme.textHint)),
                ])),
                Icon(sel ? Icons.check_circle : Icons.radio_button_off,
                    size: 18, color: sel ? color : PosTheme.textHint),
              ]),
            ),
          );
        }
        Widget fontOpt(String value, String label, String desc) {
          final sel = cfg.font == value;
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setD(() => cfg.font = value),
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: sel ? PosTheme.accent.withOpacity(0.08) : const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: sel ? PosTheme.accent : PosTheme.line, width: sel ? 1.5 : 1),
              ),
              child: Row(children: [
                SizedBox(
                  width: 110,
                  child: Text(label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: value == 'fs2' ? 16 : value == 'fs' ? 14 : 12.5,
                        fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                        color: sel ? PosTheme.accent : PosTheme.textMain,
                      )),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(desc, style: const TextStyle(fontSize: 11, color: PosTheme.textHint))),
                Icon(sel ? Icons.check_circle : Icons.radio_button_off,
                    size: 18, color: sel ? PosTheme.accent : PosTheme.textHint),
              ]),
            ),
          );
        }
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            const Icon(Icons.tune, size: 19, color: PosTheme.accent),
            const SizedBox(width: 8),
            Expanded(child: Text('绑定打印机 · ${p['name']}', style: const TextStyle(fontSize: 15.5))),
          ]),
          content: SizedBox(
            width: 430,
            child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('出票角色', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              roleOpt('', '不参与点餐出票', '仅做收银小票/交班单等默认用途', Icons.block, PosTheme.textHint),
              roleOpt('front', '前台单', '顾客点单/加菜的前台回执', Icons.storefront, PosTheme.blue),
              roleOpt('kitchen', '后厨单', '按分类出菜票，传后厨时自动出', Icons.restaurant, PosTheme.accent),
              if (cfg.role.isNotEmpty) ...[
                const SizedBox(height: 6),
                const Text('出票方式', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (cfg.role == 'front') ...[
                  modeOpt('whole', '主单一张', '整桌全部商品合并打在一张小票上'),
                  modeOpt('split', '分单', '每道商品各打一张小票'),
                ] else ...[
                  modeOpt('whole', '整单打印', '本机负责的菜合并打一张小票'),
                  modeOpt('split', '一菜一切', '每个菜品单独打一张小票，方便分拣'),
                ],
              ],
              if (cfg.role.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(cfg.role == 'kitchen' ? '字体大小（菜名/做法/合计行）' : '字体大小（菜名/合计行, 方便顾客核对）',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                fontOpt('', '标准', '默认字号，一页能放下更多菜品'),
                fontOpt('fs', '加大', '菜名放大一档（高32），看得更清楚'),
                fontOpt('fs2', '特大', '菜名两倍大（高48），最醒目；每页菜品会变少'),
              ],
              if (cfg.role == 'kitchen') ...[
                const SizedBox(height: 6),
                const Text('负责分类（可多台分工；同分类绑多台=双打备份）',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (cats.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('暂无商品分类，请先在商品管理中创建分类',
                        style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
                  )
                else
                  Wrap(spacing: 8, runSpacing: 8, children: cats.map((c) {
                    final cid = '${c['id']}';
                    final sel = cfg.cats.contains(cid);
                    return FilterChip(
                      label: Text('${c['title'] ?? c['name'] ?? cid}',
                          style: TextStyle(fontSize: 12.5, color: sel ? Colors.white : PosTheme.textSub)),
                      selected: sel,
                      selectedColor: PosTheme.accent,
                      checkmarkColor: Colors.white,
                      backgroundColor: Colors.white,
                      side: BorderSide(color: sel ? PosTheme.accent : PosTheme.line),
                      showCheckmark: false,
                      onSelected: (v) => setD(() {
                        if (v) {
                          cfg.cats.add(cid);
                        } else {
                          cfg.cats.remove(cid);
                        }
                      }),
                    );
                  }).toList()),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
                  child: Row(children: [
                    const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(height: 8),
                      Text('接收未分配分类', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      SizedBox(height: 2),
                      Text('没分到分类的菜，本机也打一份（多台开启则每台各打一份）',
                          style: TextStyle(fontSize: 11, color: PosTheme.textHint)),
                      SizedBox(height: 8),
                    ])),
                    Switch(
                      value: cfg.allCats,
                      activeColor: PosTheme.accent,
                      onChanged: (v) => setD(() => cfg.allCats = v),
                    ),
                  ]),
                ),
              ],
            ])),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: PosTheme.accent),
              onPressed: () async {
                Navigator.pop(ctx);
                final ok = await _savePrinterCfg(code, cfg);
                if (!mounted) return;
                final base = cfg.role.isEmpty ? '已解绑「${p['name']}」' : '「${p['name']}」已绑定为${cfg.role == 'front' ? '前台单' : '后厨单'}';
                toast(context, ok ? '$base · 已云端同步' : '$base（云端同步失败，仅本机生效）', error: !ok);
              },
              child: const Text('保存'),
            ),
          ],
        );
      }),
    );
  }

  /// 打印机绑定角标文案（v3.3.124）：云打印机列表行显示
  String _cfgRoleLabel(String code) {
    final c = printerCfgs[code];
    if (c == null || c.role.isEmpty) return '';
    return c.role == 'front' ? '前台单' : '后厨单';
  }

  String _cfgSummary(String code) {
    final c = printerCfgs[code];
    if (c == null || c.role.isEmpty) return '';
    final mode = c.mode == 'split'
        ? (c.role == 'kitchen' ? '一菜一切' : '分单')
        : (c.role == 'kitchen' ? '整单' : '主单一张');
    if (c.role == 'kitchen') {
      final n = c.cats.length;
      final bits = <String>[mode];
      bits.add(n > 0 ? '$n 个分类' : '未分配分类');
      if (c.allCats) bits.add('兜底双打');
      if (c.font == 'fs') bits.add('加大字');
      if (c.font == 'fs2') bits.add('特大字');
      return bits.join(' · ');
    }
    // 前台单（v3.3.127）：主单一张/分单 + 字体
    if (c.font == 'fs') return '$mode · 加大字';
    if (c.font == 'fs2') return '$mode · 特大字';
    return mode;
  }

  Future<void> _loadVoice() async {
    final v = await VoiceService.instance.enabled();
    setState(() => voiceEnabled = v);
  }

  /// 语音播报卡片：收款成功时播报「微信收款X元Y角」
  Widget _voiceCard() {
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.volume_up_outlined, '语音播报'),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 8),
            Text('收款成功语音播报', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 2),
            Text('开启后收款成功时自动播报支付方式和金额，如「微信收款，8元8角」（系统离线语音，无需联网）',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 8),
          ])),
          Switch(
            value: voiceEnabled,
            activeColor: PosTheme.accent,
            onChanged: (v) async {
              setState(() => voiceEnabled = v);
              await VoiceService.instance.setEnabled(v);
              if (v) {
                await VoiceService.instance.pay('微信', 8.80);
              }
            },
          ),
        ]),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton.icon(
          onPressed: () async {
            await VoiceService.instance.setEnabled(true);
            await VoiceService.instance.pay('微信', 8.80);
            if (!voiceEnabled) setState(() => voiceEnabled = true);
          },
          style: OutlinedButton.styleFrom(foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
          icon: const Icon(Icons.play_circle_outline, size: 16),
          label: const Text('试听'),
        ),
      ),
    ]));
  }

  /// 读取云打印总开关（v3.3.157）
  Future<void> _loadCloudOn() async {
    final on = await CloudPrinter.enabled();
    if (!mounted) return;
    setState(() => cloudEnabled = on);
  }

  Future<void> _loadUsb() async {
    if (!UsbPrinter.supported) return;
    final sp = await SharedPreferences.getInstance();
    setState(() {
      usbEnabled = sp.getBool(UsbPrinter.prefEnabled) ?? false;
      usbPaper = sp.getInt(UsbPrinter.prefPaper) ?? 58;
      usbSpec = sp.getString(UsbPrinter.prefSpec) ??
          ((usbPaper >= 80) ? 'pos80' : 'pos58');
      usbMode = sp.getString(UsbPrinter.prefMode) ?? 'auto';
      final raw = sp.getString(UsbPrinter.prefPrinter);
      usbSelected = (raw == null || raw.isEmpty)
          ? null
          : () {
              try {
                return jsonDecode(raw) as Map<String, dynamic>;
              } catch (_) {
                return null;
              }
            }();
    });
    await _refreshUsb();
    await _loadSpecCfgs();
  }

  /// 读取四个规格的自定义配置（页宽/微调，v3.3.159）
  Future<void> _loadSpecCfgs() async {
    final m = <String, Map<String, double>>{};
    for (final k in const ['pos58', 'pos80', 'dot', 'a4']) {
      m[k] = await UsbPrinter.loadSpecCfg(k);
    }
    if (!mounted) return;
    setState(() => usbCfgs = m);
  }

  Future<void> _refreshUsb() async {
    if (!UsbPrinter.supported) return;
    setState(() => usbLoading = true);
    try {
      final list = await UsbPrinter.list();
      if (!mounted) return;
      setState(() {
        usbPrinters = list;
        usbLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => usbLoading = false);
    }
  }

  Future<void> _saveUsbPrefs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(UsbPrinter.prefEnabled, usbEnabled);
    await sp.setInt(UsbPrinter.prefPaper, usbPaper);
    await sp.setString(UsbPrinter.prefSpec, usbSpec);
    await sp.setString(UsbPrinter.prefMode, usbMode);
    await sp.setString(
        UsbPrinter.prefPrinter, usbSelected == null ? '' : jsonEncode(usbSelected));
  }

  Future<void> _pickUsbPrinter(Map<String, dynamic> p) async {
    // macOS 未建队列的 USB 设备先申请权限/建队列由打印时自动处理
    setState(() => usbSelected = p);
    await _saveUsbPrefs();
    if (mounted) toast(context, '已选择：${p['name']}');
  }

  Future<void> _usbTest() async {
    final sel = usbSelected;
    if (sel == null) {
      toast(context, '请先选择 USB 打印机', error: true);
      return;
    }
    if (Platform.isAndroid && (sel['hasPermission'] == false)) {
      final ok = await UsbPrinter.requestPermission(sel);
      if (!ok && mounted) {
        toast(context, '未获得 USB 权限', error: true);
        return;
      }
    }
    loadingDialog(context, '发送测试小票…');
    try {
      final spec = UsbPrinter.specOf(usbSpec);
      await UsbPrinter.printTicket(sel, _usbSampleTicket('${sel['name']}', '${spec['label']}'),
          paperWidth: spec['width'] as int,
          mode: spec['mode'] as String,
          textW: spec['textW'] as int?,
          offsetCols: spec['offsetCols'] as int? ?? 0);
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '测试小票已发送，出纸即为打印成功');
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, '打印失败：$e', error: true);
    }
  }

  // ==================== 蓝牙打印（v3.3.185） ====================

  Future<void> _loadBt() async {
    if (!BtPrinter.supported) return;
    final sp = await SharedPreferences.getInstance();
    setState(() {
      btEnabled = sp.getBool(BtPrinter.prefEnabled) ?? false;
      btSpec = sp.getString(BtPrinter.prefSpec) ?? 'pos58';
      final raw = sp.getString(BtPrinter.prefDevice);
      btSelected = (raw == null || raw.isEmpty)
          ? null
          : () {
              try {
                return jsonDecode(raw) as Map<String, dynamic>;
              } catch (_) {
                return null;
              }
            }();
    });
    await _refreshBt();
  }

  Future<void> _refreshBt() async {
    if (!BtPrinter.supported) return;
    setState(() => btLoading = true);
    try {
      final list = await BtPrinter.list();
      if (!mounted) return;
      setState(() {
        btDevices = list;
        btLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => btLoading = false);
    }
  }

  Future<void> _btScanPair() async {
    if (!Platform.isAndroid) return;
    // 先申请蓝牙运行时权限
    final ok = await BtPrinter.requestPermission();
    if (!ok && mounted) {
      toast(context, '未授权蓝牙权限，无法扫描', error: true);
      return;
    }
    setState(() => btScanning = true);
    try {
      final list = await BtPrinter.scan();
      if (!mounted) return;
      setState(() => btScanResults = list);
      if (list.isEmpty) toast(context, '没扫到蓝牙设备，请确认打印机处于可配对状态');
    } catch (e) {
      if (mounted) toast(context, '扫描失败：$e', error: true);
    } finally {
      if (mounted) setState(() => btScanning = false);
    }
  }

  Future<void> _btPairDevice(Map<String, dynamic> p) async {
    loadingDialog(context, '正在配对…');
    try {
      final ok = await BtPrinter.pair('${p['id']}');
      if (!mounted) return;
      Navigator.pop(context);
      if (ok) {
        toast(context, '配对成功');
        await _refreshBt();
      } else {
        toast(context, '配对未完成，请重试', error: true);
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '配对失败：$e', error: true);
    }
  }

  Future<void> _pickBtPrinter(Map<String, dynamic> p) async {
    setState(() => btSelected = p);
    await BtPrinter.selectDevice(p);
    if (mounted) toast(context, '已选择：${p['name']}');
  }

  Future<void> _btTest() async {
    final sel = btSelected;
    if (sel == null) {
      toast(context, '请先选择蓝牙打印机', error: true);
      return;
    }
    loadingDialog(context, '发送测试小票…');
    try {
      final spec = BtPrinter.specOf(btSpec);
      await BtPrinter.printTicket(sel, _usbSampleTicket('${sel['name']}', '${spec['label']}'),
          paperWidth: spec['width'] as int,
          textW: spec['textW'] as int?);
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '测试小票已发送，出纸即为打印成功');
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, '打印失败：$e', error: true);
    }
  }

  // ==================== 在线更新（v3.3.79） ====================

  /// 功能设置卡片（v3.3.187，参考稳讯另一套收银系统的功能设置）
  Future<void> _loadFunc() async {
    final on = await SearchFocus.enabled();
    final side = await CartSide.side();
    if (!mounted) return;
    setState(() {
      searchFocusOn = on;
      cartSide = side;
    });
  }

  Widget _funcCard() {
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle(Icons.tune_outlined, '功能设置'),
      ]),
      const SizedBox(height: 4),
      // 搜索框始终聚焦
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 10),
            Text('搜索框始终聚焦', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 3),
            Text('开启后，零售/生鲜/堂食收银页的商品搜索框始终保持聚焦：扫码枪扫商品条码直接进搜索框，点选商品后焦点自动回到搜索框，无需先点输入框。关闭后正常点选输入。',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 10),
          ])),
          Switch(
            value: searchFocusOn,
            activeColor: PosTheme.accent,
            onChanged: (v) async {
              setState(() => searchFocusOn = v);
              await SearchFocus.setEnabled(v);
            },
          ),
        ]),
      ),
      const SizedBox(height: 8),
      // 购物车显示位置（v3.3.189）
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 10),
            Text('购物车显示位置', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 3),
            Text('零售收银页购物车面板显示在右侧（默认）还是左侧，按操作习惯选择，切换页面后生效。',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 10),
          ])),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'right', label: Text('右侧', style: TextStyle(fontSize: 13))),
              ButtonSegment(value: 'left', label: Text('左侧', style: TextStyle(fontSize: 13))),
            ],
            selected: {cartSide},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: PosTheme.accentLive,
              selectedForegroundColor: Colors.white,
              foregroundColor: PosTheme.textSub,
            ),
            onSelectionChanged: (sel) async {
              final v = sel.first;
              setState(() => cartSide = v);
              await CartSide.setSide(v);
            },
          ),
        ]),
      ),
      const SizedBox(height: 8),
      // 清空购物车需权限码（v3.3.192）
      const _ClearPinRow(),
      const SizedBox(height: 8),
      // 单个商品改价需权限码（v3.3.205）
      const _PricePinRow(),
      const SizedBox(height: 8),
      const Text('提示：适配扫码枪扫码搜商品场景。开启后如果同时使用键盘快捷操作，输入会优先进入搜索框。',
          style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
    ]));
  }

  /// 显示设置卡片（v3.3.193）：整体字体缩放 / 商品字体 / 商品每行显示个数
  /// 全部自定义，适配不同商户的屏幕与视力需求；改动即时生效，本机保存。
  Widget _displayCard() {
    final isDefault = DisplayPrefs.fontScale.value == 1.0 &&
        DisplayPrefs.fontWeight.value == 'normal' &&
        DisplayPrefs.goodsFont.value.isEmpty &&
        DisplayPrefs.goodsCols.value == 0 &&
        DisplayPrefs.goodsImage.value;
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle(Icons.format_size, '显示设置'),
        const Spacer(),
        if (!isDefault)
          TextButton.icon(
            onPressed: () async {
              await DisplayPrefs.resetAll();
              if (mounted) toast(context, '已恢复默认显示');
            },
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('恢复默认', style: TextStyle(fontSize: 13)),
          ),
      ]),
      const SizedBox(height: 4),
      const Text('按商户需求自定义界面显示：整体字体大小与粗细影响全软件文字；商品字体、商品图片开关、每行个数只影响零售收银页商品区。改动即时生效，保存在本机。',
          style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      const SizedBox(height: 10),
      // 0. 窗口模式 / 全屏（v3.3.209）：收银机铺满整屏，隐藏 Windows 标题栏与任务栏
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) ...[
        ValueListenableBuilder<bool>(
          valueListenable: WindowPrefs.fullscreen,
          builder: (context, full, __) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
            decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(height: 8),
                  Text('全屏模式（收银机）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  SizedBox(height: 2),
                  Text('隐藏 Windows 标题栏与任务栏，界面铺满整块屏幕；小屏收银机建议开启，快捷键 F11 切换',
                      style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                  SizedBox(height: 8),
                ]),
              ),
              Switch(
                value: full,
                activeColor: PosTheme.accent,
                onChanged: (v) async {
                  await WindowPrefs.setFullScreen(v);
                  if (mounted) toast(context, v ? '已进入全屏（F11 可退出）' : '已退出全屏');
                },
              ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
      ],
      // 1. 整体字体大小（0.8~1.4，5% 一档）
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 8),
          Row(children: [
            const Expanded(child: Text('整体字体大小', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: PosTheme.line)),
              child: Text('${(DisplayPrefs.fontScale.value * 100).round()}%',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: PosTheme.accentLive)),
            ),
          ]),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: PosTheme.accentLive,
              inactiveTrackColor: PosTheme.line,
              thumbColor: PosTheme.accentLive,
              overlayColor: PosTheme.accentLive.withValues(alpha: 0.12),
              trackHeight: 4,
              valueIndicatorColor: PosTheme.accentLive,
            ),
            child: Slider(
              value: DisplayPrefs.fontScale.value,
              min: 0.8, max: 1.4, divisions: 12, // 5% 一档：80%~140%
              label: '${(DisplayPrefs.fontScale.value * 100).round()}%',
              onChanged: (v) => DisplayPrefs.setFontScale(v),
            ),
          ),
          const Align(
            alignment: Alignment.centerRight,
            child: Text('80% —— 140%，默认 100%；与窗口自适应缩放叠加', style: TextStyle(fontSize: 11, color: PosTheme.textHint)),
          ),
          const SizedBox(height: 6),
        ]),
      ),
      const SizedBox(height: 8),
      // 1.5 字体粗细（细 / 正常 / 加粗，v3.3.193）
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 10),
            Text('字体粗细', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 3),
            Text('全软件文字笔画：细 / 正常 / 加粗（含按钮、输入框）。原来加粗的标题与金额保持加粗，老人看店可调粗更清楚。',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 10),
          ])),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'light', label: Text('细', style: TextStyle(fontSize: 13))),
              ButtonSegment(value: 'normal', label: Text('正常', style: TextStyle(fontSize: 13))),
              ButtonSegment(value: 'bold', label: Text('加粗', style: TextStyle(fontSize: 13))),
            ],
            selected: {DisplayPrefs.fontWeight.value},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: PosTheme.accentLive,
              selectedForegroundColor: Colors.white,
              foregroundColor: PosTheme.textSub,
            ),
            onSelectionChanged: (sel) => DisplayPrefs.setFontWeight(sel.first),
          ),
        ]),
      ),
      const SizedBox(height: 8),
      // 2. 商品字体大小（零售收银页商品卡片名称/价格）
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 10),
            Text('商品字体大小', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 3),
            Text('零售收银页商品卡片上的名称与价格字号，老人看店/大屏远看可调大。', style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 10),
          ])),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 's', label: Text('小', style: TextStyle(fontSize: 13))),
              ButtonSegment(value: '', label: Text('标准', style: TextStyle(fontSize: 13))),
              ButtonSegment(value: 'm', label: Text('大', style: TextStyle(fontSize: 13))),
              ButtonSegment(value: 'l', label: Text('特大', style: TextStyle(fontSize: 13))),
            ],
            selected: {DisplayPrefs.goodsFont.value},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: PosTheme.accentLive,
              selectedForegroundColor: Colors.white,
              foregroundColor: PosTheme.textSub,
            ),
            onSelectionChanged: (sel) => DisplayPrefs.setGoodsFont(sel.first),
          ),
        ]),
      ),
      const SizedBox(height: 8),
      // 2.5 商品图片（v3.3.196）：显示 / 不显示，不显示时用纯文字卡片
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 10),
            Text('商品图片', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 3),
            Text('不显示图片时，收银页商品卡改为纯文字样式（大字品名 + 价格 + 规格角标），'
                '一行能放更多商品，适合没上传图片或按名称点单的商户。', style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 10),
          ])),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('显示图片', style: TextStyle(fontSize: 13))),
              ButtonSegment(value: false, label: Text('不显示', style: TextStyle(fontSize: 13))),
            ],
            selected: {DisplayPrefs.goodsImage.value},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: PosTheme.accentLive,
              selectedForegroundColor: Colors.white,
              foregroundColor: PosTheme.textSub,
            ),
            onSelectionChanged: (sel) => DisplayPrefs.setGoodsImage(sel.first),
          ),
        ]),
      ),
      const SizedBox(height: 8),
      // 3. 商品图片每行显示个数（零售收银页商品网格）
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('商品图片每行显示个数', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          const Text('零售收银页商品区一行放几张图：「自动」按屏幕宽度自适应；固定个数适合大屏多列或触摸大卡片的需求。',
              style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _colOpt(0, '自动'),
            _colOpt(3, '3 个'),
            _colOpt(4, '4 个'),
            _colOpt(5, '5 个'),
            _colOpt(6, '6 个'),
            _colOpt(7, '7 个'),
            _colOpt(8, '8 个'),
          ]),
        ]),
      ),
    ]));
  }

  /// 主体风格（v3.3.194）：6 套渐变色配色方案，适配不同行业商户 / 新店开业
  /// v3.3.195：默认不启用配色，保持旧版默认外观；商户点选后才换色
  Widget _themeCard() {
    final cur = ThemePrefs.active;
    final on = ThemePrefs.hasSkin;
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle(Icons.palette_outlined, '主体风格'),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            gradient: on ? cur.linear : null,
            color: on ? null : const Color(0xFFF0F2F5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(on ? '当前：${cur.name}' : '未使用配色 · 默认外观',
              style: TextStyle(
                  fontSize: 12,
                  color: on ? Colors.white : PosTheme.textSub,
                  fontWeight: FontWeight.w700)),
        ),
      ]),
      const SizedBox(height: 4),
      const Text('默认不启用配色，界面保持原有外观；选任意一套方案才会换成对应渐变色'
          '（侧边栏、登录页品牌区、收款等主按钮、价格与选中态）。'
          '配色只影响界面外观，不影响商品、订单、打印与任何数据。改动即时生效，保存在本机。',
          style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      const SizedBox(height: 14),
      Wrap(spacing: 14, runSpacing: 14, children: ThemePrefs.skins.map(_skinTile).toList()),
      if (on)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              await ThemePrefs.clear();
              if (mounted) toast(context, '已取消配色，恢复默认外观');
            },
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('取消配色（恢复默认外观）', style: TextStyle(fontSize: 13)),
          ),
        ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lightbulb_outline, size: 16, color: PosTheme.amber),
          SizedBox(width: 8),
          Expanded(child: Text('新店开业推荐「开门红」（红金渐变，喜庆醒目）；生鲜果蔬推荐「生鲜绿」；便利店/数码推荐「海洋蓝」；'
              '奶茶/美妆推荐「紫罗兰」；烘焙/花店推荐「玫瑰金」；想统一成品牌橙选「稳讯橙」。'
              '不选则保持默认外观。',
              style: TextStyle(fontSize: 11.5, color: PosTheme.textSub, height: 1.5))),
        ]),
      ),
    ]));
  }

  /// 单套配色方案卡片（渐变预览 + 选中状态）
  Widget _skinTile(PosSkin s) {
    final on = ThemePrefs.hasSkin && ThemePrefs.skinId.value == s.id;
    return InkWell(
      onTap: () async {
        await ThemePrefs.set(s.id);
        if (mounted) toast(context, '已切换主体风格：${s.name}');
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 208,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: on ? s.accent : PosTheme.line, width: on ? 2 : 1),
          boxShadow: on
              ? [BoxShadow(color: s.accent.withValues(alpha: 0.18), blurRadius: 12, offset: const Offset(0, 4))]
              : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            height: 54,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(gradient: s.linear, borderRadius: BorderRadius.circular(10)),
            child: Stack(children: [
              Positioned(
                left: 0, bottom: 9,
                child: Text(s.name,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
              ),
              if (on)
                const Positioned(
                  right: 0, top: 8,
                  child: Icon(Icons.check_circle, color: Colors.white, size: 18),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          Text(s.desc,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
          const SizedBox(height: 8),
          Row(children: [
            _skinDot(s.accent),
            _skinDot(s.accentDeep),
            _skinDot(s.sidebar),
            const Spacer(),
            if (on)
              Text('使用中',
                  style: TextStyle(fontSize: 11.5, color: s.accent, fontWeight: FontWeight.w700)),
          ]),
        ]),
      ),
    );
  }

  Widget _skinDot(Color c) {
    return Container(
      width: 14, height: 14,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black12),
      ),
    );
  }

  /// 每行个数选项（自动=0）
  Widget _colOpt(int v, String label) {
    final on = DisplayPrefs.goodsCols.value == v;
    return InkWell(
      onTap: () => DisplayPrefs.setGoodsCols(v),
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: on ? PosTheme.accentLive : Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: on ? PosTheme.accentLive : PosTheme.line, width: on ? 1.5 : 1),
        ),
        child: Text(label, style: TextStyle(
            fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            color: on ? Colors.white : PosTheme.textMain)),
      ),
    );
  }

  /// 在线更新卡片：商户手动点击「检查更新」→ 有新版弹更新窗（下载/安装全程确认）
  /// 没点或没新版本什么都不发生；更新只替换程序文件，不丢数据
  Widget _updateCard() {
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle(Icons.system_update_alt, '在线更新'),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: const Color(0xFFF0F2F5), borderRadius: BorderRadius.circular(6)),
          child: Text('当前版本 v${Updater.curVersion.isEmpty ? '-' : Updater.curVersion}',
              style: const TextStyle(fontSize: 11.5, color: PosTheme.textSub)),
        ),
      ]),
      const SizedBox(height: 4),
      Text(Platform.isMacOS
          ? '检查到新版本后将引导前往 App Store 更新（macOS 版通过应用商店分发）。更新不影响本地配置与业务数据。'
          : '检查到新版本后由您确认下载安装。更新仅替换程序文件，不影响本地配置（云打印/USB打印/打印开关等）与业务数据（数据在服务器）。',
          style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      const SizedBox(height: 12),
      if (Updater.supported)
        SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: _checkUpdate,
          style: FilledButton.styleFrom(backgroundColor: PosTheme.accent, padding: const EdgeInsets.symmetric(vertical: 12)),
          icon: const Icon(Icons.search, size: 18),
          label: const Text('检查更新', style: TextStyle(fontWeight: FontWeight.w600)),
        ))
      else
        const Text('当前设备不支持在线更新（仅 Windows / macOS 桌面版支持）',
            style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
    ]));
  }

  Future<void> _checkUpdate() async {
    loadingDialog(context, '正在检查更新…');
    try {
      final info = await Updater.check();
      if (!mounted) return;
      Navigator.pop(context);
      if (info == null) {
        toast(context, '当前已是最新版本 v${Updater.curVersion}');
        return;
      }
      showDialog(context: context, barrierDismissible: false, builder: (_) => UpdateDialog(info: info));
    } on ApiError catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  Future<void> _load({bool syncStatus = true}) async {
    setState(() => loading = true);
    try {
      // 实时同步易联云在线/缺纸状态（v3.3.122）：逐台查 getprintstatus 并回写库，
      // 失败（网络/token）不阻塞，展示库里旧值
      if (syncStatus) {
        try {
          final fresh = await Api.printerStatusSync(Session.wenxunId);
          if (!mounted) return;
          if (fresh.isNotEmpty) {
            setState(() { printers = fresh; loading = false; });
            return;
          }
        } on ApiError {
          // 同步失败 → 落回读取本地库
        }
      }
      final p = await CloudPrinter.list();
      if (!mounted) return;
      setState(() { printers = p; loading = false; });
    } on ApiError {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  // ==================== 左右布局（v3.3.79）：左侧导航菜单 + 右侧内容 ====================
  String _nav = 'store';

  static const List<Map<String, Object>> _navDefs = [
    {'key': 'store',    'icon': Icons.storefront,           'label': '店铺信息'},
    {'key': 'activity', 'icon': Icons.campaign_outlined,    'label': '营销活动'},
    {'key': 'func',     'icon': Icons.tune_outlined,        'label': '功能设置'},
    {'key': 'display',  'icon': Icons.format_size,          'label': '显示设置'},
    {'key': 'cd',       'icon': Icons.desktop_windows_outlined, 'label': '副屏客显'},
    {'key': 'theme',    'icon': Icons.palette_outlined,     'label': '主体风格'},
    {'key': 'payorder', 'icon': Icons.low_priority,         'label': '支付方式排序'},
    {'key': 'update',   'icon': Icons.system_update_alt,    'label': '在线更新'},
    {'key': 'cloud',    'icon': Icons.print_outlined,       'label': '云打印机'},
    {'key': 'usb',      'icon': Icons.usb_outlined,         'label': 'USB打印'},
    {'key': 'bt',       'icon': Icons.bluetooth_outlined,   'label': '蓝牙打印'},
    {'key': 'drawer',   'icon': Icons.savings_outlined,     'label': '钱箱'},
    {'key': 'receipt',  'icon': Icons.receipt_long_outlined,'label': '小票打印设置'},
    {'key': 'zuofa',    'icon': Icons.restaurant_menu,      'label': '常用做法'},
    {'key': 'nocode',   'icon': Icons.bookmark_border,      'label': '无码商品常用'},
    {'key': 'scale',    'icon': Icons.scale_outlined,        'label': '称重设备'},
    {'key': 'voice',    'icon': Icons.volume_up_outlined,   'label': '语音播报'},
    {'key': 'password', 'icon': Icons.lock_outline,         'label': '权限密码'},
    {'key': 'account',  'icon': Icons.manage_accounts_outlined, 'label': '当前账号'},
    {'key': 'kefu',     'icon': Icons.support_agent,        'label': '联系客服'},
    {'key': 'about',    'icon': Icons.info_outline,         'label': '关于'},
  ];

  List<Map<String, Object>> get _visibleNavs {
    final list = <Map<String, Object>>[];
    for (final it in _navDefs) {
      if (it['key'] == 'password' && Session.isCashierOnly) continue; // 收银员不显示权限密码
      if (it['key'] == 'usb' && !UsbPrinter.supported) continue;      // 不支持 USB 的设备不显示
      if (it['key'] == 'bt' && !BtPrinter.supported) continue;        // 不支持蓝牙的设备不显示
      if (it['key'] == 'drawer' && !CashDrawer.supported) continue;   // 钱箱仅 Windows / Android
      if (it['key'] == 'zuofa' && Session.hangye != 2) continue;      // 常用做法仅餐饮版
      if (it['key'] == 'activity' && Session.hangye == 2) continue;   // 营销活动当前接入零售收银（v3.3.222）
      if (it['key'] == 'scale' && !ScaleSupport.canUseScale) continue; // 苹果端不接秤，只手输重量
      if (it['key'] == 'cd' && !(Platform.isWindows || Platform.isAndroid)) continue; // 副屏客显：Windows / 安卓（v3.3.212）
      list.add(it);
    }
    return list;
  }

  Widget _navContent(String key) {
    switch (key) {
      case 'activity': return const ActivityAdminCard();
      case 'update':  return _updateCard();
      case 'payorder':return _payOrderCard();
      case 'cloud':   return _cloudCard();
      case 'usb':     return _usbCard();
      case 'bt':      return _btCard();
      case 'drawer':  return _drawerCard();
      case 'receipt': return _printPrefsCard();
      case 'zuofa':   return _zuofaCard();
      case 'nocode':  return _noCodeCard();
      case 'scale':   return const _ScaleCard();
      case 'voice':   return _voiceCard();
      case 'password':return _refundPwdCard();
      case 'account': return _accountCard();
      case 'kefu':    return _kefuCard();
      case 'about':   return _aboutCard();
      case 'func':    return _funcCard();
      case 'display': return _displayCard();
      case 'cd':      return const _CdCard();
      case 'theme':   return _themeCard();
      case 'store':
      default:        return _storeCard();
    }
  }

  @override
  Widget build(BuildContext context) {
    final navs = _visibleNavs;
    if (!navs.any((n) => n['key'] == _nav)) _nav = '${navs.first['key']}'; // 兜底：当前选中被隐藏时回到第一项
    return Column(children: [
      PageHeader('设置'),
      Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ===== 左侧导航菜单 =====
        Container(
          width: 196,
          margin: const EdgeInsets.fromLTRB(20, 0, 0, 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: PosTheme.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 16, 18, 10),
              child: Text('设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: PosTheme.textMain)),
            ),
            Expanded(child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              children: navs.map((n) {
                final sel = n['key'] == _nav;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Material(
                    color: sel ? PosTheme.tint : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => setState(() => _nav = '${n['key']}'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                        child: Row(children: [
                          Icon(n['icon'] as IconData, size: 18,
                              color: sel ? PosTheme.accentLive : PosTheme.textSub),
                          const SizedBox(width: 10),
                          Expanded(child: Text('${n['label']}',
                              style: TextStyle(fontSize: 13.5,
                                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                                  color: sel ? PosTheme.accentLive : PosTheme.textMain))),
                        ]),
                      ),
                    ),
                  ),
                );
              }).toList(),
            )),
          ]),
        ),
        const SizedBox(width: 16),
        // ===== 右侧内容 =====
        Expanded(child: Container(
          margin: const EdgeInsets.fromLTRB(0, 0, 20, 20),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 4),
            child: _navContent(_nav),
          ),
        )),
      ])),
    ]);
  }

  /// 支付方式排序（v3.3.163）：结账弹窗展示顺序，上下箭头调整，即时保存
  Widget _payOrderCard() {
    final isDefault = PayMethods.isDefault(payOrder);
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle(Icons.low_priority, '支付方式排序'),
        const Spacer(),
        if (!isDefault)
          TextButton.icon(
            onPressed: () async {
              final d = List<String>.from(PayMethods.defaultOrder);
              setState(() => payOrder = d);
              await PayMethods.save(d);
            },
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('恢复默认', style: TextStyle(fontSize: 13)),
          ),
      ]),
      const SizedBox(height: 4),
      const Text('结账收款弹窗按此顺序展示支付方式，餐饮结账 / 零售生鲜收款 / 不开台 / 挂账核销全部复用同一排序。\n微信支付/支付宝点卡片即进入扫码枪收款，付款成功自动完成结账；现金/挂账/会员需收银员点「确认收款」。各场景只显示自己有的方式（如餐饮无「扫码收款/会员支付」、零售无「挂账」）。',
          style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      const SizedBox(height: 12),
      for (var i = 0; i < payOrder.length; i++) _payOrderRow(i),
    ]));
  }

  Widget _payOrderRow(int i) {
    final m = payOrder[i];
    final c = const {
      '微信支付': Color(0xFF07C160),
      '支付宝': Color(0xFF1677FF),
      '现金': Color(0xFF22B573),
      '扫码收款': PosTheme.blue,
      '挂账': Color(0xFFE4573D),
      '会员余额': PosTheme.accent,
      '会员支付': PosTheme.accent,
    }[m] ?? PosTheme.textSub;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosTheme.line),
      ),
      child: Row(children: [
        Container(
          width: 26, height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
          child: Text('${i + 1}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: c)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(m, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700))),
        // 上下移按钮（触屏大热区）
        _orderBtn(Icons.arrow_upward, i > 0, () async {
          final d = List<String>.from(payOrder);
          final t = d[i - 1]; d[i - 1] = d[i]; d[i] = t;
          setState(() => payOrder = d);
          await PayMethods.save(d);
        }),
        const SizedBox(width: 6),
        _orderBtn(Icons.arrow_downward, i < payOrder.length - 1, () async {
          final d = List<String>.from(payOrder);
          final t = d[i + 1]; d[i + 1] = d[i]; d[i] = t;
          setState(() => payOrder = d);
          await PayMethods.save(d);
        }),
      ]),
    );
  }

  Widget _orderBtn(IconData icon, bool enabled, VoidCallback onTap) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 38, height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? Colors.white : const Color(0xFFF2F3F7),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: enabled ? PosTheme.line : PosTheme.line.withOpacity(0.5)),
        ),
        child: Icon(icon, size: 17, color: enabled ? PosTheme.textMain : PosTheme.textHint.withOpacity(0.5)),
      ),
    );
  }

  Widget _storeCard() {
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.storefront, '店铺信息'),
      const SizedBox(height: 12),
      Row(children: [
        _info('店铺名称', Session.shopName),
        _info('行业版本', Session.hangye == 2 ? '餐饮版' : (Session.hangye == 3 ? '生鲜版（零售）' : '零售版')),
        _info('店铺电话', Session.shopPhone.isEmpty ? '-' : Session.shopPhone),
      ]),
    ]));
  }

  Widget _cloudCard() {
    final isDining = Session.hangye == 2; // 餐饮版才有前台/后厨绑定
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle(Icons.print_outlined, '云打印机'),
        const Spacer(),
        TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('刷新状态'),
        ),
      ]),
      if (isDining)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('点「配置」把打印机绑定为前台单/后厨单：可设出票方式（主单一张/分单/整单/一菜一切）、负责分类、兜底双打。',
              style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        ),
      // 云打印总开关（v3.3.157：与 USB 打印各自独立，商户自选打印 / 不打印）
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 8),
            Text('启用云打印', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 2),
            Text('关闭后所有小票都不再发往云打印机（USB 打印不受影响）',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 8),
          ])),
          Switch(
            value: cloudEnabled,
            activeColor: PosTheme.accent,
            onChanged: (v) async {
              setState(() => cloudEnabled = v);
              final sp = await SharedPreferences.getInstance();
              await sp.setBool(CloudPrinter.prefEnabled, v);
            },
          ),
        ]),
      ),
      if (isDining) _cloudSyncBar(),
      const SizedBox(height: 6),
      if (loading)
        const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(color: PosTheme.accent)))
      else if (printers.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text('尚未绑定云打印机。请联系管理员在商户后台添加（易联云终端号 + 密钥），添加后此处自动显示并支持状态监控。',
              style: TextStyle(fontSize: 13.5, color: PosTheme.textHint)),
        )
      else
        ...printers.map((p) {
          final code = '${p['machine_code']}';
          final role = isDining ? _cfgRoleLabel(code) : '';
          final summary = isDining ? _cfgSummary(code) : '';
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Container(width: 9, height: 9, decoration: BoxDecoration(
                  color: '${p['is_online']}' == '1' ? PosTheme.green : PosTheme.textHint, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text('${p['name']}', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600))),
                  if (role.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    TagChip(role, color: role == '前台单' ? PosTheme.blue : PosTheme.accent),
                  ],
                ]),
                const SizedBox(height: 2),
                Text('终端号 $code${_syncTimeSuffix(p)}',
                    style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
                if (summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text('出票：$summary', style: const TextStyle(fontSize: 11.5, color: PosTheme.accent)),
                  ),
              ])),
              TagChip('${p['is_online'] == 1 ? '在线' : '离线'}', color: '${p['is_online']}' == '1' ? PosTheme.green : PosTheme.textHint),
              const SizedBox(width: 8),
              TagChip('${p['has_paper'] == 1 ? '有纸' : '缺纸'}', color: '${p['has_paper']}' == '1' ? PosTheme.blue : PosTheme.red),
              const SizedBox(width: 8),
              if (isDining)
                OutlinedButton(
                  onPressed: () => _showPrinterCfgDialog(p),
                  style: OutlinedButton.styleFrom(foregroundColor: PosTheme.blue, side: const BorderSide(color: PosTheme.blue)),
                  child: Text(role.isEmpty ? '配置' : '修改'),
                ),
            ]),
          );
        }),
      if (isDining)
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
          decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(height: 8),
              Text('米饭只打前台单', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              SizedBox(height: 2),
              Text('开启后米饭等主食不出后厨票，只在前台单打印（名称含「米饭」的菜品均不进后厨）',
                  style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              SizedBox(height: 8),
            ])),
            Switch(
              value: riceFrontOnly,
              activeColor: PosTheme.accent,
              onChanged: (v) async {
                setState(() => riceFrontOnly = v);
                final ok = await PrinterRoute.setRiceFrontOnly('${Session.wenxunId}', v);
                if (!mounted) return;
                setState(() => cloudSyncOk = ok);
                if (!ok) toast(context, '已在本机生效，云端同步失败（联网后请再切换一次）', error: true);
              },
            ),
          ]),
        ),
    ]));
  }

  /// 云端同步状态条（v3.3.125）：换电脑/换账号登录后配置自动跟随
  Widget _cloudSyncBar() {
    final Color c = cloudSyncOk ? PosTheme.green : PosTheme.amber;
    final String text = cloudSyncing
        ? '正在从云端同步打印机配置…'
        : cloudSyncOk
            ? '配置已云端同步：换电脑或换收银员账号登录自动生效'
            : '云端同步失败，当前配置仅本机生效（点此重试）';
    return GestureDetector(
      onTap: cloudSyncing ? null : () => _loadRoute(),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: c.withOpacity(0.07), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          if (cloudSyncing)
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.8, color: PosTheme.accent))
          else
            Icon(cloudSyncOk ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, size: 14, color: c),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(fontSize: 11.5, color: c))),
          if (!cloudSyncing && !cloudSyncOk)
            Icon(Icons.refresh, size: 13, color: c),
        ]),
      ),
    );
  }

  /// 状态同步时间后缀（v3.3.122）：显示易联云实时查询的完成时间
  String _syncTimeSuffix(Map p) {
    final t = '${p['last_status_time'] ?? ''}';
    if (t.length < 16 || t.startsWith('1970') || t.startsWith('0000')) return '';
    return ' · 状态同步 ${t.substring(11, 16)}';
  }

  Widget _accountCard() {
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.manage_accounts_outlined, '当前账号'),
      const SizedBox(height: 12),
      Row(children: [
        _info('收银员', Session.staffName),
        _info('角色', Session.roleName),
        _info('添加会员权限', Session.vipadd ? '允许' : '禁止'),
      ]),
      const SizedBox(height: 16),
      SizedBox(
        width: 160,
        child: BigButton('退出登录', onTap: () async {
          final ok = await confirm(context, '退出登录', '确定退出当前收银员账号？');
          if (ok && context.mounted) {
            await Session.clear();
            Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginPage()));
          }
        }, color: PosTheme.red, height: 46),
      ),
    ]));
  }

  Widget _kefuCard() {
    // v3.3.81：客服从左侧栏移入设置页（KefuCard 抽为公开组件）
    return Column(children: [
      const KefuCard(),
      const SizedBox(height: 18),
      const Text('工作时间 9:00 - 22:00，扫码后由企业微信客服一对一解答',
          style: TextStyle(fontSize: 13, color: PosTheme.textHint)),
    ]);
  }

  Widget _aboutCard() {
    final ver = Updater.curVersion.isEmpty ? '3.0.0' : Updater.curVersion;
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.info_outline, '关于'),
      const SizedBox(height: 10),
      Text('稳讯收银 桌面版 v$ver', style: const TextStyle(fontSize: 14)),
      const SizedBox(height: 4),
      const Text('零售 / 餐饮一体化收银 · 云打印 · 会员营销 · 小程序订单同步',
          style: TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
    ]));
  }

  // ==================== 钱箱（v3.3.202） ====================

  Future<void> _loadDrawer() async {
    final sp = await SharedPreferences.getInstance();
    final ch = sp.getString(CashDrawer.prefChannel) ?? 'usb';
    final name = await _drawerPrinterNameOf(ch);
    if (!mounted) return;
    setState(() {
      drawerEnabled = sp.getBool(CashDrawer.prefEnabled) ?? false;
      drawerChannel = ch;
      drawerPrinterName = name;
    });
  }

  /// 当前弹箱通道已选打印机名称（未选返回空）
  Future<String> _drawerPrinterNameOf(String ch) async {
    try {
      if (ch == 'bt') {
        final d = await BtPrinter.selectedDevice();
        return '${d?['name'] ?? ''}';
      }
      final p = await UsbPrinter.selectedPrinter();
      return '${p?['name'] ?? ''}';
    } catch (_) {
      return '';
    }
  }

  Future<void> _saveDrawer() async {
    await CashDrawer.setEnabled(drawerEnabled);
    await CashDrawer.setChannel(drawerChannel);
  }

  /// 测试打开钱箱：直接给当前通道打印机发开箱指令（与自动弹箱自动开关无关，随时可测）
  Future<void> _drawerTest() async {
    setState(() => drawerTesting = true);
    try {
      await CashDrawer.open();
      if (!mounted) return;
      toast(context, '已向「${drawerPrinterName.isEmpty ? '打印机' : drawerPrinterName}」发送开箱指令，请确认钱箱是否弹出');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) toast(context, '弹箱失败：$e', error: true);
    } finally {
      if (mounted) setState(() => drawerTesting = false);
    }
  }

  Widget _drawerCard() {
    if (!CashDrawer.supported) return const SizedBox.shrink();
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle(Icons.savings_outlined, '钱箱'),
        const Spacer(),
        // 测试打开钱箱：常驻标题栏，不依赖自动弹箱开关
        OutlinedButton.icon(
          onPressed: drawerTesting ? null : _drawerTest,
          style: OutlinedButton.styleFrom(foregroundColor: PosTheme.blue, side: const BorderSide(color: PosTheme.blue)),
          icon: drawerTesting
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: PosTheme.blue))
              : const Icon(Icons.lock_open_outlined, size: 16),
          label: const Text('测试打开钱箱'),
        ),
      ]),
      const SizedBox(height: 4),
      // 自动弹箱开关
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 8),
            Text('现金结算自动弹箱', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 2),
            Text('开启后零售 / 生鲜 / 堂食用现金收银成功时，自动向打印机发送开箱指令弹出钱箱（扫码、会员等其他支付方式不弹）',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 8),
          ])),
          Switch(
            value: drawerEnabled,
            activeColor: PosTheme.accent,
            onChanged: (v) async {
              setState(() => drawerEnabled = v);
              await _saveDrawer();
            },
          ),
        ]),
      ),
      // 弹箱通道
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('钱箱接线方式', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(children: [
            _drawerChip('usb', 'USB小票打印机'),
            const SizedBox(width: 6),
            _drawerChip('bt', '蓝牙打印机'),
          ]),
          const SizedBox(height: 6),
          Text(
            drawerChannel == 'bt'
                ? '钱箱 RJ11 线接在蓝牙小票打印机上，开箱指令通过已选择的蓝牙打印机发出'
                : '钱箱 RJ11 线接在 USB 小票打印机上，开箱指令通过已选择的 USB 打印机发出',
            style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint),
          ),
        ]),
      ),
      // 当前打印机 + 排障提示
      Row(children: [
        Icon(drawerPrinterName.isEmpty ? Icons.error_outline : Icons.print_outlined,
            size: 14, color: drawerPrinterName.isEmpty ? PosTheme.amber : PosTheme.textHint),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            drawerPrinterName.isEmpty
                ? '未选择${drawerChannel == 'bt' ? '蓝牙' : ' USB '}打印机，请先在上方对应设置里选择，否则测试和自动弹箱都会失败'
                : '弹箱打印机：$drawerPrinterName　｜　测试不弹箱时：确认钱箱 RJ11 线插紧在打印机上、打印机电源正常',
            style: TextStyle(fontSize: 11.5,
                color: drawerPrinterName.isEmpty ? PosTheme.amber : PosTheme.textHint),
          ),
        ),
      ]),
    ]));
  }

  Widget _drawerChip(String key, String label) {
    final sel = drawerChannel == key;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        setState(() => drawerChannel = key);
        await _saveDrawer();
        final name = await _drawerPrinterNameOf(key);
        if (mounted) setState(() => drawerPrinterName = name);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFFEFF7F0) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sel ? PosTheme.accent : PosTheme.textHint.withOpacity(0.4)),
        ),
        child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600,
            color: sel ? PosTheme.accent : PosTheme.textSub)),
      ),
    );
  }

  // ==================== USB 小票打印机 ====================

  Widget _usbCard() {
    if (!UsbPrinter.supported) {
      return const SizedBox.shrink();
    }
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle(Icons.usb_outlined, 'USB小票打印机'),
        const Spacer(),
        TextButton.icon(
          onPressed: _refreshUsb,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('刷新'),
        ),
      ]),
      const SizedBox(height: 4),
      // 启用开关
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 8),
            Text('启用 USB 直连打印', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 2),
            Text('开启后收银 / 结账 / 后厨 / 交班小票直接发往本机打印机（无需联网云打印）',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 8),
          ])),
          Switch(
            value: usbEnabled,
            activeColor: PosTheme.accent,
            onChanged: (v) async {
              setState(() => usbEnabled = v);
              await _saveUsbPrefs();
            },
          ),
        ]),
      ),
      // 出票模式：自动打印 / 手动打印（v3.3.156）
      if (usbEnabled)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('出票模式', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              _modeChip('auto', '自动打印'),
              const SizedBox(width: 6),
              _modeChip('manual', '手动打印'),
            ]),
            const SizedBox(height: 4),
            Text(
              usbMode == 'manual'
                  ? '手动打印：收银 / 结账 / 后厨 / 预约等小票一律不自动出票，仅在补打小票、测试打印等主动操作时出票'
                  : '自动打印：收银 / 结账 / 后厨 / 预约小票按「小票打印设置」自动出票',
              style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint),
            ),
          ]),
        ),
      // 打印机列表
      if (usbLoading)
        const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(color: PosTheme.accent)))
      else if (usbPrinters.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            Platform.isMacOS
                ? '未发现打印机。请确认打印机已开机并用 USB 数据线连接；若仍为空，请在「系统设置 → 打印机与扫描仪」添加打印机后刷新。'
                : '未发现打印机。请确认打印机已开机并用 USB 数据线连接后，点右上角「刷新」。',
            style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint),
          ),
        )
      else
        ...usbPrinters.map((p) {
          final sel = usbSelected != null && '${usbSelected!['id']}' == '${p['id']}';
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: sel ? const Color(0xFFEFF7F0) : const Color(0xFFF7F8FA),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sel ? PosTheme.accent : Colors.transparent),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _pickUsbPrinter(p),
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Row(children: [
                  Icon(sel ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 19, color: sel ? PosTheme.accent : PosTheme.textHint),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${p['name']}',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (Platform.isAndroid && p['hasPermission'] == false)
                      const Text('尚未授权，打印时会弹出 USB 权限确认',
                          style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                  ])),
                  TagChip(_usbKindName(p), color: PosTheme.blue),
                ]),
              ),
            ),
          );
        }),
      // 纸张规格 + 预览 + 测试
      const SizedBox(height: 4),
      Row(children: [
        const Text('纸张规格', style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
        const SizedBox(width: 10),
        _specChip('pos58', '58mm小票'),
        const SizedBox(width: 6),
        _specChip('pos80', '80mm小票'),
        const SizedBox(width: 6),
        _specChip('dot', '针式连续纸'),
        const SizedBox(width: 6),
        _specChip('a4', 'A4纸'),
        const SizedBox(width: 6),
        // 自定义：页宽 + 水平微调（v3.3.159，适配不同打印机进纸位置）
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _usbCustomSpec,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: _hasCustomCfg(usbSpec) ? const Color(0xFFFDF1EC) : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _hasCustomCfg(usbSpec) ? PosTheme.accent : PosTheme.textHint.withOpacity(0.4)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.tune, size: 14,
                  color: _hasCustomCfg(usbSpec) ? PosTheme.accent : PosTheme.textSub),
              const SizedBox(width: 4),
              Text('自定义',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600,
                      color: _hasCustomCfg(usbSpec) ? PosTheme.accent : PosTheme.textSub)),
            ]),
          ),
        ),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _usbPreview,
          style: OutlinedButton.styleFrom(foregroundColor: PosTheme.blue, side: const BorderSide(color: PosTheme.blue)),
          icon: const Icon(Icons.visibility_outlined, size: 16),
          label: const Text('预览'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: usbSelected == null ? null : _usbTest,
          style: OutlinedButton.styleFrom(foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
          icon: const Icon(Icons.local_printshop_outlined, size: 16),
          label: const Text('测试打印'),
        ),
      ]),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('提示：热敏小票机选 58/80mm；针式打印机（EPSON LQ 系列等）选「针式连续纸」或「A4纸」，打印完自动换页出纸，不再卡在"正在打印"。关闭开关时小票自动改走云打印机。',
            style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      ),
    ]));
  }

  String _usbKindName(Map<String, dynamic> p) {
    switch ('${p['kind']}') {
      case 'win': return '系统打印机';
      case 'queue': return '打印队列';
      case 'usb': return Platform.isMacOS ? 'USB设备' : 'USB直连';
      default: return 'USB';
    }
  }

  /// 蓝牙打印卡片（v3.3.185）：Windows/macOS 选已配对设备，Android 支持扫描配对
  Widget _btCard() {
    if (!BtPrinter.supported) {
      return const SizedBox.shrink();
    }
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle(Icons.bluetooth_outlined, '蓝牙打印机'),
        const Spacer(),
        TextButton.icon(
          onPressed: _refreshBt,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('刷新'),
        ),
      ]),
      const SizedBox(height: 4),
      // 启用开关
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 8),
            Text('启用蓝牙打印', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 2),
            Text('开启后小票发往蓝牙打印机（USB 打印未启用时自动生效，便携蓝牙机适配移动收银场景）',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 8),
          ])),
          Switch(
            value: btEnabled,
            activeColor: PosTheme.accent,
            onChanged: (v) async {
              setState(() => btEnabled = v);
              await BtPrinter.setEnabled(v);
            },
          ),
        ]),
      ),
      // Android：扫描附近蓝牙设备
      if (btEnabled && Platform.isAndroid)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: const Text('打印机还没配对？扫描附近蓝牙设备并配对',
                  style: TextStyle(fontSize: 13))),
              OutlinedButton.icon(
                onPressed: btScanning ? null : _btScanPair,
                style: OutlinedButton.styleFrom(foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
                icon: btScanning
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: PosTheme.accent))
                    : const Icon(Icons.bluetooth_searching, size: 16),
                label: Text(btScanning ? '扫描中…' : '扫描配对'),
              ),
            ]),
          ]),
        ),
      // Android 扫描结果（未配对设备）
      if (btEnabled && btScanResults.isNotEmpty)
        ...btScanResults.where((p) => p['paired'] != true).map((p) {
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F8FA),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              const Icon(Icons.bluetooth_disabled_outlined, size: 19, color: PosTheme.textHint),
              const SizedBox(width: 10),
              Expanded(child: Text('${p['name']}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              TextButton(
                onPressed: () => _btPairDevice(p),
                child: const Text('配对'),
              ),
            ]),
          );
        }),
      // 已配对设备列表
      if (btEnabled)
        if (btLoading)
          const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(color: PosTheme.accent)))
        else if (btDevices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              Platform.isAndroid
                  ? '没有已配对的蓝牙打印机。点上方「扫描配对」，或到系统蓝牙设置配对后刷新。'
                  : '未发现已配对的蓝牙打印机。请先到系统蓝牙设置配对小票打印机（开机并处于可配对状态），然后点右上角「刷新」。',
              style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint),
            ),
          )
        else
          ...btDevices.map((p) {
            final sel = btSelected != null && '${btSelected!['id']}' == '${p['id']}';
            final noSpp = '${p['kind']}' == 'nospp';
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: sel ? const Color(0xFFEFF7F0) : const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: sel ? PosTheme.accent : Colors.transparent),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: noSpp ? null : () => _pickBtPrinter(p),
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: Row(children: [
                    Icon(noSpp
                        ? Icons.block_outlined
                        : (sel ? Icons.radio_button_checked : Icons.radio_button_off),
                        size: 19, color: sel ? PosTheme.accent : PosTheme.textHint),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${p['name']}',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: noSpp ? PosTheme.textHint : PosTheme.textMain),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (noSpp)
                        const Text('该设备没有串口(SPP)服务，无法直接打印',
                            style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                    ])),
                    TagChip(noSpp ? '不可用' : '蓝牙SPP', color: noSpp ? Colors.grey : PosTheme.blue),
                  ]),
                ),
              ),
            );
          }),
      // 纸张规格 + 测试
      if (btEnabled && btSelected != null) ...[
        const SizedBox(height: 4),
        Row(children: [
          const Text('纸张规格', style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
          const SizedBox(width: 10),
          _btSpecChip('pos58', '58mm小票'),
          const SizedBox(width: 6),
          _btSpecChip('pos80', '80mm小票'),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _btTest,
            style: OutlinedButton.styleFrom(foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
            icon: const Icon(Icons.local_printshop_outlined, size: 16),
            label: const Text('测试打印'),
          ),
        ]),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('提示：蓝牙打印按「先 USB、后蓝牙」顺序出票——USB 打印关闭时小票自动走蓝牙；关闭蓝牙开关则改走云打印机。测试不出票时，请确认打印机开机、在蓝牙范围内且没被手机占用。',
              style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        ),
      ],
    ]));
  }

  /// 蓝牙纸张规格 chip（58/80）
  Widget _btSpecChip(String key, String label) {
    final sel = btSpec == key;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        setState(() => btSpec = key);
        await BtPrinter.setSpec(key);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? PosTheme.accent : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sel ? PosTheme.accent : PosTheme.textHint.withOpacity(0.4)),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: sel ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  /// 出票模式选择 chip（自动/手动）
  Widget _modeChip(String key, String label) {
    final sel = usbMode == key;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        setState(() => usbMode = key);
        await _saveUsbPrefs();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? PosTheme.accent : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sel ? PosTheme.accent : PosTheme.textHint.withOpacity(0.4)),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: sel ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  Widget _specChip(String key, String label) {    final sel = usbSpec == key;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        setState(() => usbSpec = key);
        final spec = UsbPrinter.specOf(key);
        setState(() => usbPaper = spec['width'] as int);
        await _saveUsbPrefs();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? PosTheme.accent : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sel ? PosTheme.accent : PosTheme.textHint.withOpacity(0.4)),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: sel ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  bool _hasCustomCfg(String key) {
    final c = usbCfgs[key];
    return c != null && ((c['pageMm'] ?? 0) > 0 || (c['offMm'] ?? 0) != 0);
  }

  /// 规格默认页宽 mm
  static double _defaultPageMm(String key) {
    switch (key) {
      case 'pos80':
        return 80;
      case 'dot':
        return 241;
      case 'a4':
        return 210;
      default:
        return 58;
    }
  }

  /// 版心宽 mm：escp 10cpi 1列=2.54mm；热敏 1.5mm/列
  static double _textMmOfSpec(String key) {
    switch (key) {
      case 'pos80':
        return 48 * 1.5;
      case 'dot':
        return 48 * 2.54;
      case 'a4':
        return 60 * 2.54;
      default:
        return 32 * 1.5;
    }
  }

  /// 自定义纸张设置（v3.3.159）：页宽 + 水平微调（靠左/居中/靠右 + 毫米级微调）
  /// 适配不同打印机/进纸位置：纸放偏了往相反方向微调即可
  Future<void> _usbCustomSpec() async {
    final cfgs = <String, Map<String, double>>{};
    for (final k in const ['pos58', 'pos80', 'dot', 'a4']) {
      cfgs[k] = await UsbPrinter.loadSpecCfg(k);
    }
    String spec = usbSpec;
    double pageMm() {
      final saved = cfgs[spec]!['pageMm'] ?? 0;
      return saved > 0 ? saved : _defaultPageMm(spec);
    }

    double offMm = cfgs[spec]!['offMm'] ?? 0;
    final customCtl = TextEditingController(
        text: pageMm().toStringAsFixed(0));

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final isEscp = spec == 'dot' || spec == 'a4';
        final pm = pageMm();
        final textMm = _textMmOfSpec(spec);
        // 步进取整：保证滑杆 1mm 整数步进，快捷键状态判断才准
        final maxShift = isEscp
            ? (((pm - textMm) / 2).floorToDouble()).clamp(5.0, 90.0)
            : 30.0;
        if (offMm > maxShift) offMm = maxShift;
        if (offMm < -maxShift) offMm = -maxShift;
        final presets = spec == 'dot' ? [241.0, 190.0, 127.0] : (spec == 'a4' ? [210.0] : <double>[]);
        final isCustomPage = isEscp && !presets.contains(pm);

        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('自定义纸张 · ${UsbPrinter.specOf(spec)['label']}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                // 规格切换
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final e in const [
                    ['pos58', '58mm'],
                    ['pos80', '80mm'],
                    ['dot', '针式连续纸'],
                    ['a4', 'A4纸'],
                  ])
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => setD(() {
                        spec = '${e[0]}';
                        offMm = cfgs[spec]!['offMm'] ?? 0;
                        customCtl.text = pageMm().toStringAsFixed(0);
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: spec == e[0] ? PosTheme.accent : const Color(0xFFF5F6F8),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: spec == e[0] ? PosTheme.accent : Colors.transparent),
                        ),
                        child: Text('${e[1]}',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                color: spec == e[0] ? Colors.white : PosTheme.textSub)),
                      ),
                    ),
                ]),
                const SizedBox(height: 14),
                // 纸张宽度（针式可自定义，热敏固定）
                Text('纸张宽度', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: PosTheme.textSub)),
                const SizedBox(height: 8),
                if (isEscp)
                  Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    for (final p in presets)
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => setD(() {
                          cfgs[spec] = {'pageMm': p, 'offMm': offMm}; // 选中该预设纸宽
                          customCtl.text = p.toStringAsFixed(0);
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: pm == p ? PosTheme.accent : Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: pm == p ? PosTheme.accent : PosTheme.textHint.withOpacity(0.4)),
                          ),
                          child: Text('${p.toStringAsFixed(0)}mm${p == _defaultPageMm(spec) ? ' 默认' : ''}',
                              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600,
                                  color: pm == p ? Colors.white : PosTheme.textSub)),
                        ),
                      ),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => setD(() {}),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isCustomPage ? PosTheme.accent : Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: isCustomPage ? PosTheme.accent : PosTheme.textHint.withOpacity(0.4)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text('自定义 ',
                              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600,
                                  color: isCustomPage ? Colors.white : PosTheme.textSub)),
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: customCtl,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                              textAlign: TextAlign.center,
                              decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                  hintText: 'mm',
                                  suffixText: 'mm',
                                  suffixStyle: const TextStyle(fontSize: 11)),
                              onChanged: (v) => setD(() {
                                final m = double.tryParse(v) ?? 0;
                                if (m >= 50 && m <= 500) cfgs[spec] = {'pageMm': m, 'offMm': offMm};
                              }),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ])
                else
                  Text('热敏机纸宽固定 ${_defaultPageMm(spec).toStringAsFixed(0)}mm，无需设置',
                      style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                const SizedBox(height: 16),
                // 水平位置：快捷 + 微调
                Text('水平位置微调', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: PosTheme.textSub)),
                const SizedBox(height: 8),
                if (isEscp)
                  Wrap(spacing: 8, children: [
                    for (final e in const [
                      ['left', '靠左'],
                      ['center', '居中'],
                      ['right', '靠右'],
                    ])
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => setD(() => offMm = e[0] == 'left'
                            ? -maxShift
                            : (e[0] == 'right' ? maxShift : 0)),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(
                            color: offMm == (e[0] == 'left' ? -maxShift : (e[0] == 'right' ? maxShift : 0))
                                ? PosTheme.blue
                                : Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: offMm == (e[0] == 'left' ? -maxShift : (e[0] == 'right' ? maxShift : 0))
                                    ? PosTheme.blue
                                    : PosTheme.textHint.withOpacity(0.4)),
                          ),
                          child: Text('${e[1]}',
                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600,
                                  color: offMm == (e[0] == 'left' ? -maxShift : (e[0] == 'right' ? maxShift : 0))
                                      ? Colors.white
                                      : PosTheme.textSub)),
                        ),
                      ),
                  ]),
                const SizedBox(height: 8),
                Row(children: [
                  Text('左移', style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
                  Expanded(
                    child: Slider(
                      value: offMm.clamp(-maxShift, maxShift),
                      min: -maxShift,
                      max: maxShift,
                      divisions: (maxShift * 2).round(),
                      label: '${offMm > 0 ? '+' : ''}${offMm.toStringAsFixed(0)}mm',
                      activeColor: PosTheme.accent,
                      onChanged: (v) => setD(() => offMm = v),
                    ),
                  ),
                  Text('右移', style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
                  SizedBox(
                    width: 64,
                    child: Text('${offMm > 0 ? '+' : ''}${offMm.toStringAsFixed(0)}mm',
                        textAlign: TextAlign.end,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                  ),
                ]),
                const SizedBox(height: 10),
                // 实时预览（规格名显示实际纸宽）
                Center(
                  child: _TicketPaper(
                    content: _usbSampleTicket(usbSelected?['name'] ?? '未选择打印机',
                        isEscp ? '针式纸 ${pm.toStringAsFixed(0)}mm' : '${UsbPrinter.specOf(spec)['label']}'),
                    spec: spec,
                    pageMm: cfgs[spec]!['pageMm'] ?? 0,
                    offMm: offMm,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isEscp
                      ? '纸没放正就用微调救：内容偏左 → 往右移（正值）；内容偏右 → 往左移（负值）。1 字符列 ≈ 2.54mm（针式 10cpi）。'
                      : '热敏机默认贴左打，正值整体右移、负值左移。1 字符列 ≈ 1.5mm。',
                  style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await UsbPrinter.saveSpecCfg(spec, pageMm: 0, offMm: 0);
                cfgs[spec] = {'pageMm': 0, 'offMm': 0};
                offMm = 0;
                customCtl.text = _defaultPageMm(spec).toStringAsFixed(0);
                setD(() {});
              },
              child: const Text('恢复默认'),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: PosTheme.accent),
              child: const Text('保存'),
            ),
          ],
        );
      }),
    );
    if (ok == true) {
      final isEscp = spec == 'dot' || spec == 'a4';
      await UsbPrinter.saveSpecCfg(spec,
          pageMm: isEscp ? pageMm() : 0, offMm: offMm);
      await _loadSpecCfgs();
      if (mounted) toast(context, '已保存「${UsbPrinter.specOf(spec)['label']}」自定义设置');
    } else {
      customCtl.dispose();
    }
  }

  /// 测试小票样张（预览与测试打印共用）
  static String _usbSampleTicket(String printerName, String specLabel) {
    return '<FS2><center>测试小票</center></FS2>\n'
        '--------------------------------\n'
        '稳讯收银桌面版\n'
        'USB打印机：$printerName\n'
        '纸张规格：$specLabel\n'
        '--------------------------------\n'
        '湖南小炒肉 x1        ¥38.00\n'
        '可乐 x2              ¥6.00\n'
        '--------------------------------\n'
        '合计：¥44.00\n'
        '时间：${DateTime.now().toString().substring(0, 19)}\n'
        '--------------------------------\n'
        '打印正常，可开始收银';
  }

  /// 打印预览：弹窗内实时切换纸张规格查看效果（含自定义页宽/微调）
  Future<void> _usbPreview() async {
    String spec = usbSpec;
    final cfgs = <String, Map<String, double>>{};
    for (final k in const ['pos58', 'pos80', 'dot', 'a4']) {
      cfgs[k] = await UsbPrinter.loadSpecCfg(k);
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final s = UsbPrinter.specOf(spec);
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('小票打印预览', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              // 规格切换（实时刷新预览）
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in const [
                  ['pos58', '58mm小票'],
                  ['pos80', '80mm小票'],
                  ['dot', '针式连续纸'],
                  ['a4', 'A4纸'],
                ])
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setD(() => spec = '${e[0]}'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: spec == e[0] ? PosTheme.accent : const Color(0xFFF5F6F8),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: spec == e[0] ? PosTheme.accent : Colors.transparent),
                      ),
                      child: Text('${e[1]}',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: spec == e[0] ? Colors.white : PosTheme.textSub)),
                    ),
                  ),
              ]),
              const SizedBox(height: 14),
              // 纸张效果预览（含自定义页宽/微调）
              Center(child: _TicketPaper(
                content: _usbSampleTicket(usbSelected?['name'] ?? '未选择打印机', '${s['label']}'),
                spec: spec,
                pageMm: cfgs[spec]!['pageMm'] ?? 0,
                offMm: cfgs[spec]!['offMm'] ?? 0,
              )),
              const SizedBox(height: 8),
              Text(
                spec == 'dot'
                    ? '针式连续纸 241mm：两侧带孔的连打纸，小票内容整张居中不贴左，打印完自动换页走纸'
                    : spec == 'a4'
                        ? 'A4 单页纸：针式打印机单页送纸，小票内容整张居中，打印完自动退纸'
                        : '热敏小票机：打印完自动切纸（需打印机支持切刀）',
                style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: PosTheme.accent),
              child: const Text('使用该规格'),
            ),
          ],
        );
      }),
    );
    if (ok == true) {
      setState(() => usbSpec = spec);
      final s = UsbPrinter.specOf(spec);
      setState(() => usbPaper = s['width'] as int);
      await _saveUsbPrefs();
      if (mounted) toast(context, '已切换：${s['label']}');
    }
  }

  Widget _sectionTitle(IconData icon, String text) {
    return Row(children: [
      Icon(icon, size: 19, color: PosTheme.accentLive),
      const SizedBox(width: 8),
      Text(text, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
    ]);
  }

  Widget _info(String k, String v) {
    return Expanded(child: Container(
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
        const SizedBox(height: 3),
        Text(v.isEmpty ? '-' : v, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    ));
  }
}

/// 清空购物车二次确认设置（v3.3.192）
/// 开关按设备保存；密码校验走云端员工权限密码（与退款/现金充值同一套），本机不存密码
class _ClearPinRow extends StatefulWidget {
  const _ClearPinRow();
  @override
  State<_ClearPinRow> createState() => _ClearPinRowState();
}

class _ClearPinRowState extends State<_ClearPinRow> {
  bool loading = true;
  bool enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final e = await ClearPin.enabled();
    if (!mounted) return;
    setState(() {
      enabled = e;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
      decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 10),
            Text('清空购物车需权限密码', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 3),
            Text('开启后，零售收银界面点「清空」会弹出数字键盘，输入正确的员工权限密码才能清空购物车（防止误触把整单清掉）。',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            SizedBox(height: 10),
          ])),
          Switch(
            value: enabled,
            activeColor: PosTheme.accent,
            onChanged: (v) async {
              setState(() => enabled = v);
              await ClearPin.setEnabled(v);
            },
          ),
        ]),
        if (enabled && !loading)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: PosTheme.line),
              ),
              child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline, size: 16, color: PosTheme.accent),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '密码与「订单退款 / 现金充值」共用同一套：由商户在「设置 → 权限密码」中为每位收银员分配 6 位数字，收银员本人不可修改，也不保存在本机。未分配密码的收银员无法清空购物车。',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: PosTheme.textSub),
                  ),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// 单个商品改价需权限密码（v3.3.205）
/// 开关按设备保存；与「清空购物车 / 退款」共用云端员工权限密码
class _PricePinRow extends StatefulWidget {
  const _PricePinRow();
  @override
  State<_PricePinRow> createState() => _PricePinRowState();
}

class _PricePinRowState extends State<_PricePinRow> {
  bool enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final e = await CartPrefs.priceNeedPin();
    if (!mounted) return;
    setState(() => enabled = e);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
      decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(height: 10),
              Text('单个商品改价需权限密码', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              SizedBox(height: 3),
              Text('开启后，在购物车点商品改价（折扣价 / 自定义单价）需先输入员工权限密码，防止收银员随意打折。改数量、备注、删除不受影响。',
                  style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              SizedBox(height: 10),
            ]),
          ),
          Switch(
            value: enabled,
            activeColor: PosTheme.accent,
            onChanged: (v) async {
              setState(() => enabled = v);
              await CartPrefs.setPriceNeedPin(v);
            },
          ),
        ]),
        if (enabled)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, size: 16, color: PosTheme.accent),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '密码与「订单退款 / 清空购物车」共用同一套，由商户在「设置 → 权限密码」为收银员分配；未分配密码的收银员将无法改价。',
                  style: TextStyle(fontSize: 11.5, height: 1.5, color: PosTheme.textSub),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// 小票纸张预览：按规格模拟纸张宽度/字号/样式（预览弹窗用）
/// [pageMm] 自定义纸宽（0=规格默认）、[offMm] 水平微调 mm（v3.3.159）
class _TicketPaper extends StatelessWidget {
  final String content;
  final String spec; // pos58/pos80/dot/a4
  final double pageMm;
  final double offMm;
  const _TicketPaper({required this.content, required this.spec, this.pageMm = 0, this.offMm = 0});

  @override
  Widget build(BuildContext context) {
    // 纸张视觉宽度与字号
    final double paperW;
    final double fontSize;
    switch (spec) {
      case 'pos80':
        paperW = 310;
        fontSize = 13;
        break;
      case 'dot':
        paperW = 400;
        fontSize = 14;
        break;
      case 'a4':
        paperW = 470;
        fontSize = 13.5;
        break;
      default:
        paperW = 230;
        fontSize = 12;
    }
    final isDot = spec == 'dot' || spec == 'a4';
    // 水平位置：针式按「版心/页宽」居中 + 微调；热敏按微调 mm 平移
    final double sideInset;
    if (isDot) {
      final pm = pageMm > 0 ? pageMm : (spec == 'dot' ? 241.0 : 210.0);
      final tm = spec == 'dot' ? 48 * 2.54 : 60 * 2.54; // 版心宽 mm
      final inner = paperW - 36;
      final frac = (tm / pm).clamp(0.0, 1.0);
      sideInset =
          (inner * (1 - frac) / 2 + offMm / pm * inner).clamp(0.0, inner * (1 - frac));
    } else if (offMm != 0) {
      final inner = paperW - 36;
      final defMm = spec == 'pos80' ? 80.0 : 58.0;
      sideInset = (offMm / defMm * inner).clamp(0.0, inner * 0.5);
    } else {
      sideInset = 0;
    }

    final lines = <Widget>[];
    for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
      final t = raw.trim();
      if (t.isEmpty) {
        lines.add(SizedBox(height: fontSize * 0.7));
        continue;
      }
      final lower = t.toLowerCase();
      final center = lower.contains('<center>') || lower.contains('<cb>');
      final double_ = lower.contains('<fs2>') || lower.contains('<cb>');
      final bold = lower.contains('<fb>') || lower.contains('<cb>') || lower.contains('<bold>');
      final text = t.replaceAll(
          RegExp(r'</?(CB|C|B|BOLD|FS|FS2|FB|FH|FH2|FW|FW2|center|right|left)>', caseSensitive: false), '');
      if (text.isEmpty) {
        lines.add(SizedBox(height: fontSize * 0.7));
        continue;
      }
      if (text == '-' * text.length && text.length >= 8) {
        // 分隔线
        lines.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Container(height: 1, color: const Color(0xFFB9BDC7))),
          ]),
        ));
        continue;
      }
      lines.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Text(
          text,
          textAlign: center ? TextAlign.center : TextAlign.left,
          style: TextStyle(
            fontSize: double_ ? fontSize * 1.5 : fontSize,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            height: 1.35,
            color: const Color(0xFF22242A),
          ),
        ),
      ));
    }

    return Container(
      width: paperW,
      padding: EdgeInsets.fromLTRB(18, 16, 18, isDot ? 26 : 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(isDot ? 4 : 10),
        border: Border.all(color: const Color(0xFFD8DBE2)),
        boxShadow: const [BoxShadow(color: Color(0x14101828), blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 针式纸顶部齿轮孔装饰
          if (isDot)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                for (var i = 0; i < 16; i++)
                  Container(width: 5, height: 5, decoration: const BoxDecoration(color: Color(0xFFE7E9EF), shape: BoxShape.circle)),
              ]),
            ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: sideInset),
            // stretch：Text 占满整行宽 → 正文按 textAlign 左对齐（像文章），
            // 仅 <center> 标题行居中；不能用 Column 默认 center（会把正文全居中）
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: lines),
          ),
          const SizedBox(height: 6),
          if (!isDot)
            Container(
              height: 14,
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade300, width: 1)),
              ),
              alignment: Alignment.center,
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                for (var i = 0; i < 24; i++)
                  Container(width: 3, height: 8, decoration: const BoxDecoration(color: Color(0xFFEDEEF3), shape: BoxShape.circle)),
              ]),
            ),
        ],
      ),
    );
  }
}

/// 称重设备设置卡片（v3.3.184）
///
/// 只在这两端出现（苹果端不接秤，称重只用键盘手输）：
/// - Windows：键盘口秤（USB-HID，免驱）+ 串口秤（COM/RS232，市面通用收银秤，支持自动检测）
/// - 安卓：键盘口秤 + 一体机内置秤（商米/天波等一体机自带秤）
class _ScaleCard extends StatefulWidget {
  const _ScaleCard();
  @override
  State<_ScaleCard> createState() => _ScaleCardState();
}

class _ScaleCardState extends State<_ScaleCard> {
  final p = ScalePrefs();
  final portCtrl = TextEditingController();
  bool loading = true;
  bool testing = false;
  bool probing = false;
  double? testKg;
  String testMsg = '';

  SerialScale? _serial;
  BuiltinScale? _builtin;
  KeyboardScale? _kb;
  Timer? _timer; // 20 秒自动停止
  Timer? _poll; // 键盘口秤静默帧轮询
  bool _keyOn = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await ScalePrefs.load();
    if (!mounted) return;
    setState(() {
      p.enabled = v.enabled;
      p.mode = v.mode;
      p.port = v.port;
      p.baud = v.baud;
      p.unit = v.unit;
      portCtrl.text = v.port;
      loading = false;
    });
  }

  Future<void> _save() async {
    p.port = portCtrl.text.trim();
    await p.save();
    // 配置变更后重启全局秤连接（收银页称重条/称重弹窗共用）；
    // 测试/自动检测期间不重启（服务已暂停，避免抢串口）
    if (!testing && !probing) await ScaleService.I.restart();
  }

  @override
  void dispose() {
    _stopTest();
    // 测试中离开设置页：恢复全局秤连接（按最新配置重连）
    ScaleService.I.resume();
    portCtrl.dispose();
    super.dispose();
  }

  void _stopTest() {
    _timer?.cancel();
    _timer = null;
    _poll?.cancel();
    _poll = null;
    if (_keyOn) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _keyOn = false;
    }
    _serial?.dispose();
    _serial = null;
    _builtin?.dispose();
    _builtin = null;
    _kb?.clear();
    _kb = null;
    if (mounted) setState(() => testing = false);
  }

  bool _onKey(KeyEvent e) {
    final k = _kb;
    if (k == null) return false;
    final kg = k.feed(e, unitPref: p.unit);
    if (kg != null) _onRead(kg);
    return false;
  }

  void _onRead(double kg) {
    if (!mounted || kg <= 0) return;
    setState(() {
      testKg = kg;
      testMsg = '已连接，读到重量';
    });
  }

  Future<void> _startTest() async {
    // 测试要独占串口/内置秤：先暂停全局秤连接（收银页称重条在用）
    await ScaleService.I.suspend();
    setState(() => testing = true); // 先置位，_save 期间不重启全局连接
    await _save();
    _stopTest();
    setState(() {
      testing = true;
      testKg = null;
      testMsg = '请把商品放到秤上（监听 20 秒）';
    });

    if (p.mode == 'serial' && ScaleSupport.hasSerial) {
      final s = SerialScale();
      final ok = s.start(portName: p.port, baud: p.baud, unitPref: p.unit);
      if (!mounted) {
        s.dispose();
        ScaleService.I.resume();
        return;
      }
      if (!ok) {
        setState(() {
          testing = false;
          testMsg = '串口打不开：确认秤已插好、驱动已装，或点「自动检测」让系统自己找';
        });
        ScaleService.I.resume(); // 测试失败也要恢复全局连接
        return;
      }
      _serial = s;
      s.stream.listen(_onRead);
    } else if (p.mode == 'builtin' && ScaleSupport.hasBuiltin) {
      final b = BuiltinScale();
      final ok = await b.start(unitPref: p.unit);
      if (!mounted) {
        b.dispose();
        ScaleService.I.resume();
        return;
      }
      _builtin = b;
      b.stream.listen(_onRead);
      if (!ok) {
        setState(() {
          testing = false;
          testMsg = '这台机器没有开放内置秤接口，建议改用键盘口秤';
        });
        ScaleService.I.resume();
        return;
      }
    } else {
      final k = KeyboardScale();
      _kb = k;
      HardwareKeyboard.instance.addHandler(_onKey);
      _keyOn = true;
      // 无回车协议兜底：定时取静默帧（与 20 秒超时分开计时）
      _poll = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final kg = k.takePending();
        if (kg != null) _onRead(kg);
      });
    }
    // 20 秒监听结束：停止测试并恢复全局秤连接
    _timer = Timer(const Duration(seconds: 20), () async {
      _stopTest();
      await ScaleService.I.resume();
    });
  }

  /// Windows：自动找串口 + 波特率（收银员不用懂 COM 号）
  Future<void> _autoDetect() async {
    await ScaleService.I.suspend(); // 探测要遍历 COM 口，先暂停全局连接
    _stopTest();
    setState(() {
      probing = true;
      testKg = null;
      testMsg = '正在自动检测串口和波特率，秤盘上放不放东西都行，最长约半分钟…';
    });
    final r = await SerialScale.autoDetect();
    if (!mounted) return;
    if (r == null) {
      setState(() {
        probing = false;
        testMsg = '没找到秤：确认秤已开机、线插好（设备管理器里能看到 COM 口）；'
          '一体机内置秤请联系厂家确认串口是否已接出。也可改用键盘口秤';
      });
      ScaleService.I.resume(); // 没找到也要恢复全局连接
      return;
    }
    setState(() {
      probing = false;
      p.mode = 'serial';
      p.port = r.port;
      p.baud = r.baud;
      portCtrl.text = r.port;
      testKg = r.kg;
      testMsg = '已自动连接 ${r.port}（${r.baud}）';
    });
    await _save();
    await ScaleService.I.resume(); // 探测结束恢复全局连接
  }

  void _pickPort() {
    final ports = SerialScale.availablePorts();
    if (ports.isEmpty) {
      toast(context, '未检测到串口设备：请确认秤已插好、驱动已装（设备管理器能看到 COM 口）', error: true);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('选择串口', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            ...ports.map((name) => InkWell(
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() => portCtrl.text = name);
                    _save();
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
                    child: Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                )),
          ]),
        ),
      ),
    );
  }

  Widget _chip(String text, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        margin: const EdgeInsets.only(right: 8, bottom: 8),
        decoration: BoxDecoration(
          color: active ? PosTheme.accent.withOpacity(0.1) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: active ? PosTheme.accent : PosTheme.line, width: active ? 1.6 : 1),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? PosTheme.accent : PosTheme.textSub)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const AppCard(child: SizedBox(height: 120, child: Center(child: CircularProgressIndicator())));
    final isWin = ScaleSupport.isWindows;
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(color: PosTheme.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.scale_outlined, size: 20, color: PosTheme.accent),
        ),
        const SizedBox(width: 10),
        const Text('称重设备', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 6),
      Text(
          isWin
              ? '适配收银机常用电子秤：键盘口秤免驱即插即用，串口秤（托利多/顶尖/大华等）插上点「自动检测」即可。'
                  '启用后称重弹窗自动读数，秤连上会显示绿色图标。'
              : '适配商米、天波等一体机自带秤（内置秤）和键盘口秤。启用后称重弹窗自动读数，秤连上会显示绿色图标。',
          style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
      const SizedBox(height: 14),
      // 总开关
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(height: 8),
              Text('启用电子秤', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              SizedBox(height: 2),
              Text('称重商品弹窗自动读数；关闭则只能手动输入重量', style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              SizedBox(height: 8),
            ]),
          ),
          Switch(
            value: p.enabled,
            activeColor: PosTheme.accent,
            onChanged: (v) async {
              setState(() => p.enabled = v);
              await _save();
            },
          ),
        ]),
      ),
      if (p.enabled) ...[
        const SizedBox(height: 16),
        const Text('连接方式', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(children: [
          _chip('键盘口（USB-HID，免驱）', p.mode == 'keyboard', () async {
            _stopTest();
            setState(() => p.mode = 'keyboard');
            await _save();
          }),
          if (ScaleSupport.hasSerial)
            _chip('串口（COM / RS232）', p.mode == 'serial', () async {
              _stopTest();
              setState(() => p.mode = 'serial');
              await _save();
            }),
          if (ScaleSupport.hasBuiltin)
            _chip('一体机内置秤（商米等）', p.mode == 'builtin', () async {
              _stopTest();
              setState(() => p.mode = 'builtin');
              await _save();
            }),
        ]),
        if (p.mode == 'keyboard')
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('秤把重量当键盘敲进来自动识别，USB 直插免驱，Windows 和安卓一体机都通用；秤若不发数据，先确认秤已设为「连续发送」。',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
          ),
        if (p.mode == 'builtin')
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('不需要插线，直接读一体机自带秤。个别机型未开放秤接口，读不到时改用键盘口秤即可。',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
          ),
        if (p.mode == 'serial') ...[
          const SizedBox(height: 8),
          Row(children: [
            SizedBox(
              width: 180,
              child: TextField(
                controller: portCtrl,
                decoration: const InputDecoration(labelText: '串口号', hintText: 'COM3', isDense: true),
                onChanged: (_) => _save(),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _pickPort,
              icon: const Icon(Icons.usb, size: 16),
              label: const Text('检测端口'),
            ),
            const SizedBox(width: 14),
            const Text('波特率', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: p.baud,
              items: const [2400, 4800, 9600, 19200, 38400, 115200]
                  .map((b) => DropdownMenuItem(value: b, child: Text('$b')))
                  .toList(),
              onChanged: (v) async {
                if (v == null) return;
                setState(() => p.baud = v);
                await _save();
              },
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              OutlinedButton.icon(
                onPressed: probing ? null : _autoDetect,
                style: OutlinedButton.styleFrom(foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
                icon: probing
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_fix_high, size: 16),
                label: Text(probing ? '检测中…' : '自动检测（推荐）'),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('不用管 COM 号和波特率，系统自己试一遍',
                    style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 14),
        const Text('秤的输出单位', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(children: [
          _chip('自动识别（推荐）', p.unit == 'auto', () async {
            setState(() => p.unit = 'auto');
            await _save();
          }),
          _chip('千克 kg', p.unit == 'kg', () async {
            setState(() => p.unit = 'kg');
            await _save();
          }),
          _chip('克 g', p.unit == 'g', () async {
            setState(() => p.unit = 'g');
            await _save();
          }),
          _chip('斤', p.unit == 'jin', () async {
            setState(() => p.unit = 'jin');
            await _save();
          }),
        ]),
        const Padding(
          padding: EdgeInsets.only(top: 2, bottom: 8),
          child: Text('秤显示什么单位就选什么；「自动识别」按报文里的 kg/g/斤 判断，裸数字按千克处理。',
              style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        ),
        // 测试读数
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: testKg == null ? const Color(0xFFF7F8FA) : const Color(0xFFEAF8F0),
            borderRadius: BorderRadius.circular(10),
            border: testKg == null ? null : Border.all(color: const Color(0xFF2FBF71).withOpacity(0.45)),
          ),
          child: Row(children: [
            if (testKg != null) ...[
              const Icon(Icons.check_circle, size: 20, color: Color(0xFF2FBF71)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  testKg == null ? '测试读数' : '${testKg!.toStringAsFixed(3)} kg  ·  ${(testKg! * 2).toStringAsFixed(2)} 斤',
                  style: TextStyle(
                      fontSize: testKg == null ? 14 : 20,
                      fontWeight: FontWeight.w800,
                      color: testKg == null ? PosTheme.textMain : PosTheme.accent),
                ),
                const SizedBox(height: 3),
                Text(testMsg.isEmpty ? '点右侧按钮，放上商品看是否能读到重量' : testMsg,
                    style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              ]),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: testing ? _stopTest : _startTest,
              style: OutlinedButton.styleFrom(
                foregroundColor: testing ? PosTheme.textSub : PosTheme.accent,
                side: BorderSide(color: testing ? PosTheme.line : PosTheme.accent),
              ),
              icon: Icon(testing ? Icons.stop_circle_outlined : Icons.play_circle_outline, size: 17),
              label: Text(testing ? '停止' : '开始读数'),
            ),
          ]),
        ),
      ],
    ]));
  }
}

/// 副屏（客显）设置卡 v3.3.212
///
/// Windows 双屏收银机：主屏收银，第二块屏给顾客看明细/应收/会员码；
/// 副屏是同程序第二个窗口（--customer-display），只读展示购物车快照。
/// 安卓：本机可作为客显屏——自动搜索局域网内的主收银机并全屏显示客显。
class _CdCard extends StatefulWidget {
  const _CdCard();
  @override
  State<_CdCard> createState() => _CdCardState();
}

class _CdCardState extends State<_CdCard> {
  bool loading = true;
  bool on = false;
  String pos = 'screen2';
  bool busy = false;
  String lanAddr = '';
  bool connecting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await CustomerDisplay.load();
    String addr = '';
    if (CustomerDisplay.running) addr = await CustomerDisplay.lanAddress();
    if (!mounted) return;
    setState(() {
      on = CustomerDisplay.enabled;
      pos = CustomerDisplay.position;
      lanAddr = addr;
      loading = false;
    });
  }

  Future<void> _apply() async {
    setState(() => busy = true);
    await CustomerDisplay.apply();
    final addr = on ? await CustomerDisplay.lanAddress() : '';
    if (!mounted) return;
    setState(() {
      busy = false;
      lanAddr = addr;
    });
    toast(context, CustomerDisplay.enabled ? '副屏已启动' : '副屏已关闭');
  }

  Future<void> _openNow() async {
    final ok = await CustomerDisplay.startServer();
    if (!ok) {
      if (mounted) toast(context, '副屏服务启动失败：端口 19877 被占用', error: true);
      return;
    }
    final w = await CustomerDisplay.openWindow();
    final addr = await CustomerDisplay.lanAddress();
    if (!mounted) return;
    setState(() => lanAddr = addr);
    toast(context, w ? '副屏窗口已打开' : '副屏打开失败（仅 Windows 支持）', error: !w);
  }

  /// 安卓：本机作为客显屏，自动搜索主收银机
  Future<void> _joinAsDisplay() async {
    setState(() => connecting = true);
    await CustomerDisplay.ensureServer(); // 本机若也是收银主机则确保服务在跑
    final found = await CustomerDisplay.discover();
    if (!mounted) return;
    setState(() => connecting = false);
    if (found == null) {
      final typed = await _askHost();
      if (typed == null || typed.isEmpty) return;
      final parts = typed.replaceAll('http://', '').split(':');
      _pushDisplay(parts.first, parts.length > 1 ? int.tryParse(parts[1]) ?? CustomerDisplay.portBase : CustomerDisplay.portBase);
      return;
    }
    _pushDisplay('${found['host']}', (found['port'] as num?)?.toInt() ?? CustomerDisplay.portBase);
  }

  Future<String?> _askHost() async {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连接主收银机'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('自动搜索没找到主收银机，请手动输入它显示在「副屏客显」里的地址，例如 192.168.1.23:19877',
              style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
          const SizedBox(height: 12),
          TextField(
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '192.168.1.23:19877'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('连接')),
        ],
      ),
    );
  }

  void _pushDisplay(String host, int port) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CustomerScreenPage(remoteHost: host, remotePort: port),
    ));
  }

  Widget _chip(String text, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        margin: const EdgeInsets.only(right: 8, bottom: 8),
        decoration: BoxDecoration(
          color: active ? PosTheme.accent.withOpacity(0.1) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: active ? PosTheme.accent : PosTheme.line, width: active ? 1.6 : 1),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? PosTheme.accent : PosTheme.textSub)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const AppCard(child: SizedBox(height: 120, child: Center(child: CircularProgressIndicator())));
    }
    final isWin = Platform.isWindows;
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(color: PosTheme.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.desktop_windows_outlined, size: 20, color: PosTheme.accent),
        ),
        const SizedBox(width: 10),
        const Text('副屏（客显屏）', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 6),
      Text(
          isWin
              ? '收银时第二块屏实时显示商品明细、应收金额和会员激活码。适合双屏收银机，或再用 HDMI 接一台显示器。'
              : '另一台安卓平板 / 手机可以当客显屏：自动搜索同一 Wi-Fi 下的主收银机，全屏显示明细、应收和会员码。',
          style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
      const SizedBox(height: 14),

      // 安卓：本机作为客显屏
      if (!isWin) ...[
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: connecting ? null : _joinAsDisplay,
            style: FilledButton.styleFrom(
                backgroundColor: PosTheme.accent, padding: const EdgeInsets.symmetric(vertical: 14)),
            icon: connecting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.cast_connected, size: 18),
            label: Text(connecting ? '正在搜索主收银机…' : '本机作为客显屏（自动搜索）',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 8),
        const Text('搜索不到时会让手动输入主收银机的地址；连上后本机全屏显示客显，按返回键退出。',
            style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        const SizedBox(height: 16),
      ],

      // 总开关：Windows=开副屏窗口；安卓=开放客显服务给平板
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 8),
              Text(isWin ? '启用副屏' : '让其他设备连本机客显',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                  isWin
                      ? '开启后每次启动自动打开副屏窗口；关闭则只保留主屏'
                      : '开启后本机把购物车同步到局域网，平板/手机客显可自动发现并连接',
                  style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              const SizedBox(height: 8),
            ]),
          ),
          Switch(
            value: on,
            activeColor: PosTheme.accent,
            onChanged: busy ? null : (v) async {
              setState(() => on = v);
              CustomerDisplay.enabled = v;
              await _apply();
            },
          ),
        ]),
      ),

      if (isWin && on) ...[
        const SizedBox(height: 14),
        const Text('副屏位置', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(children: [
          _chip('第二块屏幕铺满', pos == 'screen2', () async {
            setState(() => pos = 'screen2');
            CustomerDisplay.position = 'screen2';
            await _apply();
          }),
          _chip('独立窗口（可拖动）', pos == 'window', () async {
            setState(() => pos = 'window');
            CustomerDisplay.position = 'window';
            await _apply();
          }),
        ]),
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('「第二块屏幕铺满」会按系统里的第 2 台显示器自动定位；只有一台显示器时打开的是可拖动的窗口，把它拖到副屏即可。',
              style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        ),
      ],

      // 配对地址（给安卓平板/手机客显用）
      if (lanAddr.isNotEmpty) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF7FA),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFBEE0EA)),
          ),
          child: Row(children: [
            const Icon(Icons.lan_outlined, size: 18, color: Color(0xFF14708A)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('客显配对地址', style: TextStyle(fontSize: 12, color: Color(0xFF14708A))),
                const SizedBox(height: 2),
                SelectableText(lanAddr,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF0E566B))),
              ]),
            ),
            IconButton(
              tooltip: '复制',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: lanAddr));
                toast(context, '地址已复制');
              },
              icon: const Icon(Icons.copy, size: 17, color: Color(0xFF14708A)),
            ),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('同一 Wi-Fi 下的安卓平板/手机打开收银软件 → 设置 → 副屏客显，会自动搜到这个地址。',
              style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        ),
      ],

      if (isWin) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: busy ? null : _openNow,
            style: OutlinedButton.styleFrom(
                foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('立即打开副屏'),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : () async {
              await CustomerDisplay.closeWindow();
              if (mounted) toast(context, '副屏已关闭');
            },
            style: OutlinedButton.styleFrom(
                foregroundColor: PosTheme.textSub, side: const BorderSide(color: PosTheme.line)),
            icon: const Icon(Icons.close, size: 16),
            label: const Text('关闭副屏'),
          ),
        ]),
      ],

      const SizedBox(height: 10),
      const Text('副屏只读显示，顾客无法操作收银数据；退出登录或重启后按上面的开关自动恢复。',
          style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
    ]));
  }
}
