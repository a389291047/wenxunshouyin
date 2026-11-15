import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/scale.dart';
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

  // 电子秤（仅 Windows / 安卓；苹果端只用键盘手输）
  // 串口/内置秤走全局 ScaleService（与收银页称重条共用连接，不抢串口）；键盘口秤在弹窗内监听
  ScalePrefs? prefs;
  StreamSubscription<ScaleFrame>? _sub;
  KeyboardScale? _kbd;
  Timer? _poll;
  double? scaleKg;        // 最近一次秤读数（千克）
  bool scaleStable = true; // 最近一帧稳定位
  bool connected = false; // 真正读到重量才算连上 → 显示绿色图标

  @override
  void initState() {
    super.initState();
    if (widget.initial > 0) {
      // 预填已有重量（去掉末尾多余 0）
      var s = widget.initial.toStringAsFixed(3);
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
      input = s;
    }
    _initScale();
  }

  /// 商品单位 ← 千克换算（秤统一输出 kg）
  double _kgToUnit(double kg) {
    switch (unit) {
      case 'g':
        return kg * 1000;
      case '斤':
        return kg * 2;
      default:
        return kg;
    }
  }

  Future<void> _initScale() async {
    // 苹果端（macOS）：不接秤，只手工输重量
    if (!ScaleSupport.canUseScale) return;

    final p = await ScalePrefs.load();
    if (!mounted) return;
    setState(() => prefs = p);
    if (!p.enabled) return;

    if (p.mode == 'keyboard') {
      // 键盘口秤：秤以键盘事件打重量，只在弹窗内监听（全局服务不接管，避免干扰搜索框输入）
      final k = KeyboardScale();
      _kbd = k;
      HardwareKeyboard.instance.addHandler(_onKey);
      // 无回车协议的秤：定时取静默帧
      _poll = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final kg = k.takePending();
        if (kg != null) _onScaleKg(ScaleFrame(kg: kg, stable: true));
      });
      return;
    }
    // 串口（Windows）/ 内置秤（安卓）：用全局 ScaleService，避免与收银页称重条抢串口
    await ScaleService.I.ensure();
    if (!mounted) return;
    _sub = ScaleService.I.stream.listen(_onScaleKg);
  }

  bool _onKey(KeyEvent e) {
    final k = _kbd;
    if (k == null) return false;
    final kg = k.feed(e, unitPref: prefs?.unit ?? 'auto');
    if (kg != null) _onScaleKg(ScaleFrame(kg: kg, stable: true));
    // 数字/回车/字母键交给秤解析，不冒泡（弹窗内没有输入框，不影响手输）
    return false;
  }

  void _onScaleKg(ScaleFrame f) {
    if (!mounted || f.kg <= 0) return;
    final kg = f.kg;
    final w = _kgToUnit(kg);
    setState(() {
      connected = true;
      scaleKg = kg;
      scaleStable = f.stable;
      // 秤读数直接填进「重量」框，收银员核对后点确认；已手动输金额时不动金额
      if (!amountMode) {
        input = w.toStringAsFixed(3);
      }
    });
  }

  @override
  void dispose() {
    if (_kbd != null) HardwareKeyboard.instance.removeHandler(_onKey);
    _poll?.cancel();
    _sub?.cancel();
    super.dispose();
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
    // 自适应收银机尺寸（v3.3.209）：1366×768 / 1280×800 / 1024×768 等小屏上
    // 原布局高度超过一屏，底部数字键与「确认」被切掉。小屏压缩间距与按键高度，
    // 极端情况再允许整块滚动兜底，任何尺寸都能看到并点到确认键。
    final size = MediaQuery.of(context).size;
    final compact = size.height < 900 || size.width < 1280;
    final pad = compact ? 16.0 : 26.0;
    final gap = compact ? 8.0 : 12.0;
    final keyH = compact ? 46.0 : 58.0;
    final maxH = size.height - 20;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520, maxHeight: maxH),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(pad),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 标题
            Row(children: [
              Container(
                width: compact ? 38 : 44,
                height: compact ? 38 : 44,
                decoration: BoxDecoration(color: PosTheme.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                child: Icon(Icons.scale_outlined, size: compact ? 20 : 24, color: PosTheme.accent),
              ),
              SizedBox(width: compact ? 10 : 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: compact ? 18 : 21, fontWeight: FontWeight.w800)),
                  Text('单价 ¥${Fmt.money(widget.price)} / $unit', style: const TextStyle(fontSize: 13, color: PosTheme.textHint)),
                ]),
              ),
              InkWell(
                onTap: () => Navigator.pop(context),
                borderRadius: BorderRadius.circular(20),
                child: const SizedBox(width: 36, height: 36, child: Icon(Icons.close, size: 24, color: PosTheme.textHint)),
              ),
            ]),
            SizedBox(height: compact ? 10 : 18),
            // 录入方式切换
            Row(children: [
              Expanded(child: _modeChip('输重量（$unit）', !amountMode, () => setState(() => amountMode = false), compact)),
              SizedBox(width: gap),
              Expanded(child: _modeChip('输金额（元）', amountMode, () => setState(() => amountMode = true), compact)),
            ]),
            // 电子秤连接成功才显示绿色标识（未连上不占位、不提示）
            if (connected) ...[
              SizedBox(height: gap),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 11, vertical: compact ? 6 : 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF8F0),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: const Color(0xFF2FBF71).withOpacity(0.45)),
                ),
                child: Row(children: [
                  Icon(
                    scaleStable ? Icons.check_circle : Icons.sync,
                    size: 16,
                    color: scaleStable ? const Color(0xFF2FBF71) : const Color(0xFFF5A623),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    scaleStable ? '电子秤已连接' : '电子秤读数中…',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: scaleStable ? const Color(0xFF1E9C58) : const Color(0xFFC57F00)),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(scaleStable ? '读数已稳定，核对后点确认' : '等数字停止闪烁再确认',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5, color: PosTheme.textSub)),
                  ),
                  if (scaleKg != null)
                    Text('${_kgToUnit(scaleKg!).toStringAsFixed(3)} $unit',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: PosTheme.accent)),
                ]),
              ),
              // 串口秤支持远程置零/去皮（连续输出协议的秤会忽略指令，无反应请按秤面按键）
              if (prefs?.mode == 'serial' && ScaleService.I.canRemoteCommand) ...[
                SizedBox(height: compact ? 6 : 8),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        final ok = ScaleService.I.zero();
                        toast(context, ok ? '已发送置零指令，无反应请按秤面【置零】键' : '指令未送达：秤未连接', error: !ok);
                      },
                      style: OutlinedButton.styleFrom(
                          foregroundColor: PosTheme.textSub,
                          side: const BorderSide(color: PosTheme.line),
                          padding: EdgeInsets.symmetric(vertical: compact ? 6 : 10)),
                      icon: const Icon(Icons.exposure_zero, size: 16),
                      label: const Text('置零（空秤归0）', style: TextStyle(fontSize: 12.5)),
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        final ok = ScaleService.I.tare();
                        toast(context, ok ? '已发送去皮指令，无反应请按秤面【去皮】键' : '指令未送达：秤未连接', error: !ok);
                      },
                      style: OutlinedButton.styleFrom(
                          foregroundColor: PosTheme.textSub,
                          side: const BorderSide(color: PosTheme.line),
                          padding: EdgeInsets.symmetric(vertical: compact ? 6 : 10)),
                      icon: const Icon(Icons.remove_circle_outline, size: 16),
                      label: const Text('去皮（扣皮重）', style: TextStyle(fontSize: 12.5)),
                    ),
                  ),
                ]),
              ],
            ],
            SizedBox(height: compact ? 10 : 14),
            // 当前录入值
            Container(
              padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 18, vertical: compact ? 8 : 14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7F4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: PosTheme.accent.withOpacity(0.5), width: 1.5),
              ),
              child: Row(children: [
                Text(amountMode ? '¥' : '', style: TextStyle(fontSize: compact ? 19 : 22, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    input.isEmpty ? '0' : input,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    style: TextStyle(fontSize: compact ? 30 : 34, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 6),
                Text(amountMode ? '' : unit, style: TextStyle(fontSize: compact ? 15 : 17, color: PosTheme.textSub)),
              ]),
            ),
            SizedBox(height: compact ? 8 : 12),
            // 换算结果
            Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 7 : 10),
              decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                Text('重量 ${weight.toStringAsFixed(3)} $unit', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.close, size: 12, color: PosTheme.textHint),
                ),
                Text('单价 ¥${Fmt.money(widget.price)}', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                const Spacer(),
                const Text('小计', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
                const SizedBox(width: 6),
                Text('¥${Fmt.money(total)}', style: TextStyle(fontSize: compact ? 18 : 20, fontWeight: FontWeight.w800, color: PosTheme.accent)),
              ]),
            ),
            SizedBox(height: compact ? 10 : 14),
            _keypad(compact: compact, keyH: keyH, gap: compact ? 6.0 : 10.0),
            SizedBox(height: compact ? 10 : 16),
            BigButton(
              weight > 0 ? '确认 ${weight.toStringAsFixed(3)} $unit · ¥${Fmt.money(total)}' : '请输入${amountMode ? '金额' : '重量'}',
              onTap: weight > 0 ? _confirm : null,
              height: compact ? 50 : 58,
            ),
          ]),
        ),
      ),
    );
  }

  Widget _modeChip(String text, bool active, VoidCallback onTap, [bool compact = false]) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: compact ? 40 : 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? PosTheme.accent.withOpacity(0.1) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? PosTheme.accent : PosTheme.line, width: active ? 2 : 1),
        ),
        child: Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 14 : 15,
              fontWeight: active ? FontWeight.w800 : FontWeight.w500,
              color: active ? PosTheme.accent : PosTheme.textSub,
            )),
      ),
    );
  }

  Widget _keypad({bool compact = false, double keyH = 58, double gap = 10}) {
    const keys = ['7', '8', '9', '4', '5', '6', '1', '2', '3', '.', '0', 'B'];
    return Column(children: [
      for (var r = 0; r < 4; r++)
        Padding(
          padding: EdgeInsets.only(bottom: r == 3 ? 0 : gap),
          child: Row(children: [
            for (var c = 0; c < 3; c++) ...[
              if (c > 0) SizedBox(width: gap),
              Expanded(child: _keyBtn(keys[r * 3 + c], keyH, compact)),
            ],
          ]),
        ),
    ]);
  }

  Widget _keyBtn(String k, [double keyH = 58, bool compact = false]) {
    final isBack = k == 'B';
    return InkWell(
      onTap: () => _key(k),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: keyH,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
        child: isBack
            ? Icon(Icons.backspace_outlined, size: compact ? 20 : 22, color: PosTheme.textSub)
            : Text(k, style: TextStyle(fontSize: compact ? 21 : 24, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
