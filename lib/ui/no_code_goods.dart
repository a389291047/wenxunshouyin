import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/no_code_common.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// 无码商品/无码菜品弹窗（零售 + 餐饮共用）
///
/// - 金额只能通过弹窗内置 12 宫格数字键盘输入（不用系统键盘），价格默认第一个输入
/// - 商品名称：可选，可用物理/系统键盘输入
/// - 商品数量：可选，默认 1，点数量框后用键盘输入几就加几件，小计 = 单价 × 数量
/// - 名称输入框右侧「常用」按钮（v3.3.179）：点开弹窗展示最多 5 张渐变卡片
///   （自动记录最近 5 条支付成功/加菜成功的无码项），点击一键带入名称与单价
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
  bool numTouched = false; // 数量是否被用户改过（改过则以输入为准，没改过视为 1）
  List<String> common = []; // 常用无码项名称（v3.3.181：非空才在名称框右侧显示「常用」按钮）

  @override
  void initState() {
    super.initState();
    NoCodeCommon.load().then((l) {
      if (mounted) setState(() => common = l);
    });
  }

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
          numTouched = true;
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
        // 数量：纯整数，最多 3 位，以输入的数字为准
        numTouched = true;
        if (num.length < 3) num += k;
      }
    });
  }

  /// 「常用」选择弹窗：最多 5 张渐变卡片（只带名称，价格需手输）
  Future<void> _pickFromCommon() async {
    final items = await NoCodeCommon.load();
    if (!mounted) return;
    if (items.isEmpty) {
      toast(context, '还没有常用项：无码${widget.title == '无码菜品' ? '菜品' : '商品'}支付成功后会自动记录最近 ${NoCodeCommon.max} 条名称');
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.bookmark_border, size: 20, color: PosTheme.accent),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('常用${widget.title}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: PosTheme.textMain))),
              Text('最多 ${NoCodeCommon.max} 条', style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              const SizedBox(width: 8),
              InkWell(
                onTap: () => Navigator.pop(ctx),
                borderRadius: BorderRadius.circular(20),
                child: const SizedBox(width: 34, height: 34, child: Icon(Icons.close, size: 22, color: PosTheme.textHint)),
              ),
            ]),
            const SizedBox(height: 12),
            for (final name in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: () => Navigator.pop(ctx, name),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [const Color(0xFFFF8A50), PosTheme.accent]),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(children: [
                      const Icon(Icons.touch_app_outlined, size: 19, color: Colors.white),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(name,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: Colors.white)),
                      ),
                    ]),
                  ),
                ),
              ),
            const SizedBox(height: 2),
            const Text('点击卡片只带入名称，单价请用下方键盘输入（设置页可删除不用的常用项）',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
          ]),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _pickCommon(picked);
  }

  /// 常用项一键带入：只填名称，价格留给收银员输入（v3.3.181）
  void _pickCommon(String name) {
    setState(() {
      nameCtrl.text = name.trim();
      priceActive = true;
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
          // 名称（可选，物理/系统键盘输入）；有常用项时右内侧显示紧凑「常用」按钮
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
              // suffix 贴在输入内容之后靠右排，不占输入区、不影响正常输入
              suffix: common.isEmpty
                  ? null
                  : InkWell(
                      onTap: _pickFromCommon,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.bookmark_border, size: 17, color: PosTheme.accent),
                          const SizedBox(width: 4),
                          const Text('常用',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                        ]),
                      ),
                    ),
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
              // 首次切到数量框时清掉默认值 1：输入 6 就显示 6，而不是拼成 16
              onTap: () => setState(() {
                priceActive = false;
                if (!numTouched) num = '';
              }),
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
