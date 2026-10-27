import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';
import '../login_page.dart';

/// 设置页（零售/餐饮共用）：店铺信息、云打印、账号、关于
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List printers = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
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
