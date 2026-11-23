import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/theme.dart';
import '../ui/agreement.dart';
import '../ui/widgets.dart';
import 'login_page.dart' show BrandPanel;

/// 商家自助注册页
/// 注册 = 创建商户 + 默认分类 + 会员等级 + 店长账号，成功后用手机号+密码直接登录
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});
  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pwd = TextEditingController();
  final _pwd2 = TextEditingController();
  int _hangye = 1; // 1零售 2餐饮 3生鲜
  bool _agree = false;
  bool _showPwd = false;
  bool _busy = false;

  static const _hangyeList = [
    (1, '零售版', Icons.shopping_bag_outlined),
    (2, '餐饮版', Icons.restaurant_outlined),
    (3, '生鲜版', Icons.eco_outlined),
  ];

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _pwd.dispose();
    _pwd2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final pwd = _pwd.text;
    final pwd2 = _pwd2.text;
    if (name.isEmpty) return _err('请输入店铺名称');
    if (name.length > 30) return _err('店铺名称最多 30 个字');
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) return _err('请输入正确的 11 位手机号');
    if (pwd.length < 6) return _err('密码至少 6 位');
    if (pwd != pwd2) return _err('两次密码输入不一致');
    if (!_agree) return _err('请先阅读并勾选同意协议');

    setState(() => _busy = true);
    try {
      final r = await Api.register(name: name, phone: phone, password: pwd, hangye: _hangye);
      if (!mounted) return;
      if (int.tryParse('${r['code']}') != 200) {
        _err((r['msg'] ?? '注册失败').toString());
        return;
      }
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Row(children: const [
            Icon(Icons.check_circle, color: PosTheme.green, size: 24),
            SizedBox(width: 8),
            Text('注册成功'),
          ]),
          content: Text('店铺「$name」已创建。\n\n请用手机号 $phone 和刚设置的密码登录，账号角色为店长。',
              style: const TextStyle(height: 1.6)),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context), // 关弹窗
              style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
              child: const Text('去登录'),
            ),
          ],
        ),
      ).then((_) {
        if (mounted) Navigator.pop(context, phone); // 回登录页并预填手机号
      });
    } on ApiError catch (e) {
      _err(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _err(String msg) {
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: PosTheme.red,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          const Expanded(flex: 5, child: BrandPanel()),
          Expanded(
            flex: 4,
            child: Container(
              color: const Color(0xFFFAFBFC),
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 28),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Text('注册商家', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      const Text('注册即创建店铺，账号角色为店长',
                          style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
                      const SizedBox(height: 22),
                      _field(label: '店铺名称', controller: _name, hint: '例如：稳讯便利店', maxLength: 30),
                      const SizedBox(height: 14),
                      // 行业选择
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('经营行业', style: TextStyle(fontSize: 13.5, color: PosTheme.textSub, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Row(children: [
                          for (int i = 0; i < _hangyeList.length; i++) ...[
                            Expanded(child: _hangyeChip(_hangyeList[i])),
                            if (i < _hangyeList.length - 1) const SizedBox(width: 10),
                          ],
                        ]),
                      ]),
                      const SizedBox(height: 14),
                      _field(label: '手机号', controller: _phone, hint: '11 位手机号（同时作为登录账号）',
                          keyboardType: TextInputType.phone, maxLength: 11),
                      const SizedBox(height: 14),
                      _field(label: '登录密码', controller: _pwd, hint: '至少 6 位', obscure: !_showPwd, maxLength: 32,
                          trailing: IconButton(
                            onPressed: () => setState(() => _showPwd = !_showPwd),
                            icon: Icon(_showPwd ? Icons.visibility : Icons.visibility_off, size: 20, color: PosTheme.textHint),
                          )),
                      const SizedBox(height: 14),
                      _field(label: '确认密码', controller: _pwd2, hint: '再输入一次密码', obscure: true, maxLength: 32),
                      const SizedBox(height: 12),
                      AgreementCheck(value: _agree, onChanged: (v) => setState(() => _agree = v)),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 56,
                        child: ElevatedButton(
                          onPressed: _busy ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: PosTheme.accent,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          child: _busy
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.4))
                              : const Text('注 册'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        child: const Text('已有账号？返回登录',
                            style: TextStyle(fontSize: 14, color: PosTheme.textSub)),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 控件 ====================

  Widget _hangyeChip((int, String, IconData) item) {
    final on = _hangye == item.$1;
    return InkWell(
      onTap: () => setState(() => _hangye = item.$1),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: on ? PosTheme.accent.withValues(alpha: 0.08) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line, width: on ? 2 : 1),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(item.$3, size: 18, color: on ? PosTheme.accent : PosTheme.textSub),
          const SizedBox(width: 6),
          Text(item.$2, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600,
              color: on ? PosTheme.accent : PosTheme.textMain)),
        ]),
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    TextInputType? keyboardType,
    int? maxLength,
    Widget? trailing,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      PosField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        maxLength: maxLength,
        compact: true,
        hint: hint,
        suffix: trailing,
      ),
    ]);
  }
}
