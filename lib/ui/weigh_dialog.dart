import 'package:flutter/material.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// 称重商品弹窗（零售）
///
/// - 单价来自商品资料（元/单位，如 18.00 元/kg）
/// - 两种录入方式：输重量（默认，3 位小数＝克级）/ 输金额反算重量（散装零食常用）
/// - 内置 12 宫格数字键盘，触屏友好，不调系统键盘
/// - 返回重量（double，单位与商品 unit 一致）；取消返回 null
class WeighDialog extends StatefulWidget {
  final String title; // 商品名
  final double price; // 单价（元/单位）
  final String unit; // 单位：kg / 斤 / 份…（默认 kg）
  final double initial; // 初始重量（再次点击同一商品时预填，0 表示新增）

  const WeighDialog({
    super.key,
    required this.title,
    required this.price,
    this.unit = 'kg',
    this.initial = 0,
  });

  @override
  State<WeighDialog> createState() => _WeighDialogState();
}

class _WeighDialogState extends State<WeighDialog> {
  String input = ''; // 当前录入值（重量或金额）
  bool amountMode = false; // false=输重量 true=输金额

  @override
  void initState() {
    super.initState();
    if (widget.initial > 0) {
      // 预填已有重量（去掉末尾多余 0）
      var s = widget.initial.toStringAsFixed(3);
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
      input = s;
    }
  }

  String get unit => widget.unit.trim().isEmpty ? 'kg' : widget.unit.trim();

  /// 重量（3 位小数，单位同 unit）
  double get weight {
    final v = double.tryParse(input) ?? 0;
    if (!amountMode) return v;
    if (widget.price <= 0) return 0;
    return double.parse((v / widget.price).toStringAsFixed(3));
  }

  /// 金额（2 位小数）
  double get amount {
    final v = double.tryParse(input) ?? 0;
    if (amountMode) return double.parse(v.toStringAsFixed(2));
    return double.parse((v * widget.price).toStringAsFixed(2));
  }

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
        if (!input.contains('.')) input = input.isEmpty ? '0.' : '$input.';
        return;
      }
      final dot = input.indexOf('.');
      if (dot == -1) {
        if (input.length < 6) input += k;
      } else {
        // 重量最多 3 位小数，金额最多 2 位
        final maxDec = amountMode ? 2 : 3;
        if (input.length - dot - 1 < maxDec) input += k;
      }
    });
  }

  void _confirm() {
    if (weight <= 0) return;
    Navigator.pop(context, weight);
  }

  @override
  Widget build(BuildContext context) {
    final total = amount;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(26),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 标题
          Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(color: PosTheme.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.scale_outlined, size: 24, color: PosTheme.accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                Text('单价 ¥${Fmt.money(widget.price)} / $unit', style: const TextStyle(fontSize: 13, color: PosTheme.textHint)),
              ]),
            ),
            InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(20),
              child: const SizedBox(width: 40, height: 40, child: Icon(Icons.close, size: 26, color: PosTheme.textHint)),
            ),
          ]),
          const SizedBox(height: 18),
          // 录入方式切换
          Row(children: [
            Expanded(child: _modeChip('输重量（$unit）', !amountMode, () => setState(() => amountMode = false))),
            const SizedBox(width: 12),
            Expanded(child: _modeChip('输金额（元）', amountMode, () => setState(() => amountMode = true))),
          ]),
          const SizedBox(height: 14),
          // 当前录入值
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7F4),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: PosTheme.accent.withOpacity(0.5), width: 1.5),
            ),
            child: Row(children: [
              Text(amountMode ? '¥' : '', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: PosTheme.accent)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  input.isEmpty ? '0' : input,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 6),
              Text(amountMode ? '' : unit, style: const TextStyle(fontSize: 17, color: PosTheme.textSub)),
            ]),
          ),
          const SizedBox(height: 12),
          // 换算结果
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Text('重量 ${weight.toStringAsFixed(3)} $unit', style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.close, size: 13, color: PosTheme.textHint),
              ),
              Text('单价 ¥${Fmt.money(widget.price)}', style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
              const Spacer(),
              const Text('小计', style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
              const SizedBox(width: 8),
              Text('¥${Fmt.money(total)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: PosTheme.accent)),
            ]),
          ),
          const SizedBox(height: 14),
          _keypad(),
          const SizedBox(height: 16),
          BigButton(
            weight > 0 ? '确认 ${weight.toStringAsFixed(3)} $unit · ¥${Fmt.money(total)}' : '请输入${amountMode ? '金额' : '重量'}',
            onTap: weight > 0 ? _confirm : null,
            height: 58,
          ),
        ]),
      ),
    );
  }

  Widget _modeChip(String text, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? PosTheme.accent.withOpacity(0.1) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? PosTheme.accent : PosTheme.line, width: active ? 2 : 1),
        ),
        child: Text(text,
            style: TextStyle(
              fontSize: 15,
              fontWeight: active ? FontWeight.w800 : FontWeight.w500,
              color: active ? PosTheme.accent : PosTheme.textSub,
            )),
      ),
    );
  }

  Widget _keypad() {
    const keys = ['7', '8', '9', '4', '5', '6', '1', '2', '3', '.', '0', 'B'];
    return Column(children: [
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
    ]);
  }

  Widget _keyBtn(String k) {
    final isBack = k == 'B';
    return InkWell(
      onTap: () => _key(k),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 58,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: isBack
            ? const Icon(Icons.backspace_outlined, size: 22, color: PosTheme.textSub)
            : Text(k, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
