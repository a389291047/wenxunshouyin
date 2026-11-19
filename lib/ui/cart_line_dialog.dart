import 'package:flutter/material.dart';

import '../core/clear_pin.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// 单行编辑结果
class CartLineEdit {
  final double num;
  final double? price; // null = 按商品原价
  final double giftQty; // 赠送数量（0=无；称重商品单位同商品，随小票打 0 元行）v3.3.231
  final bool deleted;
  const CartLineEdit({
    required this.num,
    this.price,
    this.giftQty = 0,
    this.deleted = false,
  });
}

/// 打开「单个商品」操作弹窗（v3.3.205；v3.3.231 备注改为赠送数量）
///
/// 收银页购物车里点某一行商品即可打开，支持：
/// - 改数量（步进 + 数字键盘直接输入）
/// - 改价（原价 / 9折 / 8.5折 / 8折 / 自定义单价，可配置权限密码）
/// - 赠送数量（自定义输入，买2送1输1；称重买0.5kg送0.25kg输0.25，随小票打 0 元行）
/// - 删除该商品（可撤销）
///
/// 返回 null 表示取消；否则返回编辑结果。
Future<CartLineEdit?> showCartLineDialog(
  BuildContext context, {
  required String title,
  String subtitle = '',
  required double listPrice,
  required double num,
  double giftQty = 0,
  double? price,
  bool byWeight = false,
  String unit = '',
  Color? accent,
  Future<bool> Function()? onNeedPriceAuth,
}) {
  return showDialog<CartLineEdit>(
    context: context,
    builder: (_) => CartLineDialog(
      title: title,
      subtitle: subtitle,
      listPrice: listPrice,
      num: num,
      giftQty: giftQty,
      price: price,
      byWeight: byWeight,
      unit: unit,
      accent: accent ?? PosTheme.accentLive,
      onNeedPriceAuth: onNeedPriceAuth,
    ),
  );
}

class CartLineDialog extends StatefulWidget {
  final String title;
  final String subtitle;
  final double listPrice;
  final double num;
  final double giftQty;
  final double? price;
  final bool byWeight;
  final String unit;
  final Color accent;
  final Future<bool> Function()? onNeedPriceAuth;

  const CartLineDialog({
    super.key,
    required this.title,
    this.subtitle = '',
    required this.listPrice,
    required this.num,
    this.giftQty = 0,
    this.price,
    this.byWeight = false,
    this.unit = '',
    this.accent = PosTheme.accent,
    this.onNeedPriceAuth,
  });

  @override
  State<CartLineDialog> createState() => _CartLineDialogState();
}

class _CartLineDialogState extends State<CartLineDialog> {
  late double qty = widget.num;
  late double? price = widget.price;
  late double giftQty = widget.giftQty;

  Color get accent => widget.accent;
  double get unitPrice => price ?? widget.listPrice;

  /// 应付数量 = 数量 - 赠送数量（赠送不计价，v3.3.232）
  double get payNum {
    final v = qty - giftQty;
    return v > 0 ? v : 0;
  }

  double get sub => unitPrice * payNum;
  String get unit => widget.unit.trim();

  /// 数量展示：按件整数 / 称重去尾零
  String get qtyText {
    if (!widget.byWeight) return '${qty.round()}';
    var s = qty.toStringAsFixed(3);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return s.isEmpty ? '0' : s;
  }

  /// 赠送数量展示：按件 x1 / 称重 0.25kg
  String giftText(double g) {
    if (g <= 0) return '';
    if (!widget.byWeight) return 'x${g.round()}';
    var s = g.toStringAsFixed(3);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return '${s.isEmpty ? '0' : s}${unit.isEmpty ? '' : ' $unit'}';
  }

  /// 改价前校验权限（未开启则直接通过）
  Future<bool> _authPrice() async {
    final f = widget.onNeedPriceAuth;
    if (f == null) return true;
    final ok = await f();
    return ok && mounted;
  }

  void _bump(int delta) {
    final next = qty + delta;
    setState(() => qty = next < 1 ? 1 : next);
  }

  Future<void> _inputQty() async {
    final v = await showNumberPad(
      context,
      title: '修改数量',
      initial: qtyText,
      decimal: widget.byWeight,
      unit: widget.byWeight ? unit : '',
      hint: widget.byWeight ? '称重商品最多 3 位小数' : '输入整数件数',
    );
    if (v == null || v <= 0 || !mounted) return;
    setState(() => qty = widget.byWeight ? double.parse(v.toStringAsFixed(3)) : v.roundToDouble());
  }

  Future<void> _inputPrice() async {
    if (!await _authPrice()) return;
    if (!mounted) return;
    final v = await showNumberPad(
      context,
      title: '修改单价',
      initial: Fmt.money(unitPrice),
      decimal: true,
      prefix: '¥',
      hint: '原价 ¥${Fmt.money(widget.listPrice)}',
    );
    if (v == null || v < 0 || !mounted) return;
    setState(() => price = double.parse(v.toStringAsFixed(2)));
  }

  Future<void> _applyDiscount(double rate) async {
    if (rate >= 1) {
      // 回到原价不需要校验
      setState(() => price = null);
      return;
    }
    if (!await _authPrice()) return;
    if (!mounted) return;
    setState(() => price = double.parse((widget.listPrice * rate).toStringAsFixed(2)));
  }

  /// 赠送数量：自定义数字键盘输入（按件整数 / 称重 3 位小数）
  Future<void> _inputGift() async {
    final v = await showNumberPad(
      context,
      title: '赠送数量',
      initial: giftQty > 0 ? giftText(giftQty).replaceAll(RegExp(r'[a-zA-Z ]+$'), '') : '',
      decimal: widget.byWeight,
      unit: widget.byWeight ? unit : '',
      hint: widget.byWeight ? '买0.5kg送0.25kg就输0.25（称重最多 3 位小数）' : '买2送1就输1（按件为整数）',
    );
    if (v == null || v <= 0 || !mounted) return;
    setState(() {
      giftQty = widget.byWeight ? double.parse(v.toStringAsFixed(3)) : v.roundToDouble();
    });
  }

  void _delete() => Navigator.pop(context, const CartLineEdit(num: 0, deleted: true));

  void _done() => Navigator.pop(
        context,
        CartLineEdit(num: qty, price: price, giftQty: giftQty),
      );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 560,
        // 小屏（安卓一体机）高度不够时可滚动，避免溢出
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
        child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 标题
          Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.shopping_bag_outlined, size: 23, color: accent),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                Text(
                  widget.subtitle.isNotEmpty
                      ? '${widget.subtitle} · 原价 ¥${Fmt.money(widget.listPrice)}'
                      : '原价 ¥${Fmt.money(widget.listPrice)}${widget.byWeight && unit.isNotEmpty ? ' / $unit' : ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint),
                ),
              ]),
            ),
            InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(20),
              child: const SizedBox(width: 38, height: 38, child: Icon(Icons.close, size: 24, color: PosTheme.textHint)),
            ),
          ]),
          const SizedBox(height: 16),

          // 数量 + 小计
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('数量', style: TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: _inputQty,
                    borderRadius: BorderRadius.circular(8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(widget.byWeight ? '$qtyText${unit.isEmpty ? '' : ' $unit'}' : qtyText,
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                      const SizedBox(width: 6),
                      Icon(Icons.edit_outlined, size: 15, color: accent),
                    ]),
                  ),
                ]),
              ),
              _stepBtn(Icons.remove, () => _bump(-1), enabled: qty > 1),
              Container(
                width: 56, alignment: Alignment.center,
                child: Text(qtyText, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              _stepBtn(Icons.add, () => _bump(1)),
            ]),
          ),
          const SizedBox(height: 14),

          // 改价
          Row(children: [
            const Text('单价', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: PosTheme.textMain)),
            const SizedBox(width: 8),
            Text('¥${Fmt.money(unitPrice)}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: price == null ? PosTheme.textMain : accent)),
            if (price != null) ...[
              const SizedBox(width: 8),
              Text('原价 ¥${Fmt.money(widget.listPrice)}',
                  style: const TextStyle(fontSize: 12, color: PosTheme.textHint, decoration: TextDecoration.lineThrough)),
            ],
            const Spacer(),
            const Text('改价', style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _chip('原价', price == null, () => _applyDiscount(1)),
            _chip('9 折', _isRate(0.9), () => _applyDiscount(0.9)),
            _chip('8.5 折', _isRate(0.85), () => _applyDiscount(0.85)),
            _chip('8 折', _isRate(0.8), () => _applyDiscount(0.8)),
            _chip('自定义', false, _inputPrice, icon: Icons.edit_outlined),
          ]),
          const SizedBox(height: 14),

          // 赠送数量（v3.3.231，替代备注；随小票打 0 元行）
          Row(children: [
            const Text('赠送数量', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: PosTheme.textMain)),
            const SizedBox(width: 8),
            Text(widget.byWeight ? '称重按 $unit 送' : '按件送',
                style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
            const Spacer(),
            if (giftQty > 0)
              InkWell(
                onTap: () => setState(() => giftQty = 0),
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text('清除', style: TextStyle(fontSize: 12.5, color: PosTheme.blue)),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          InkWell(
            onTap: _inputGift,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: giftQty <= 0 ? const Color(0xFFF7F8FA) : const Color(0xFFEFF7EF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: giftQty <= 0 ? PosTheme.line : Colors.green.withValues(alpha: 0.45)),
              ),
              child: Row(children: [
                Icon(Icons.redeem_outlined, size: 19, color: giftQty <= 0 ? PosTheme.textSub : Colors.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(giftQty <= 0 ? '未赠送 · 点击输入（会打印在小票上）' : '赠送 ${giftText(giftQty)} · ¥0.00',
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: giftQty <= 0 ? PosTheme.textSub : Colors.green.shade700,
                          fontWeight: giftQty <= 0 ? FontWeight.w400 : FontWeight.w700)),
                ),
                const Icon(Icons.chevron_right, size: 20, color: PosTheme.textHint),
              ]),
            ),
          ),
          const SizedBox(height: 16),

          // 小计
          Row(children: [
            Text(widget.byWeight
                    ? '$qtyText$unit × ¥${Fmt.money(unitPrice)}${giftQty > 0 ? ' + 赠送 ${giftText(giftQty)}' : ''}'
                    : '$qtyText 件 × ¥${Fmt.money(unitPrice)}${giftQty > 0 ? ' + 赠送 ${giftText(giftQty)}' : ''}',
                style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
            const Spacer(),
            const Text('小计 ', style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
            Text('¥${Fmt.money(sub)}', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: accent)),
          ]),
          const SizedBox(height: 16),

          // 底部操作
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 54,
                child: OutlinedButton.icon(
                  onPressed: _delete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: PosTheme.red,
                    side: BorderSide(color: PosTheme.red.withValues(alpha: 0.55)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('删除该商品', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: SizedBox(
                height: 54,
                child: BigButton('完成 · ¥${Fmt.money(sub)}', onTap: _done, height: 54, color: accent),
              ),
            ),
          ]),
        ]),
        ),
      ),
    );
  }

  bool _isRate(double rate) =>
      price != null && (price! - widget.listPrice * rate).abs() < 0.005;

  Widget _stepBtn(IconData icon, VoidCallback onTap, {bool enabled = true}) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 46, height: 46, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: PosTheme.line),
        ),
        child: Icon(icon, size: 20, color: enabled ? PosTheme.textMain : PosTheme.textHint),
      ),
    );
  }

  Widget _chip(String text, bool active, VoidCallback onTap,
      {IconData? icon, bool small = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: small ? 11 : 15, vertical: small ? 7 : 10),
        decoration: BoxDecoration(
          color: active ? accent.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: active ? accent : PosTheme.line, width: active ? 1.5 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: active ? accent : PosTheme.textSub),
            const SizedBox(width: 4),
          ],
          Text(text,
              style: TextStyle(
                fontSize: small ? 12.5 : 13.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? accent : PosTheme.textSub,
              )),
        ]),
      ),
    );
  }
}

// ==================== 数字键盘（数量 / 单价） ====================

Future<double?> showNumberPad(
  BuildContext context, {
  required String title,
  String initial = '',
  bool decimal = false,
  String prefix = '',
  String unit = '',
  String hint = '',
}) {
  return showDialog<double>(
    context: context,
    builder: (_) => _NumberPadDialog(
      title: title,
      initial: initial,
      decimal: decimal,
      prefix: prefix,
      unit: unit,
      hint: hint,
    ),
  );
}

class _NumberPadDialog extends StatefulWidget {
  final String title;
  final String initial;
  final bool decimal;
  final String prefix;
  final String unit;
  final String hint;

  const _NumberPadDialog({
    required this.title,
    this.initial = '',
    this.decimal = false,
    this.prefix = '',
    this.unit = '',
    this.hint = '',
  });

  @override
  State<_NumberPadDialog> createState() => _NumberPadDialogState();
}

class _NumberPadDialogState extends State<_NumberPadDialog> {
  late String input = widget.initial;

  double get value => double.tryParse(input) ?? 0;

  void _key(String k) {
    setState(() {
      if (k == 'C') {
        input = '';
        return;
      }
      if (k == 'B') {
        if (input.isNotEmpty) input = input.substring(0, input.length - 1);
        return;
      }
      if (k == '.') {
        if (!widget.decimal || input.contains('.')) return;
        input = input.isEmpty ? '0.' : '$input.';
        return;
      }
      final dot = input.indexOf('.');
      if (dot == -1) {
        if (input.length < 7) input += k;
      } else if (input.length - dot - 1 < (widget.decimal ? 3 : 0)) {
        input += k;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const keys = ['7', '8', '9', '4', '5', '6', '1', '2', '3', '.', '0', 'B'];
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const Spacer(),
            InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(18),
              child: const SizedBox(width: 34, height: 34, child: Icon(Icons.close, size: 22, color: PosTheme.textHint)),
            ),
          ]),
          if (widget.hint.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(widget.hint, style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F8FA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: PosTheme.line),
            ),
            child: Row(children: [
              Text(widget.prefix, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: PosTheme.textSub)),
              Expanded(
                child: Text(input.isEmpty ? '0' : input, textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800)),
              ),
              if (widget.unit.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(widget.unit, style: const TextStyle(fontSize: 16, color: PosTheme.textSub)),
              ],
            ]),
          ),
          const SizedBox(height: 14),
          for (var r = 0; r < 4; r++)
            Padding(
              padding: EdgeInsets.only(bottom: r == 3 ? 0 : 10),
              child: Row(children: [
                for (var c = 0; c < 3; c++) ...[
                  if (c > 0) const SizedBox(width: 10),
                  Expanded(child: _keyBtn(keys[r * 3 + c])),
                ],
              ]),
            ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed: () => setState(() => input = ''),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: PosTheme.textSub,
                    side: const BorderSide(color: PosTheme.line),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('清空'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: SizedBox(
                height: 52,
                child: BigButton('确定', onTap: value > 0 ? () => Navigator.pop(context, value) : null, height: 52),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _keyBtn(String k) {
    return InkWell(
      onTap: () => _key(k),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 54,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: k == 'B'
            ? const Icon(Icons.backspace_outlined, size: 21, color: PosTheme.textSub)
            : Text(k, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

// ==================== 权限密码校验 ====================

/// 输入并校验员工权限密码（与退款 / 清空购物车同一套云端密码）
/// 通过返回 true；取消或失败返回 false
Future<bool> showPinVerifyDialog(
  BuildContext context, {
  String title = '需要权限密码',
  String sub = '请输入当前收银员的权限密码（与退款密码相同）',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PinDialog(title: title, sub: sub),
  );
  return ok == true;
}

class _PinDialog extends StatefulWidget {
  final String title;
  final String sub;
  const _PinDialog({required this.title, required this.sub});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final ctrl = TextEditingController();
  bool busy = false;
  String? err;

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (busy) return;
    setState(() { busy = true; err = null; });
    final r = await ClearPin.verify(ctrl.text);
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, true);
      return;
    }
    setState(() { busy = false; err = r.msg; });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.sub, style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: InputDecoration(
              hintText: '权限密码',
              counterText: '',
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: err,
              prefixIcon: const Icon(Icons.lock_outline, size: 19),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: PosTheme.accent),
          onPressed: busy ? null : _submit,
          child: busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('确定', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
