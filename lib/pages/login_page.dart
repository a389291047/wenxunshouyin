import 'dart:math';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../core/theme.dart';
import 'shell_page.dart';

/// 收银端登录页（触摸屏版）
/// 左侧：渐变 + 气泡动画品牌区（零售版 / 餐饮版）
/// 右侧：纯触摸交互——手机号数字键盘 / 密码全键盘，适配无物理键盘的安卓收银机
/// 登录成功按商户行业 hangye 路由：1零售 → 零售收银；2餐饮 → 餐饮收银；3生鲜 → 零售收银
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String _phoneVal = '';
  String _pwdVal = '';
  bool _showPwd = false;
  bool _busy = false;
  int _active = 0; // 0=手机号 1=密码（当前键盘作用对象）
  bool _shift = false; // 密码键盘大小写

  Future<void> _login({int? wenxunId}) async {
    final phone = _phoneVal.trim();
    final pwd = _pwdVal;
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      _err('请输入正确的 11 位手机号');
      return;
    }
    if (pwd.length < 4) {
      _err('请输入登录密码');
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await Api.login(phone, pwd, wenxunId);
      final code = int.tryParse('${r['code']}') ?? 0;

      if (code == 300) {
        // 多店铺选择
        final shops = (r['shops'] ?? []) as List;
        if (!mounted) return;
        setState(() => _busy = false);
        final picked = await showDialog<Map>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('选择店铺'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: shops
                  .map((s) => ListTile(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        leading: const Icon(Icons.storefront, color: PosTheme.accent),
                        title: Text('${s['name']}'),
                        onTap: () => Navigator.pop(context, s),
                      ))
                  .toList(),
            ),
          ),
        );
        if (picked != null) {
          await _login(wenxunId: int.tryParse('${picked['wenxun_id']}'));
        }
        return;
      }
      if (code != 200) {
        _err((r['msg'] ?? '登录失败').toString());
        return;
      }
      final data = r['data'];
      if (data == null || int.tryParse('${data['staff_id']}') == null || '${data['staff_id']}'.isEmpty) {
        _err('该账号不是收银员账号，请使用员工账号登录');
        return;
      }
      if ('${data['status'] ?? 1}' == '0') {
        _err('账号已被停用，请联系店主');
        return;
      }
      await Session.save(data);
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const ShellPage()));
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

  // ==================== 触摸输入 ====================
  void _onKey(String k) {
    setState(() {
      if (_active == 0) {
        if (k == '<') {
          if (_phoneVal.isNotEmpty) _phoneVal = _phoneVal.substring(0, _phoneVal.length - 1);
        } else if (k == 'C') {
          _phoneVal = '';
        } else if (_phoneVal.length < 11) {
          _phoneVal += k;
          if (_phoneVal.length == 11) _active = 1; // 输满自动跳密码
        }
      } else {
        if (k == '<') {
          if (_pwdVal.isNotEmpty) _pwdVal = _pwdVal.substring(0, _pwdVal.length - 1);
        } else if (k == 'C') {
          _pwdVal = '';
        } else if (k == '⇧') {
          _shift = !_shift;
        } else if (_pwdVal.length < 32) {
          _pwdVal += _shift ? k.toUpperCase() : k.toLowerCase();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // 左侧品牌区（渐变 + 气泡上飘动画）
          const Expanded(
            flex: 5,
            child: _BrandPanel(),
          ),
          // 右侧登录区（触摸键盘）
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
                      const Text('员工登录', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      const Text('请使用店主分配的收银员账号登录',
                          style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
                      const SizedBox(height: 22),
                      _inputBox(
                        label: '手机号',
                        value: _phoneVal,
                        active: _active == 0,
                        obscure: false,
                        onTap: () => setState(() => _active = 0),
                        onClear: _phoneVal.isEmpty ? null : () => setState(() => _phoneVal = ''),
                      ),
                      const SizedBox(height: 12),
                      _inputBox(
                        label: '登录密码',
                        value: _pwdVal,
                        active: _active == 1,
                        obscure: !_showPwd,
                        onTap: () => setState(() => _active = 1),
                        onClear: _pwdVal.isEmpty ? null : () => setState(() => _pwdVal = ''),
                        trailing: InkWell(
                          onTap: () => setState(() => _showPwd = !_showPwd),
                          borderRadius: BorderRadius.circular(14),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(_showPwd ? Icons.visibility : Icons.visibility_off,
                                size: 20, color: PosTheme.textHint),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _keyboard(),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 56,
                        child: ElevatedButton(
                          onPressed: _busy ? null : () => _login(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: PosTheme.accent,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          child: _busy
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.4))
                              : const Text('登 录'),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text('登录即代表已阅读并同意隐私保护指引',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
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

  // ==================== 输入显示框（替代系统 TextField，防弹系统键盘） ====================
  Widget _inputBox({
    required String label,
    required String value,
    required bool active,
    required bool obscure,
    required VoidCallback onTap,
    VoidCallback? onClear,
    Widget? trailing,
  }) {
    final shown = obscure ? '•' * value.length : value;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 62,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active ? PosTheme.accent : PosTheme.line, width: active ? 2 : 1),
          boxShadow: active ? [BoxShadow(color: PosTheme.accent.withValues(alpha: 0.10), blurRadius: 10, offset: const Offset(0, 2))] : null,
        ),
        child: Row(children: [
          Text(label, style: TextStyle(fontSize: 14, color: active ? PosTheme.accent : PosTheme.textSub, fontWeight: FontWeight.w600)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              value.isEmpty ? '请点击下方键盘输入' : shown,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 19,
                letterSpacing: obscure ? 2 : 1.5,
                color: value.isEmpty ? PosTheme.textHint : PosTheme.textMain,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailing != null) trailing,
          if (onClear != null)
            InkWell(
              onTap: onClear,
              borderRadius: BorderRadius.circular(14),
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.cancel_outlined, size: 20, color: PosTheme.textHint),
              ),
            ),
        ]),
      ),
    );
  }

  // ==================== 触摸键盘 ====================
  static const _letterRows = [
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
  ];

  Widget _keyboard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PosTheme.line),
      ),
      child: _active == 0 ? _phonePad() : _fullPad(),
    );
  }

  /// 手机号：大数字键盘
  Widget _phonePad() {
    return Column(children: [
      _padRow(['1', '2', '3']),
      _padRow(['4', '5', '6']),
      _padRow(['7', '8', '9']),
      Row(children: [
        Expanded(child: _keyBtn('C', label: '清空', isAction: true, color: PosTheme.red)),
        const SizedBox(width: 8),
        Expanded(child: _keyBtn('0')),
        const SizedBox(width: 8),
        Expanded(child: _keyBtn('<', isAction: true, icon: Icons.backspace_outlined)),
      ]),
    ]);
  }

  /// 密码：数字行 + 字母键盘 + 功能键
  Widget _fullPad() {
    return Column(children: [
      _padRow(['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'], compact: true),
      for (final row in _letterRows) _letterRow(row),
      Row(children: [
        Expanded(child: _keyBtn('⇧', isAction: true, active: _shift)),
        const SizedBox(width: 6),
        Expanded(child: _keyBtn('@')),
        const SizedBox(width: 6),
        Expanded(child: _keyBtn('.')),
        const SizedBox(width: 6),
        Expanded(child: _keyBtn('-')),
        const SizedBox(width: 6),
        Expanded(child: _keyBtn('_')),
        const SizedBox(width: 6),
        Expanded(child: _keyBtn('C', label: '清空', isAction: true, color: PosTheme.red)),
        const SizedBox(width: 6),
        Expanded(child: _keyBtn('<', isAction: true, icon: Icons.backspace_outlined)),
      ]),
    ]);
  }

  Widget _padRow(List<String> keys, {bool compact = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        for (int i = 0; i < keys.length; i++) ...[
          Expanded(child: _keyBtn(keys[i], compact: compact)),
          if (i < keys.length - 1) const SizedBox(width: 8),
        ]
      ]),
    );
  }

  Widget _letterRow(List<String> keys) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        // 三行字母梯形对齐：中行缩进少、下行缩进多
        if (keys.length == 9) const SizedBox(width: 18),
        if (keys.length == 7) const SizedBox(width: 52),
        for (int i = 0; i < keys.length; i++) ...[
          Expanded(child: _keyBtn(_shift ? keys[i].toUpperCase() : keys[i])),
          if (i < keys.length - 1) const SizedBox(width: 8),
        ],
        if (keys.length == 9) const SizedBox(width: 18),
        if (keys.length == 7) const SizedBox(width: 52),
      ]),
    );
  }

  Widget _keyBtn(String k, {String? label, bool compact = false, bool isAction = false, bool active = false, Color? color, IconData? icon}) {
    final bg = active
        ? PosTheme.accent
        : isAction
            ? const Color(0xFFF2F3F7)
            : Colors.white;
    final fg = active
        ? Colors.white
        : (isAction && color != null ? color : PosTheme.textMain);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: () => _onKey(k),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: compact ? 42 : 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: isAction || active ? Colors.transparent : PosTheme.line),
          ),
          child: icon != null
              ? Icon(icon, size: 20, color: fg)
              : k == '⇧'
                  ? Icon(Icons.arrow_upward, size: 20, color: fg)
                  : Text(label ?? k, style: TextStyle(fontSize: compact ? 16 : 18, fontWeight: FontWeight.w700, color: fg)),
        ),
      ),
    );
  }
}

// ==================== 登录页左侧品牌面板：渐变底 + 气泡上飘动画 ====================
class _BrandPanel extends StatefulWidget {
  const _BrandPanel();
  @override
  State<_BrandPanel> createState() => _BrandPanelState();
}

class _BrandPanelState extends State<_BrandPanel> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  /// 气泡参数（固定值，避免每次构建随机跳动）：
  /// (水平位置 0~1, 直径px, 速度倍率, 初始相位 0~1, 基础透明度)
  static const _bubbles = [
    (0.08, 110.0, 1.00, 0.00, 0.10),
    (0.18, 54.0, 1.35, 0.30, 0.16),
    (0.28, 150.0, 0.72, 0.62, 0.07),
    (0.38, 34.0, 1.60, 0.85, 0.20),
    (0.47, 76.0, 1.10, 0.45, 0.12),
    (0.57, 42.0, 1.45, 0.15, 0.18),
    (0.66, 180.0, 0.60, 0.78, 0.06),
    (0.74, 58.0, 1.25, 0.52, 0.14),
    (0.84, 90.0, 0.90, 0.22, 0.10),
    (0.92, 38.0, 1.55, 0.68, 0.18),
  ];

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 18))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => CustomPaint(
        painter: _BubblePainter(t: _c.value, bubbles: _bubbles),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: const [
            Text('稳讯收银',
                style: TextStyle(fontSize: 46, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 6)),
            SizedBox(height: 18),
            // 版本徽章：零售版 / 餐饮版
            _VersionBadges(),
          ]),
        ),
      ),
    );
  }
}

/// 零售版 / 餐饮版 徽章
class _VersionBadges extends StatelessWidget {
  const _VersionBadges();
  @override
  Widget build(BuildContext context) {
    Widget badge(String text, IconData icon) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.45), width: 1.2),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 19, color: Colors.white),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, color: Colors.white, letterSpacing: 1)),
        ]),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      badge('零售版', Icons.shopping_bag_outlined),
      const SizedBox(width: 14),
      badge('餐饮版', Icons.restaurant_outlined),
    ]);
  }
}

/// 渐变底色 + 上升气泡绘制
class _BubblePainter extends CustomPainter {
  final double t; // 0~1 循环进度
  final List<(double, double, double, double, double)> bubbles;
  _BubblePainter({required this.t, required this.bubbles});

  @override
  void paint(Canvas canvas, Size size) {
    // 多段渐变底：左上亮橙 → 右下深红，中段过渡
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFFFF9A56),
          Color(0xFFFF6A2C),
          Color(0xFFF4471B),
          Color(0xFFD93212),
        ],
        stops: [0.0, 0.42, 0.75, 1.0],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bgPaint);

    // 左上一团柔光，增加层次
    canvas.drawCircle(
      Offset(size.width * 0.18, size.height * 0.16),
      size.width * 0.42,
      Paint()..color = Colors.white.withValues(alpha: 0.07),
    );

    // 气泡：自下而上飘动，带轻微左右摇摆，淡入淡出
    for (int i = 0; i < bubbles.length; i++) {
      final b = bubbles[i];
      final p = (t * b.$3 + b.$4) % 1.0; // 单个气泡周期进度
      final y = size.height * (1.15 - 1.35 * p);
      final x = size.width * b.$1 + sin((p * 2 + i) * pi) * 16;
      final fade = sin(p * pi); // 起止淡出
      final r = b.$2 / 2;

      final paint = Paint()..color = Colors.white.withValues(alpha: (b.$5 * fade).clamp(0.0, 1.0));
      canvas.drawCircle(Offset(x, y), r, paint);
      // 高光点
      canvas.drawCircle(
        Offset(x - r * 0.32, y - r * 0.32),
        r * 0.22,
        Paint()..color = Colors.white.withValues(alpha: (b.$5 * fade * 0.9).clamp(0.0, 1.0)),
      );
    }
  }

  @override
  bool shouldRepaint(_BubblePainter old) => old.t != t;
}
