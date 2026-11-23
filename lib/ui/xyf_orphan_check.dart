import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// 星驿付「未落单流水」兜底检查（v3.3.162）
///
/// 场景：扫码收款成功后、订单落库前收银机崩溃/断电 → 钱收了但没订单。
/// 订单页加载时调用 [checkXyfOrphans]：检测到未落单流水则弹窗提示，
/// 商户可输入权限密码对该笔流水原路退款（资金 1-3 个工作日退回顾客）。
Future<void> checkXyfOrphans(BuildContext context) async {
  List orphans = [];
  try {
    final r = await Api.xyfOrphanList();
    if ('${r['code']}' == '0') orphans = (r['data'] ?? []) as List;
  } on ApiError {
    return; // 查询失败静默跳过，不打扰收银
  } catch (_) {
    return;
  }
  if (orphans.isEmpty) return;
  if (!context.mounted) return;

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => _OrphanDialog(orphans: orphans),
  );
}

class _OrphanDialog extends StatefulWidget {
  final List orphans;
  const _OrphanDialog({required this.orphans});
  @override
  State<_OrphanDialog> createState() => _OrphanDialogState();
}

class _OrphanDialogState extends State<_OrphanDialog> {
  final pwdCtrl = TextEditingController();
  final focusNode = FocusNode();
  bool refunding = false;
  List orphans = [];

  @override
  void initState() {
    super.initState();
    orphans = widget.orphans;
  }

  @override
  void dispose() {
    pwdCtrl.dispose();
    focusNode.dispose();
    super.dispose();
  }

  Future<void> _refund(Map o) async {
    final pwd = pwdCtrl.text.trim();
    if (pwd.length < 4) {
      toast(context, '请输入权限密码', error: true);
      return;
    }
    setState(() => refunding = true);
    try {
      final r = await Api.xyfOrphanRefund(
        threeOrderNo: '${o['three_order_no'] ?? ''}',
        password: pwd,
        operatorId: Session.staffId,
      );
      if (!mounted) return;
      setState(() => refunding = false);
      if ('${r['code']}' == '0') {
        toast(context, '${r['message'] ?? '退款已发起'}');
        setState(() => orphans.remove(o));
        if (orphans.isEmpty && mounted) Navigator.pop(context);
      } else {
        toast(context, '${r['message'] ?? '退款失败'}', error: true);
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => refunding = false);
      toast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => refunding = false);
      toast(context, '退款失败：$e', error: true);
    }
  }

  String _channelName(dynamic ch) {
    switch (int.tryParse('$ch') ?? 0) {
      case 1:
        return '支付宝';
      case 2:
        return '微信支付';
      case 9:
        return '银联';
      case 12:
        return '数字人民币';
      default:
        return '扫码支付';
    }
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
              gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFE5484D), Color(0xFFC6323A)])),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, size: 26, color: Colors.white),
            const SizedBox(width: 10),
            const Expanded(
                child: Text('检测到未落单的已收款',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Colors.white))),
            Text('${orphans.length} 笔',
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
          ]),
        ),
      ),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(
              '以下扫码收款已成功，但对应订单未创建（收银机可能中途异常）。可选择原路退款给顾客，或联系管理员核对。',
              style: TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
          const SizedBox(height: 12),
          for (final o in orphans) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7F7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: PosTheme.red.withOpacity(0.25)),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${_channelName(o['pay_channel'])} · ¥${Fmt.money(double.tryParse('${o['amount']}') ?? 0)} · ${o['biz'] ?? ''}',
                            style: const TextStyle(
                                fontSize: 14.5, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 3),
                        Text('流水号 ${o['three_order_no'] ?? ''} · ${o['create_time'] ?? ''}',
                            style: const TextStyle(
                                fontSize: 11, color: PosTheme.textHint)),
                      ]),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: PosTheme.red,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: refunding ? null : () => _refund(o),
                  child: Text(refunding ? '退款中…' : '原路退款',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          PosField(
            controller: pwdCtrl,
            focusNode: focusNode,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            compact: true,
            label: '权限密码（退款需验证，防止误退）',
            icon: Icons.lock_outline,
          ),
        ]),
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: PosTheme.textSub,
              side: const BorderSide(color: PosTheme.line),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(context),
            child: const Text('我知道了，稍后处理', style: TextStyle(fontSize: 14.5)),
          ),
        ),
      ],
    );
  }
}
