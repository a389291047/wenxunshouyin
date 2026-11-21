import 'package:flutter/material.dart';
import '../core/theme.dart';

/// 触屏数字键盘（v3.3.251 从无码商品弹窗抽出公用）：
/// 4 行 × 3 列 = 1-9 / 清空 0 末键，键高 56、字号 22，无码商品弹窗与选会员弹窗共用
class NumKeypad extends StatelessWidget {
  const NumKeypad({
    super.key,
    required this.onKey,
    this.showDot = true,   // 末行第三键：true=小数点（数量模式可禁用），false=退格 ⌫
    this.dotActive = true, // showDot 时小数点是否可用（不可用置灰）
    this.keyHeight = 56,
    this.gap = 10,
  });

  /// 按键回调：'1'-'9' / '0' / 'C'（清空）/ '.'（小数点）/ 'B'（退格）
  final ValueChanged<String> onKey;
  final bool showDot;
  final bool dotActive;
  final double keyHeight;
  final double gap;

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];
    final last = showDot ? ['C', '0', '.'] : ['C', '0', 'B'];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final row in [...rows, last])
        Padding(
          padding: EdgeInsets.only(bottom: identical(row, last) ? 0 : gap),
          child: Row(children: [
            for (int i = 0; i < row.length; i++) ...[
              if (i > 0) SizedBox(width: gap),
              Expanded(child: _btn(row[i])),
            ],
          ]),
        ),
    ]);
  }

  Widget _btn(String k) {
    final isClear = k == 'C';
    final dim = k == '.' && !dotActive;
    return InkWell(
      onTap: dim ? null : () => onKey(k),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: keyHeight,
        decoration: BoxDecoration(
          color: dim ? const Color(0xFFF2F3F7) : (isClear ? const Color(0xFFFFF0EF) : const Color(0xFFF7F8FA)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: k == 'B'
              ? const Icon(Icons.backspace_outlined, size: 22, color: PosTheme.textSub)
              : isClear
                  ? const Text('清空', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.red))
                  : Text(k, style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700,
                      color: dim ? PosTheme.textHint : PosTheme.textMain)),
        ),
      ),
    );
  }
}
