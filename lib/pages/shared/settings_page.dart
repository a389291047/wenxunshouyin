import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/print_prefs.dart';
import '../../core/printer_route.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/usb_printer.dart';
import '../../core/updater.dart';
import '../../core/voice.dart';
import '../../ui/receipt_preview.dart';
import '../../ui/update_dialog.dart';
import '../../ui/widgets.dart';
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
  Map<String, dynamic>? usbSelected;
  List<Map<String, dynamic>> usbPrinters = [];

  // 语音播报
  bool voiceEnabled = true;

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
  bool cloudSyncing = false; // 正在与云端同步
  bool cloudSyncOk = true; // 上次云端同步结果（false=断网，仅本机生效）

  @override
  void initState() {
    super.initState();
    _load();
    _loadUsb();
    _loadVoice();
    _loadPrintPrefs();
    _loadStaffs();
    _loadRoute();
  }

  /// 加载打印机绑定配置：先与云端同步（换电脑/换账号自动拉取），再读本机缓存
  Future<void> _loadRoute() async {
    if (Session.hangye != 2) return;
    final wid = '${Session.wenxunId}';
    if (mounted) setState(() => cloudSyncing = true);
    final ok = await PrinterRoute.syncFromCloud(wid);
    final rf = await PrinterRoute.riceFrontOnly(wid);
    final pcs = await PrinterRoute.printerCfgs(wid);
    if (!mounted) return;
    setState(() {
      riceFrontOnly = rf;
      printerCfgs = pcs;
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
    for (final it in PrintPrefs.items) {
      m[it['key']!] = await PrintPrefs.on(it['key']!);
    }
    if (mounted) setState(() => printOn = m);
  }

  /// 小票打印设置卡片（v3.3.78）：按行业分开（餐饮/零售）+ 每类独立开关 + 样式预览 + 测试打印
  Widget _printPrefsCard() {
    // 餐饮跟零售分开：餐饮版显示餐饮专属类，零售/生鲜版只显示零售专属类，通用类两边都显示
    final visible = PrintPrefs.itemsForHangye(Session.hangye);
    String? lastScope;
    final rows = <Widget>[];
    for (final it in visible) {
      final scope = it['scope'] ?? 'all';
      if (scope != lastScope) {
        final header = switch (scope) {
          'dining' => '餐饮小票',
          'retail' => '零售小票',
          _ => '通用小票',
        };
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 6),
          child: Row(children: [
            Container(width: 3, height: 12, decoration: BoxDecoration(color: PosTheme.accent, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 6),
            Text(header, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.textMain)),
          ]),
        ));
        lastScope = scope;
      }
      final key = it['key']!;
      final on = printOn[key] ?? true;
      rows.add(Container(
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 7),
            Text(it['label']!, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: on ? PosTheme.textMain : PosTheme.textHint)),
            const SizedBox(height: 1),
            Text(it['desc']!, style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            const SizedBox(height: 7),
          ])),
          TextButton.icon(
            onPressed: () => _previewTicket(key, it['label']!),
            style: TextButton.styleFrom(foregroundColor: PosTheme.blue, padding: const EdgeInsets.symmetric(horizontal: 10)),
            icon: const Icon(Icons.visibility_outlined, size: 15),
            label: const Text('预览'),
          ),
          Switch(
            value: on,
            activeColor: PosTheme.accent,
            onChanged: (v) async {
              setState(() => printOn[key] = v);
              await PrintPrefs.set(key, v);
            },
          ),
        ]),
      ));
    }
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.receipt_long_outlined, '小票打印设置'),
      const SizedBox(height: 4),
      const Text('按小票类型控制「打印 / 不打印」，云打印与 USB 直连同时生效。关闭后对应小票不再输出。',
          style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
      const SizedBox(height: 10),
      ...rows,
    ]));
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
        ], font: _fontOfRole('kitchen'));
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
          cart: const [{'goods_name': '水煮牛肉', 'quantity': 1}], title: '退菜单', font: _fontOfRole('kitchen'));
      case 'urge':
        return CloudPrinter.kitchenTicket(tableTitle: '大厅8', tableQuyu: '大厅',
          cart: const [{'goods_name': '清蒸鲈鱼', 'quantity': 1}], title: '催菜单', font: _fontOfRole('kitchen'));
      case 'reprint':
        return CloudPrinter.kitchenTicket(tableTitle: '大厅8', tableQuyu: '大厅',
          cart: const [{'goods_name': '水煮牛肉', 'quantity': 1}, {'goods_name': '米饭', 'quantity': 4}], title: '后厨单重打', font: _fontOfRole('kitchen'));
      case 'queue':
        return '<FS2><center>排队号</center></FS2>\n--------------------------------\n您的号码：\n<FS2><center>** 12 **</center></FS2>\n2 位 · 前方 3 桌\n时间: $now\n请留意叫号，过号重排\n';
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
                      Text('接收未分配分类（兜底/双打）', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      SizedBox(height: 2),
                      Text('开启后没有分配到任何打印机的菜也发本机；多台都开=每台都打完整一份',
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

  Future<void> _loadUsb() async {
    if (!UsbPrinter.supported) return;
    final sp = await SharedPreferences.getInstance();
    setState(() {
      usbEnabled = sp.getBool(UsbPrinter.prefEnabled) ?? false;
      usbPaper = sp.getInt(UsbPrinter.prefPaper) ?? 58;
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
      await UsbPrinter.printTicket(sel,
          '<FS2><center>测试小票</center></FS2>\n--------------------------------\n稳讯收银桌面版\nUSB打印机：${sel['name']}\n纸张：${usbPaper}mm\n时间：${DateTime.now().toString().substring(0, 19)}\n--------------------------------\n打印正常，可开始收银',
          paperWidth: usbPaper);
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
      const Text('检查到新版本后由您确认下载安装。更新仅替换程序文件，不影响本地配置（云打印/USB打印/打印开关等）与业务数据（数据在服务器）。',
          style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
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

  Future<void> _testPrint(Map p) async {
    loadingDialog(context, '发送测试小票…');
    try {
      // 已绑定前台/后厨的机：按本机绑定配置（含字体大小）打对应测试单，直接看字体效果
      final cfg = printerCfgs['${p['machine_code']}'];
      final bound = Session.hangye == 2 && cfg != null && cfg.role.isNotEmpty;
      final content = bound
          ? '${CloudPrinter.kitchenTicket(
              tableTitle: '大厅8',
              tableQuyu: '大厅',
              isAdd: cfg.role == 'kitchen',
              title: cfg.role == 'kitchen' ? '后厨测试单' : '前台测试单',
              remark: '测试：菜名字体大小',
              cart: [
                {'goods_name': '水煮牛肉', 'quantity': 1, 'remark': '微辣·少麻'},
                {'goods_name': '米饭', 'quantity': 4},
                {'goods_name': '酸辣土豆丝', 'quantity': 1},
              ],
              font: cfg.font,
            )}打印正常，可开始出票'
          : '<FS2><center>测试小票</center></FS2>\n--------------------------------\n稳讯收银桌面版\n打印机：${p['name']}\n时间：${DateTime.now().toString().substring(0, 19)}\n--------------------------------\n打印正常，可开始收银';
      await Api.cloudPrint(
        wenxunId: Session.wenxunId,
        machineCode: '${p['machine_code']}',
        content: content,
      );
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '测试小票已发送');
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  // ==================== 左右布局（v3.3.79）：左侧导航菜单 + 右侧内容 ====================
  String _nav = 'store';

  static const List<Map<String, Object>> _navDefs = [
    {'key': 'store',    'icon': Icons.storefront,           'label': '店铺信息'},
    {'key': 'update',   'icon': Icons.system_update_alt,    'label': '在线更新'},
    {'key': 'cloud',    'icon': Icons.print_outlined,       'label': '云打印机'},
    {'key': 'usb',      'icon': Icons.usb_outlined,         'label': 'USB打印'},
    {'key': 'receipt',  'icon': Icons.receipt_long_outlined,'label': '小票打印设置'},
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
      list.add(it);
    }
    return list;
  }

  Widget _navContent(String key) {
    switch (key) {
      case 'update':  return _updateCard();
      case 'cloud':   return _cloudCard();
      case 'usb':     return _usbCard();
      case 'receipt': return _printPrefsCard();
      case 'voice':   return _voiceCard();
      case 'password':return _refundPwdCard();
      case 'account': return _accountCard();
      case 'kefu':    return _kefuCard();
      case 'about':   return _aboutCard();
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
                    color: sel ? PosTheme.accent.withOpacity(0.1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => setState(() => _nav = '${n['key']}'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                        child: Row(children: [
                          Icon(n['icon'] as IconData, size: 18,
                              color: sel ? PosTheme.accent : PosTheme.textSub),
                          const SizedBox(width: 10),
                          Expanded(child: Text('${n['label']}',
                              style: TextStyle(fontSize: 13.5,
                                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                                  color: sel ? PosTheme.accent : PosTheme.textMain))),
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
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _testPrint(p),
                style: OutlinedButton.styleFrom(foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
                child: const Text('测试打印'),
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
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('打印类型：1 收银小票 · 2 后厨热菜 · 3 面点 · 4 凉菜 · 5 传菜 · 7 交班单（前台/后厨绑定在上方「配置」里设置）',
            style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
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
      // 纸张宽度 + 测试
      const SizedBox(height: 4),
      Row(children: [
        const Text('纸张宽度', style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
        const SizedBox(width: 10),
        _paperChip(58),
        const SizedBox(width: 8),
        _paperChip(80),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: usbSelected == null ? null : _usbTest,
          style: OutlinedButton.styleFrom(foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
          icon: const Icon(Icons.local_printshop_outlined, size: 16),
          label: const Text('测试打印'),
        ),
      ]),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('提示：USB 打印需热敏小票机（ESC/POS 协议）。关闭开关时小票自动改走云打印机。',
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

  Widget _paperChip(int w) {
    final sel = usbPaper == w;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        setState(() => usbPaper = w);
        await _saveUsbPrefs();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? PosTheme.accent : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sel ? PosTheme.accent : PosTheme.textHint.withOpacity(0.4)),
        ),
        child: Text('${w}mm',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: sel ? Colors.white : PosTheme.textSub)),
      ),
    );
  }

  Widget _sectionTitle(IconData icon, String text) {
    return Row(children: [
      Icon(icon, size: 19, color: PosTheme.accent),
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
