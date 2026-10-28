import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// 会员充值弹窗（与微信小程序充值页一致：充值档次 + 扫顾客付款码）
/// 充值成功返回 {'amount': 本金, 'gift': 赠送}，取消/失败返回 null。
/// 调用方拿到结果后自行刷新会员余额并提示。
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

  Future<void> _submit() async {
    if (submitting) return;
    if (tier == null) {
      toast(context, '请选择充值档次', error: true);
      return;
    }
    final code = codeCtrl.text.trim();
    if (!RegExp(r'^\d{18,30}$').hasMatch(code)) {
      toast(context, '请输入有效的付款码（18-30位数字）', error: true);
      return;
    }
    final amount = double.tryParse('${tier!['amount']}') ?? 0;
    if (amount <= 0) {
      toast(context, '充值档次金额异常', error: true);
      return;
    }
    setState(() => submitting = true);
    try {
      final resp = await Api.rechargeCodePay(
        wenxunId: Session.wenxunId,
        amount: amount,
        code: code,
      );
      final data = (resp['data'] ?? {}) as Map;
      final ok = '${resp['code']}' == '0' &&
          ('${data['code'] ?? ''}' == '000000' || data['success'] == true);
      if (!mounted) return;
      if (ok) {
        Navigator.pop(context, {
          'amount': amount,
          'gift': double.tryParse('${tier!['zengsong'] ?? 0}') ?? 0,
        });
      } else {
        setState(() => submitting = false);
        toast(context, '${data['msg'] ?? resp['message'] ?? '支付未完成，请确认'}', error: true);
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => submitting = false);
      toast(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vip;
    return AlertDialog(
      title: Text('会员充值 · ${v['name'] ?? v['phone'] ?? ''}'),
      content: SizedBox(
        width: 440,
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
              : const Text('确认充值'),
        ),
      ],
    );
  }
}
