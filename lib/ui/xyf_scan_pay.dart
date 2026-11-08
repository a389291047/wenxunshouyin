import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextSelection, TextValue;
import '../core/api.dart';
import '../core/theme.dart';
import '../core/voice.dart';
import 'widgets.dart';

/// 星驿付 · 扫码收款弹窗（v3.3.161，收银机接扫码枪）
///
/// 流程：扫码枪扫顾客付款码（或手动输入）→ 星驿付付款码下单（B扫C）
/// → 待输密码自动轮询 25 秒 → 成功返回 {'payNo': 渠道单号, 'orderNo': 我方单号, 'order': 订单行}
/// 取消/失败返回 null。
///
/// [bizType] 业务类型：retail=零售订单 dining=餐饮订单 recharge=会员充值，
/// 编入我方单号前缀便于对账（XYFR/XYFD/XYFC + 时间戳）
/// [orderNo] 外部预生成的我方单号（收银场景传入，落单时与订单 pay_order_no 关联，退款按此原路退）
Future<Map?> showXyfScanPayDialog(BuildContext context,
    {required double amount,
    String title = '扫码收款',
    String bizType = 'retail',
    String? orderNo,
    String? moreLabel}) {
  return showDialog<Map>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _XyfScanPayDialog(
        amount: amount,
        title: title,
        bizType: bizType,
        orderNo: orderNo,
        moreLabel: moreLabel),
  );
}

class _XyfScanPayDialog extends StatefulWidget {
  final double amount;
  final String title;
  final String bizType;
  final String? orderNo;

  /// 快捷扫码场景的「完整结账」入口文案（如餐饮点结账收款直接弹扫码时，
  /// 商户要打折/现金/挂账/会员可点此进入完整结账弹窗），空则不显示
  final String? moreLabel;
  const _XyfScanPayDialog(
      {required this.amount,
      required this.title,
      required this.bizType,
      this.orderNo,
      this.moreLabel});
  @override
  State<_XyfScanPayDialog> createState() => _XyfScanPayDialogState();
}

class _XyfScanPayDialogState extends State<_XyfScanPayDialog> {
  final codeCtrl = TextEditingController();
  final focusNode = FocusNode();
  // phase: input=等待扫码 / paying=支付中 / success=成功 / fail=失败
  String phase = 'input';
  // 支付进度（paying 阶段展示）：scanned 付款码已识别 → accepted 星驿付已受理 → waiting 顾客输入密码中
  String payStatus = 'scanned';
  int elapsedSec = 0; // 支付中已等待秒数
  String errorMsg = '';
  Map? order; // 成功后的 wx_pay_orders 行
  bool submitting = false;

  @override
  void dispose() {
    codeCtrl.dispose();
    focusNode.dispose();
    super.dispose();
  }

  /// 支付中每秒计时（收银员能感知在推进）
  void _startElapsed() {
    elapsedSec = 0;
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || phase != 'paying') return false;
      setState(() => elapsedSec++);
      return true;
    });
  }

  /// 我方业务单号：XYF + 业务前缀(R零售/D餐饮/C充值) + 时间戳 + 4位随机
  /// 外部已传入（orderNo）则直接用，保证支付流水号与业务订单一致关联
  String _genOrderNo() {
    if ((widget.orderNo ?? '').isNotEmpty) return widget.orderNo!;
    final biz = widget.bizType == 'dining'
        ? 'D'
        : (widget.bizType == 'recharge' ? 'C' : 'R');
    return 'XYF$biz${DateTime.now().millisecondsSinceEpoch}'
        '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
  }

  Future<void> _pay() async {
    if (submitting) return;
    final code = codeCtrl.text.replaceAll(RegExp(r'[\r\n\t\s]'), '').trim();
    if (!RegExp(r'^\d{16,32}$').hasMatch(code)) {
      setState(() => errorMsg = '付款码无效（16-32位数字），请重新扫码或输入');
      return;
    }
    setState(() {
      submitting = true;
      phase = 'paying';
      payStatus = 'scanned';
      errorMsg = '';
    });
    _startElapsed();
    try {
      final o = await Api.xyfScanPay(
        amount: widget.amount,
        authCode: code,
        orderNo: _genOrderNo(),
        bizType: widget.bizType,
        onStatus: (s) {
          if (mounted) setState(() => payStatus = s);
        },
      );
      if (!mounted) return;
      VoiceService.instance.pay('扫码', widget.amount);
      setState(() {
        order = o;
        phase = 'success';
        submitting = false;
      });
      // 成功停 1.2 秒自动回传，收银节奏不断
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        Navigator.pop(context, {
          'payNo': '${o['order_no'] ?? ''}',
          'orderNo': '${o['three_order_no'] ?? ''}',
          'order': o,
        });
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        phase = 'fail';
        errorMsg = e.message;
        submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        phase = 'fail';
        errorMsg = '支付失败：$e';
        submitting = false;
      });
    }
  }

  void _retry() {
    setState(() {
      phase = 'input';
      codeCtrl.clear();
      errorMsg = '';
    });
    focusNode.requestFocus();
  }

  String get _payStatusText {
    switch (payStatus) {
      case 'scanned':
        return '正在提交付款码…';
      case 'accepted':
        return '已受理，等待支付结果…';
      default:
        return '顾客正在输入密码…';
    }
  }

  /// 三步进度条的单行
  Widget _step(String text, {required bool done, bool active = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        if (done)
          const Icon(Icons.check_circle, size: 17, color: PosTheme.green)
        else if (active)
          const SizedBox(
              width: 17, height: 17,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: PosTheme.blue))
        else
          const Icon(Icons.radio_button_unchecked, size: 17, color: PosTheme.textHint),
        const SizedBox(width: 8),
        Text(text,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: done || active ? FontWeight.w700 : FontWeight.w400,
                color: done
                    ? PosTheme.green
                    : active
                        ? PosTheme.textMain
                        : PosTheme.textHint)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titlePadding: EdgeInsets.zero,
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 4, 24, 18),
      title: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [Color(0xFF2E6BFF), Color(0xFF1F4FD8)]),
          ),
          child: Row(children: [
            const Icon(Icons.qr_code_scanner, size: 26, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white))),
            Text('¥${Fmt.money(widget.amount)}',
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white)),
          ]),
        ),
      ),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (phase == 'input') ...[
            const Text('扫码枪对准顾客付款码（微信/支付宝/云闪付自动识别）',
                style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
            const SizedBox(height: 12),
            TextField(
              controller: codeCtrl,
              focusNode: focusNode,
              autofocus: true,
              enabled: !submitting,
              keyboardType: TextInputType.number,
              maxLength: 32,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 1.5),
              onChanged: (v) {
                // 清除扫码枪带回的换行/制表符等脏字符
                final clean = v.replaceAll(RegExp(r'[\r\n\t\s]'), '');
                if (clean != v) {
                  codeCtrl.value = TextEditingValue(
                      text: clean,
                      selection: TextSelection.collapsed(offset: clean.length));
                }
              },
              onSubmitted: (_) => _pay(),
              decoration: InputDecoration(
                labelText: '顾客付款码',
                counterText: '',
                prefixIcon: const Icon(Icons.qr_code, size: 22),
                suffixIcon: codeCtrl.text.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () => setState(() => codeCtrl.clear())),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            if (errorMsg.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.error_outline, size: 15, color: PosTheme.red),
                const SizedBox(width: 4),
                Expanded(child: Text(errorMsg, style: const TextStyle(fontSize: 12.5, color: PosTheme.red))),
              ]),
            ],
            const SizedBox(height: 10),
            const Text('也可手动输入付款码后按回车 / 点「确认收款」',
                style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            if ((widget.moreLabel ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(context, {'more': true}),
                  icon: const Icon(Icons.tune, size: 15),
                  label: Text(widget.moreLabel!,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ] else if (phase == 'paying') ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 6),
              child: Column(children: [
                // 大号转圈（呼吸光环），收银员一眼可见
                Container(
                  width: 96, height: 96,
                  decoration: BoxDecoration(
                    color: PosTheme.blue.withOpacity(0.07),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const SizedBox(
                      width: 64, height: 64,
                      child: CircularProgressIndicator(strokeWidth: 5, color: PosTheme.blue)),
                ),
                const SizedBox(height: 18),
                // 当前状态大字（随进度切换）
                Text(_payStatusText,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text('已等待 $elapsedSec 秒 · 最长 25 秒',
                    style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                const SizedBox(height: 16),
                // 三步进度条
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F8FA),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _step('付款码识别成功', done: true),
                    _step('星驿付受理完成',
                        done: payStatus == 'accepted' || payStatus == 'waiting',
                        active: payStatus == 'scanned'),
                    _step('顾客输入支付密码…',
                        done: false,
                        active: payStatus == 'waiting'),
                  ]),
                ),
              ]),
            ),
          ] else if (phase == 'success') ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 34),
              child: Column(children: [
                Container(width: 64, height: 64,
                    decoration: BoxDecoration(color: PosTheme.green.withOpacity(0.12), shape: BoxShape.circle),
                    child: const Icon(Icons.check, size: 36, color: PosTheme.green)),
                const SizedBox(height: 14),
                const Text('收款成功', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('¥${Fmt.money(widget.amount)}',
                    style: const TextStyle(fontSize: 16, color: PosTheme.textSub)),
                if ('${order?['pay_channel'] ?? ''}'.isNotEmpty)
                  Text('渠道 ${order?['pay_channel'] ?? ''}',
                      style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
              ]),
            ),
          ] else ...[
            // fail
            Container(
              padding: const EdgeInsets.symmetric(vertical: 34),
              child: Column(children: [
                Container(width: 64, height: 64,
                    decoration: BoxDecoration(color: PosTheme.red.withOpacity(0.1), shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 36, color: PosTheme.red)),
                const SizedBox(height: 14),
                const Text('收款失败', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: PosTheme.red)),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(errorMsg, textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
                ),
              ]),
            ),
          ],
        ]),
      ),
      actions: [
        if (phase == 'input' || phase == 'fail')
          Row(children: [
            Expanded(child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: PosTheme.textSub,
                side: const BorderSide(color: PosTheme.line),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: phase == 'fail' ? () => Navigator.pop(context) : () => Navigator.pop(context),
              child: const Text('取消', style: TextStyle(fontSize: 15)),
            )),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: PosTheme.blue,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: submitting ? null : (phase == 'fail' ? _retry : _pay),
              child: Text(phase == 'fail' ? '重新扫码' : '确认收款', style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
            )),
          ])
        else
          const SizedBox(height: 4),
      ],
    );
  }
}
