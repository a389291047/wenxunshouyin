import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';

/// 收银台自带触屏键盘（v3.3.221）
///
/// 为什么要自己做：Windows 系统触摸键盘（TabTip）在 v3.3.209 被主动关闭
/// （点任何输入框都乱弹、挡住半屏），于是触摸屏收银机上的搜索框只能靠扫码枪。
/// 顾客自己点单时没法输商品名，这里补一个应用内键盘。
///
/// 中文输入靠商品资料的「简拼」字段（jianpin，如「苹果」= pg），
/// 顾客按 26 个字母键即可搜到商品，不需要中文输入法。
class TouchKeyboard extends StatelessWidget {
  const TouchKeyboard({
    super.key,
    required this.onInput,
    required this.onBackspace,
    required this.onClear,
    required this.onClose,
    this.hintText = '',
    this.keyHeight = 40,
  });

  /// 字母/数字键（小写，展示时转大写）
  final ValueChanged<String> onInput;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onClose;

  /// 键盘上方提示条（当前输入 + 匹配数量），空则不显示提示文字
  final String hintText;
  final double keyHeight;

  static const _digits = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
  static const _row1 = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
  static const _row2 = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
  static const _row3 = ['z', 'x', 'c', 'v', 'b', 'n', 'm'];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F9),
        border: const Border(top: BorderSide(color: PosTheme.line)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 14,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _hintBar(),
          const SizedBox(height: 6),
          // v3.3.226：10 列等宽网格对齐——字母键四行同宽同样式；
          // 功能键按格数跨列（⌫ 占 1 格、清空 1 格、收起键盘 2 格），不再用空格键。
          LayoutBuilder(builder: (context, c) {
            final pitch = c.maxWidth / 10; // 每格宽度
            Widget cell(String k) => _cell(
                _key(k.toUpperCase(), onTap: () => onInput(k)), pitch);
            return Column(
              children: [
                Row(children: [for (final k in _digits) cell(k)]),
                const SizedBox(height: 6),
                Row(children: [for (final k in _row1) cell(k)]),
                const SizedBox(height: 6),
                Row(children: [
                  for (final k in _row2) cell(k),
                  _cell(
                      _key('⌫',
                          onTap: onBackspace,
                          bg: const Color(0xFFE9EBF0),
                          fg: PosTheme.textMain),
                      pitch),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  for (final k in _row3) cell(k),
                  _cell(
                      _key('清空',
                          onTap: onClear,
                          bg: const Color(0xFFE9EBF0),
                          fg: PosTheme.textMain,
                          fontSize: 15),
                      pitch),
                  _span(
                      _key('收起键盘',
                          onTap: onClose,
                          bg: PosTheme.accentLive,
                          fg: Colors.white,
                          fontSize: 15,
                          bold: true),
                      pitch,
                      2),
                ]),
              ],
            );
          }),
        ],
      ),
    );
  }

  /// 单格键：固定占 1 列宽（pitch），内边距 3 形成键间 6px 间隙
  Widget _cell(Widget key, double pitch) => SizedBox(
        width: pitch,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: key,
        ),
      );

  /// 跨格键：占 n 列宽（含格间间隙）
  Widget _span(Widget key, double pitch, int n) => SizedBox(
        width: pitch * n,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: key,
        ),
      );

  /// 顶部提示条：当前输入什么、匹配到几个商品
  Widget _hintBar() {
    return SizedBox(
      height: 24,
      child: Row(children: [
        Icon(Icons.touch_app_outlined, size: 16, color: PosTheme.accentLive),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            hintText.isEmpty ? '输入商品简拼（如 pg = 苹果）或条码数字' : hintText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 13.5, color: PosTheme.textSub, fontWeight: FontWeight.w500),
          ),
        ),
      ]),
    );
  }

  Widget _key(
    String label, {
    required VoidCallback onTap,
    Color bg = Colors.white,
    Color fg = PosTheme.textMain,
    double fontSize = 17,
    bool bold = false,
  }) {
    return SizedBox(
      height: keyHeight,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(9),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            // 触屏按下给一点反馈；桌面/无马达环境无副作用
            try {
              HapticFeedback.selectionClick();
            } catch (_) {}
            onTap();
          },
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
