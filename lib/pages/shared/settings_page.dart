import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/usb_printer.dart';
import '../../core/voice.dart';
import '../../ui/widgets.dart';
import '../login_page.dart';

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

  // 退款密码（null=查询中 / true=已自定义 / false=默认手机号后6位）
  bool? refundPwdCustom;

  @override
  void initState() {
    super.initState();
    _load();
    _loadUsb();
    _loadVoice();
    _loadRefundPwd();
  }

  Future<void> _loadRefundPwd() async {
    try {
      final c = await Api.refundPasswordCustom(Session.wenxunId);
      if (mounted) setState(() => refundPwdCustom = c);
    } on ApiError {
      // 查询失败保持 null（显示未知）
    }
  }

  /// 退款密码卡片：商户级，所有收银员共用；默认商户手机号后6位
  Widget _refundPwdCard() {
    final statusText = refundPwdCustom == null
        ? '状态未知'
        : (refundPwdCustom! ? '已自定义密码' : '默认：商户手机号后6位');
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.lock_outline, '退款密码'),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('订单退款需输入退款密码（商户级，所有收银员共用）',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text('当前状态：$statusText。未自定义时使用商户手机号后6位，修改后所有收银端即时生效。',
              style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
        ])),
        const SizedBox(width: 12),
        SizedBox(
          width: 110,
          child: BigButton('修改密码', onTap: _editRefundPwd,
              color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 44),
        ),
      ]),
    ]));
  }

  Future<void> _editRefundPwd() async {
    final oldCtl = TextEditingController();
    final newCtl = TextEditingController();
    final new2Ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('修改退款密码', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: oldCtl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(fontSize: 17, letterSpacing: 5),
              decoration: InputDecoration(
                counterText: '',
                labelText: refundPwdCustom == false ? '当前密码（商户手机号后6位）' : '当前退款密码',
                prefixIcon: const Icon(Icons.lock_outline, size: 20),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newCtl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(fontSize: 17, letterSpacing: 5),
              decoration: const InputDecoration(
                counterText: '',
                labelText: '新密码（6位数字）',
                prefixIcon: Icon(Icons.lock, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: new2Ctl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(fontSize: 17, letterSpacing: 5),
              decoration: const InputDecoration(
                counterText: '',
                labelText: '确认新密码',
                prefixIcon: Icon(Icons.lock, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('确认修改')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final oldPwd = oldCtl.text.trim();
    final newPwd = newCtl.text.trim();
    if (oldPwd.length != 6 || newPwd.length != 6 || int.tryParse(newPwd) == null) {
      toast(context, '密码须为6位数字', error: true);
      return;
    }
    if (newPwd != new2Ctl.text.trim()) {
      toast(context, '两次输入的新密码不一致', error: true);
      return;
    }
    loadingDialog(context, '保存中…');
    try {
      final r = await Api.setRefundPassword(
        wenxunId: Session.wenxunId,
        oldPassword: oldPwd,
        newPassword: newPwd,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if ('${r['code']}' == '200') {
        toast(context, '${r['msg'] ?? '退款密码已更新'}');
        setState(() => refundPwdCustom = true);
      } else {
        toast(context, '${r['msg'] ?? '修改失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) toast(context, e.message, error: true);
    }
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
          '<CB>测试小票</CB>\n--------------------------------\n稳讯收银桌面版\nUSB打印机：${sel['name']}\n纸张：${usbPaper}mm\n时间：${DateTime.now().toString().substring(0, 19)}\n--------------------------------\n打印正常，可开始收银',
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

  Future<void> _load() async {
    setState(() => loading = true);
    try {
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
      await Api.cloudPrint(
        wenxunId: Session.wenxunId,
        machineCode: '${p['machine_code']}',
        content: '<CB>测试小票</CB>\n--------------------------------\n稳讯收银桌面版\n打印机：${p['name']}\n时间：${DateTime.now().toString().substring(0, 19)}\n--------------------------------\n打印正常，可开始收银',
      );
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '测试小票已发送');
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader('设置'),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), children: [
          // 店铺信息
          AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionTitle(Icons.storefront, '店铺信息'),
            const SizedBox(height: 12),
            Row(children: [
              _info('店铺名称', Session.shopName),
              _info('行业版本', Session.hangye == 2 ? '餐饮版' : (Session.hangye == 3 ? '生鲜版（零售）' : '零售版')),
              _info('店铺电话', Session.shopPhone.isEmpty ? '-' : Session.shopPhone),
            ]),
          ])),
          const SizedBox(height: 14),
          // 云打印
          AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              _sectionTitle(Icons.print_outlined, '云打印机'),
              const Spacer(),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('刷新状态'),
              ),
            ]),
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
              ...printers.map((p) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  Container(width: 9, height: 9, decoration: BoxDecoration(
                      color: '${p['is_online']}' == '1' ? PosTheme.green : PosTheme.textHint, shape: BoxShape.circle)),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${p['name']}', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text('终端号 ${p['machine_code']} · ${_printTypeName(p['print_type'])}',
                        style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
                  ])),
                  TagChip('${p['is_online'] == 1 ? '在线' : '离线'}', color: '${p['is_online']}' == '1' ? PosTheme.green : PosTheme.textHint),
                  const SizedBox(width: 8),
                  TagChip('${p['has_paper'] == 1 ? '有纸' : '缺纸'}', color: '${p['has_paper']}' == '1' ? PosTheme.blue : PosTheme.red),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () => _testPrint(p),
                    style: OutlinedButton.styleFrom(foregroundColor: PosTheme.accent, side: const BorderSide(color: PosTheme.accent)),
                    child: const Text('测试打印'),
                  ),
                ]),
              )),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('打印类型：1 收银小票 · 2 后厨热菜 · 3 面点 · 4 凉菜 · 5 传菜 · 7 交班单（后厨分单由商户后台配置）',
                  style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            ),
          ])),
          const SizedBox(height: 14),
          // USB 打印机
          _usbCard(),
          const SizedBox(height: 14),
          // 语音播报
          _voiceCard(),
          const SizedBox(height: 14),
          // 退款密码
          _refundPwdCard(),
          const SizedBox(height: 14),
          // 账号
          AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
          ])),
          const SizedBox(height: 14),
          // 关于
          AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionTitle(Icons.info_outline, '关于'),
            const SizedBox(height: 10),
            const Text('稳讯收银 桌面版 v3.0.0', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 4),
            const Text('零售 / 餐饮一体化收银 · 云打印 · 会员营销 · 小程序订单同步',
                style: TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
          ])),
        ]),
      ),
    ]);
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

  String _printTypeName(dynamic t) {
    switch ('$t') {
      case '1': return '收银小票';
      case '2': return '后厨热菜';
      case '3': return '面点';
      case '4': return '凉菜';
      case '5': return '传菜';
      case '6': return '采购单';
      case '7': return '交班单';
      default: return '打印机';
    }
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
