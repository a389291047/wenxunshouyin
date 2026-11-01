import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// 会员充值弹窗（v3.3.62 重构）：
/// - 充值档次：读商户充值活动（v1.vip/huodonglst，按金额升序）
/// - 两种方式：现金充值（需权限密码，9宫格输入）/ 付款码充值（扫顾客付款码，免密）
/// - 付款码走星驿付 codePay（type=A），成功后调 shouyin/vip/chongzhi 入账；
///   商户未开通星驿付时提示「联系客服开通支付」
/// 充值成功返回 {'amount': 本金, 'gift': 赠送}，取消/失败返回 null。
Future<Map?> showVipRechargeDialog(BuildContext context, {required Map vip}) {
  return showDialog<Map>(
    context: context,
    builder: (_) => _VipRechargeDialog(vip: vip),
  );
}

class _VipRechargeDialog extends StatefulWidget {
  final Map vip;
  const _VipRechargeDialog({required this.vip});
  @override
  State<_VipRechargeDialog> createState() => _VipRechargeDialogState();
}

class _VipRechargeDialogState extends State<_VipRechargeDialog> {
  late final Future<List> tiersFuture; // 只创建一次，避免 rebuild 重复请求
  final codeCtrl = TextEditingController();
  Map? tier;
  bool cashMode = true; // true=现金充值 false=付款码充值
  String pwd = ''; // 权限密码（6位数字，现金充值用）
  bool submitting = false;

  @override
  void initState() {
    super.initState();
    tiersFuture = Api.vipRechargeTiers(Session.wenxunId);
  }

  @override
  void dispose() {
    codeCtrl.dispose();
    super.dispose();
  }

  void _pwdKey(String k) {
    setState(() {
      if (k == 'C') {
        pwd = '';
      } else if (k == '<') {
        if (pwd.isNotEmpty) pwd = pwd.substring(0, pwd.length - 1);
      } else if (pwd.length < 6) {
        pwd += k;
      }
    });
  }

  Future<void> _submit() async {
    if (submitting) return;
    if (tier == null) {
      toast(context, '请选择充值档次', error: true);
      return;
    }
    final amount = double.tryParse('${tier!['amount']}') ?? 0;
    final gift = double.tryParse('${tier!['zengsong'] ?? 0}') ?? 0;
    if (amount <= 0) {
      toast(context, '充值档次金额异常', error: true);
      return;
    }
    setState(() => submitting = true);
    try {
      String orderNo = '';
      if (!cashMode) {
        // ---- 付款码充值：先星驿付 codePay，成功后入账 ----
        final code = codeCtrl.text.trim();
        if (!RegExp(r'^\d{18,30}$').hasMatch(code)) {
          setState(() => submitting = false);
          toast(context, '请输入有效的付款码（18-30位数字）', error: true);
          return;
        }
        orderNo = 'wenxun${DateTime.now().millisecondsSinceEpoch}${(DateTime.now().microsecondsSinceEpoch % 1000)}';
        final resp = await Api.rechargeCodePay(
          wenxunId: Session.wenxunId,
          amount: amount,
          code: code,
          orderNo: orderNo,
        );
        final data = (resp['data'] ?? {}) as Map;
        final ok = '${resp['code']}' == '0' &&
            ('${data['code'] ?? ''}' == '000000' || data['success'] == true);
        if (!mounted) return;
        if (!ok) {
          setState(() => submitting = false);
          final raw = '${data['msg'] ?? resp['message'] ?? '支付未完成，请确认'}';
          // 未开通星驿付：明确提示联系客服
          if (raw.contains('未配置商户号') || raw.contains('商户号')) {
            toast(context, '商户未开通星驿付收款，请联系客服开通支付', error: true);
          } else {
            toast(context, raw, error: true);
          }
          return;
        }
        // 以星驿付返回的平台单号为准（后端按 order_no/three_order_no 双匹配）
        final inner = (data['data'] ?? {}) as Map;
        final payNo = '${inner['orderNo'] ?? ''}';
        if (payNo.isNotEmpty) orderNo = payNo;
      } else {
        // ---- 现金充值：权限密码校验 ----
        if (pwd.length != 6) {
          setState(() => submitting = false);
          toast(context, '请输入6位数字权限密码（由商户在设置页分配）', error: true);
          return;
        }
      }
      // ---- 统一入账（现金验密码 / 付款码验成功流水）----
      final r2 = await Api.vipRechargeSubmit(
        vipId: int.tryParse('${widget.vip['id']}') ?? 0,
        wenxunId: Session.wenxunId,
        amount: amount,
        gift: gift,
        method: cashMode ? '现金' : '付款码',
        operatorId: cashMode ? Session.staffId : 0,
        password: cashMode ? pwd : '',
        orderNo: orderNo,
      );
      if (!mounted) return;
      if ('${r2['code']}' == '200') {
        Navigator.pop(context, {'amount': amount, 'gift': gift});
      } else {
        setState(() => submitting = false);
        toast(context, '${r2['msg'] ?? '充值失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => submitting = false);
      toast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => submitting = false);
      toast(context, '充值失败：$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vip;
    return AlertDialog(
      title: Text('会员充值 · ${v['name'] ?? v['phone'] ?? ''}'),
      content: SizedBox(
        width: 460,
        child: FutureBuilder<List>(
          future: tiersFuture,
          builder: (_, snap) {
            final tiers = snap.data ?? [];
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                '当前余额 ¥${Fmt.money(v['amount'])}　赠送余额 ¥${Fmt.money(v['gift_balance'])}　积分 ${v['score'] ?? 0}',
                style: const TextStyle(fontSize: 13, color: PosTheme.textSub),
              ),
              const SizedBox(height: 14),
              if (snap.connectionState != ConnectionState.done)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(child: CircularProgressIndicator(color: PosTheme.accent)),
                )
              else if (tiers.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
                  child: const Text('暂无充值活动，请联系店长配置充值档次', style: TextStyle(fontSize: 13, color: PosTheme.textHint)),
                )
              else
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final t in tiers)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: submitting ? null : () => setState(() => tier = t as Map),
                      child: Container(
                        width: 128,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: '${tier?['id']}' == '${t['id']}' ? const Color(0xFFFFF2ED) : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: '${tier?['id']}' == '${t['id']}' ? PosTheme.accent : PosTheme.line,
                            width: '${tier?['id']}' == '${t['id']}' ? 1.5 : 1,
                          ),
                        ),
                        child: Column(children: [
                          Text('¥${t['amount'] ?? 0}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                          const SizedBox(height: 2),
                          Text('送 ¥${t['zengsong'] ?? 0}', style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
                        ]),
                      ),
                    ),
                ]),
              const SizedBox(height: 16),
              // ---- 充值方式 ----
              Row(children: [
                Expanded(child: _modeChip('现金充值', Icons.payments_outlined, cashMode,
                    () => setState(() => cashMode = true))),
                const SizedBox(width: 10),
                Expanded(child: _modeChip('付款码充值', Icons.qr_code_scanner, !cashMode,
                    () => setState(() => cashMode = false))),
              ]),
              const SizedBox(height: 12),
              if (cashMode) ...[
                _pwdBox(),
                const SizedBox(height: 8),
                _pwdPad(),
              ] else
                TextField(
                  controller: codeCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  maxLength: 30,
                  enabled: !submitting,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    labelText: '顾客付款码',
                    hintText: '扫码枪扫描顾客付款码，或手动输入',
                    counterText: '',
                    prefixIcon: Icon(Icons.qr_code_scanner, size: 20),
                  ),
                ),
            ]);
          },
        ),
      ),
      actions: [
        TextButton(onPressed: submitting ? null : () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: PosTheme.accent, foregroundColor: Colors.white),
          onPressed: submitting ? null : _submit,
          child: submitting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(cashMode ? '确认现金充值' : '确认付款码充值'),
        ),
      ],
    );
  }

  Widget _modeChip(String text, IconData icon, bool on, VoidCallback onTap) {
    return InkWell(
      onTap: submitting ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFFF2ED) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? PosTheme.accent.withOpacity(0.5) : PosTheme.line, width: on ? 1.5 : 1),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 18, color: on ? PosTheme.accent : PosTheme.textSub),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(
            fontSize: 14.5, fontWeight: on ? FontWeight.w700 : FontWeight.w400,
            color: on ? PosTheme.accent : PosTheme.textSub,
          )),
        ]),
      ),
    );
  }

  /// 权限密码显示框：6 位圆点
  Widget _pwdBox() {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: PosTheme.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosTheme.line),
      ),
      child: Row(children: [
        const SizedBox(width: 12),
        const Icon(Icons.lock_outline, size: 18, color: PosTheme.textHint),
        const SizedBox(width: 12),
        Expanded(
          child: pwd.isEmpty
              ? const Text('请输入权限密码（6位数字，由商户分配）',
                  style: TextStyle(fontSize: 13, color: PosTheme.textHint))
              : Row(mainAxisAlignment: MainAxisAlignment.start, children: [
                  for (var i = 0; i < 6; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Container(
                      width: 11, height: 11,
                      decoration: BoxDecoration(
                        color: i < pwd.length ? PosTheme.textMain : Colors.transparent,
                        shape: BoxShape.circle,
                        border: Border.all(color: PosTheme.textHint, width: 1.2),
                      ),
                    ),
                  ],
                ]),
        ),
        if (pwd.isNotEmpty)
          InkWell(
            onTap: () => _pwdKey('C'),
            borderRadius: BorderRadius.circular(8),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text('清空', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
            ),
          ),
        const SizedBox(width: 8),
      ]),
    );
  }

  /// 9宫格数字键盘（触屏）：1-9 / 清空 0 退格
  Widget _pwdPad() {
    Widget keyBtn(String label, {VoidCallback? onTap, Color? color, IconData? icon}) {
      final enabled = onTap != null;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: enabled ? (color ?? Colors.white) : PosTheme.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: PosTheme.line),
          ),
          alignment: Alignment.center,
          child: icon != null
              ? Icon(icon, size: 20, color: enabled ? PosTheme.textMain : PosTheme.textHint)
              : Text(label, style: TextStyle(
                  fontSize: 19, fontWeight: FontWeight.w700,
                  color: enabled ? (color ?? PosTheme.textMain) : PosTheme.textHint)),
        ),
      );
    }

    return Column(children: [
      for (var row = 0; row < 4; row++) ...[
        if (row > 0) const SizedBox(height: 7),
        Row(children: [
          for (var col = 0; col < 3; col++) ...[
            if (col > 0) const SizedBox(width: 7),
            Expanded(
              child: row < 3
                  ? keyBtn('${row * 3 + col + 1}', onTap: () => _pwdKey('${row * 3 + col + 1}'))
                  : (col == 0
                      ? keyBtn('清空', onTap: pwd.isEmpty ? null : () => _pwdKey('C'), color: const Color(0xFFF2F3F7))
                      : (col == 1
                          ? keyBtn('0', onTap: () => _pwdKey('0'))
                          : keyBtn('退格', onTap: pwd.isEmpty ? null : () => _pwdKey('<'),
                              icon: Icons.backspace_outlined))),
            ),
          ],
        ]),
      ],
    ]);
  }
}
