import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// 无码商品/无码菜品弹窗（零售 + 餐饮共用）
///
/// - 金额只能通过弹窗内置 12 宫格数字键盘输入（不用系统键盘），价格默认第一个输入
/// - 商品名称：可选，可用物理/系统键盘输入
/// - 商品数量：可选，默认 1，点数量框后用键盘输入几就加几件，小计 = 单价 × 数量
///
/// 返回 {'name': String, 'amount': double, 'num': int}；取消返回 null
class NoCodeGoodsDialog extends StatefulWidget {
  final String title; // '无码商品' / '无码菜品'
  const NoCodeGoodsDialog({super.key, this.title = '无码商品'});
  @override
  State<NoCodeGoodsDialog> createState() => _NoCodeGoodsDialogState();
}

class _NoCodeGoodsDialogState extends State<NoCodeGoodsDialog> {
  final nameCtrl = TextEditingController();
  String price = ''; // 金额（数字键盘输入）
  String num = '1'; // 数量（默认 1）
  bool priceActive = true; // 当前键盘作用域：true=单价（默认第一个）

  double get amount => double.tryParse(price) ?? 0;
  int get qty => (int.tryParse(num) ?? 0) < 1 ? 1 : int.tryParse(num)!;
  double get subtotal => amount * qty;

  void _key(String k) {
    setState(() {
      if (k == 'C') {
        // 清空当前作用域
        if (priceActive) {
          price = '';
        } else {
          num = '';
        }
        return;
      }
      if (priceActive) {
        // 金额：整数最多 6 位、小数最多 2 位
        if (k == '.') {
          if (!price.contains('.')) price = price.isEmpty ? '0.' : '$price.';
        } else {
          final dot = price.indexOf('.');
          if (dot == -1) {
            if (price.length < 6) price += k;
          } else if (price.length - dot - 1 < 2) {
            price += k;
          }
        }
      } else if (k != '.') {
        // 数量：纯整数，最多 3 位
        if (num.length < 3) num += k;
      }
    });
  }

  void _confirm() {
    if (amount <= 0) return;
    FocusScope.of(context).unfocus();
    Navigator.pop(context, {
      'name': nameCtrl.text.trim().isEmpty ? widget.title : nameCtrl.text.trim(),
      'amount': amount,
      'num': qty,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 620,
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 标题
          Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(color: PosTheme.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.keyboard_outlined, size: 24, color: PosTheme.accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const Text('金额必填 · 名称、数量可不填（数量默认 1）', style: TextStyle(fontSize: 13, color: PosTheme.textHint)),
              ]),
            ),
            InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(20),
              child: const SizedBox(width: 40, height: 40, child: Icon(Icons.close, size: 26, color: PosTheme.textHint)),
            ),
          ]),
          const SizedBox(height: 20),
          // 名称（可选，物理/系统键盘输入）
          TextField(
            controller: nameCtrl,
            maxLength: 30,
            inputFormatters: [LengthLimitingTextInputFormatter(30)],
            style: const TextStyle(fontSize: 17),
            decoration: InputDecoration(
              counterText: '',
              hintText: '${widget.title}名称（可选）',
              prefixIcon: const Icon(Icons.edit_outlined, size: 20),
              contentPadding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
          const SizedBox(height: 14),
          // 单价 / 数量 两个输入展示块（点击切换键盘作用域）
          Row(children: [
            Expanded(child: _fieldBox(
              label: '单价 ¥',
              value: price.isEmpty ? '0.00' : price,
              active: priceActive,
              onTap: () => setState(() => priceActive = true),
              valueColor: amount > 0 ? PosTheme.accent : PosTheme.textHint,
            )),
            const SizedBox(width: 14),
            Expanded(child: _fieldBox(
              label: '数量',
              value: num.isEmpty ? '1' : num,
              active: !priceActive,
              onTap: () => setState(() => priceActive = false),
              valueColor: PosTheme.textMain,
            )),
          ]),
          const SizedBox(height: 14),
          // 小计条：单价 × 数量 = 小计
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7F4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Text('单价 ¥${Fmt.money(amount)}', style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.close, size: 13, color: PosTheme.textHint),
              ),
              Text('数量 ${num.isEmpty ? 1 : num}', style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
              const Spacer(),
              const Text('小计', style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
              const SizedBox(width: 8),
              Text('¥${Fmt.money(subtotal)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: PosTheme.accent)),
            ]),
          ),
          const SizedBox(height: 14),
          // 内置 12 宫格数字键盘（写死，金额只能在这里输入）
          _keypad(),
          const SizedBox(height: 18),
          BigButton(
            amount > 0 ? '加入购物车  ¥${Fmt.money(subtotal)}' : '请先输入单价',
            onTap: amount > 0 ? _confirm : null,
            height: 60,
          ),
        ]),
      ),
    );
  }

  Widget _fieldBox({required String label, required String value, required bool active, required VoidCallback onTap, required Color valueColor}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFFFF7F4) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? PosTheme.accent : PosTheme.line, width: active ? 2 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(label, style: TextStyle(fontSize: 13, color: active ? PosTheme.accent : PosTheme.textSub, fontWeight: active ? FontWeight.w700 : FontWeight.w400)),
            const Spacer(),
            if (active) const Icon(Icons.edit, size: 15, color: PosTheme.accent),
          ]),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: valueColor)),
        ]),
      ),
    );
  }

  /// 12 宫格：1-9 / 清空 0 .
  Widget _keypad() {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['C', '0', '.'],
    ];
    return Column(children: [
      for (final row in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            for (int i = 0; i < row.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(child: _keyBtn(row[i])),
            ],
          ]),
        ),
    ]);
  }

  Widget _keyBtn(String k) {
    final isClear = k == 'C';
    final dim = k == '.' && !priceActive; // 数量模式下小数点不可用
    return InkWell(
      onTap: dim ? null : () => _key(k),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: dim ? const Color(0xFFF2F3F7) : (isClear ? const Color(0xFFFFF0EF) : const Color(0xFFF7F8FA)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: isClear
              ? const Text('清空', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.red))
              : Text(k, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: dim ? PosTheme.textHint : PosTheme.textMain)),
        ),
      ),
    );
  }
}
