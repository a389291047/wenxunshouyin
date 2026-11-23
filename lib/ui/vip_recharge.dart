import 'dart:async';

import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/cloud_printer.dart';
import '../core/pending_recharge.dart';
import '../core/print_prefs.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/voice.dart';
import 'brand_logos.dart';
import 'widgets.dart';

/// 会员充值弹窗（v3.3.168 优化）：
/// - 充值档次：读商户充值活动（v1.vip/huodonglst，按金额升序），默认选中第一个
/// - 两种方式：付款码充值（扫顾客付款码，免密，默认）/ 现金充值（需权限密码）
/// - 付款码走星驿付 codePay（type=A），成功后调 shouyin/vip/chongzhi 入账；
///   商户未开通星驿付时提示「联系客服开通支付」
/// - 点弹窗外空白即可关闭，不放关闭按钮
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
  final codeFocus = FocusNode(); // v3.3.250：点档次/切方式后把焦点还给付款码框（否则扫码枪输不进）
  Map? tier;
  bool cashMode = false; // false=付款码充值（默认，免密） true=现金充值
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
    codeFocus.dispose();
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
      if (!cashMode) codeFocus.requestFocus();
      return;
    }
    final amount = double.tryParse('${tier!['amount']}') ?? 0;
    final gift = double.tryParse('${tier!['zengsong'] ?? 0}') ?? 0;
    if (amount <= 0) {
      toast(context, '充值档次金额异常', error: true);
      return;
    }
    setState(() => submitting = true);
    String orderNo = '';
    String myNo = ''; // 付款码业务单号（待补入账记录的 key，catch 块也要用）
    try {
      if (!cashMode) {
        // ---- 付款码充值（v3.3.161）：星驿付付款码支付 + 轮询，成功后入账 ----
        final code = codeCtrl.text.replaceAll(RegExp(r'[\r\n\t\s]'), '').trim();
        if (!RegExp(r'^\d{16,32}$').hasMatch(code)) {
          setState(() => submitting = false);
          toast(context, '请输入有效的付款码（16-32位数字）', error: true);
          // v3.3.251：焦点必须还给付款码框，否则点过确认后扫码枪再扫数字落不进来
          codeFocus.requestFocus();
          return;
        }
        final myNo2 = 'XYFC${DateTime.now().millisecondsSinceEpoch}'
            '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
        myNo = myNo2;
        // v3.3.256：发起扣款前先落「待补入账」记录——星驿扣款成功但入账断掉时
        // （546 商户 ¥200 孤儿充值），软件启动/会员页会自动补入账，不再丢
        await PendingRecharge.save(
          orderNo: myNo2,
          vipId: int.tryParse('${widget.vip['id']}') ?? 0,
          vipName: '${widget.vip['name'] ?? widget.vip['xm'] ?? ''}',
          phone: '${widget.vip['phone'] ?? ''}',
          amount: amount,
          gift: gift,
        );
        try {
          final o = await Api.xyfScanPay(
            amount: amount,
            authCode: code,
            orderNo: myNo2,
            bizType: 'recharge',
          );
          if (!mounted) return;
          VoiceService.instance.pay('扫码', amount);
          // 入账单号优先星驿渠道单号，其次我方业务单号（后端双匹配）
          orderNo = '${o['order_no'] ?? ''}';
          if (orderNo.isEmpty) orderNo = '${o['three_order_no'] ?? myNo2}';
        } on ApiError catch (e) {
          if (!mounted) return;
          setState(() => submitting = false);
          final raw = e.message;
          // 未开通星驿付：明确提示联系客服
          if (raw.contains('开通支付') || raw.contains('商户号') || raw.contains('cust')) {
            toast(context, '商户未开通扫码收款，请联系客服开通支付', error: true);
          } else {
            toast(context, '$raw（若已被扣款，软件会自动核对并补入账）', error: true);
          }
          // 扣款结果未知（超时/异常）：留在待补入账列表，稍后自动核对；
          // 渠道确认未扣款的记录会被自动清理
          unawaited(Future.delayed(const Duration(seconds: 8), () {
            PendingRecharge.retryAll();
          }));
          return;
        }
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
        // v3.3.256：入账成功，清掉待补入账记录（业务单号 + 渠道单号都清，防残留）
        if (myNo.isNotEmpty) await PendingRecharge.remove(myNo);
        if (orderNo.isNotEmpty && orderNo != myNo) {
          await PendingRecharge.remove(orderNo);
        }
        // 充值小票（v3.3.174）：小票打印设置可关；USB 直连优先，无 USB 自动走云打印
        if (await PrintPrefs.on('vipcz')) {
          CloudPrinter.print(CloudPrinter.vipRechargeTicket(
            vipName: '${widget.vip['name'] ?? widget.vip['xm'] ?? ''}',
            phone: '${widget.vip['phone'] ?? ''}',
            orderSn: '${r2['order_sn'] ?? ''}',
            amount: amount,
            gift: gift,
            payMethod: cashMode ? '现金' : '扫码支付',
            balance: double.tryParse('${r2['balance'] ?? ''}'),
          )).catchError((_) => <String, dynamic>{});
        }
        Navigator.pop(context, {'amount': amount, 'gift': gift});
      } else {
        setState(() => submitting = false);
        // v3.3.256：付款码已扣款但入账失败 → 记录已在本地，提示自动补入账
        final keep = !cashMode && orderNo.isNotEmpty;
        toast(context,
            '${r2['msg'] ?? '充值失败'}${keep ? '（扫码扣款若已成功，软件会自动补入账）' : ''}',
            error: true);
        if (keep) {
          unawaited(Future.delayed(const Duration(seconds: 8), () {
            PendingRecharge.retryAll();
          }));
        }
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => submitting = false);
      // v3.3.256：付款码已扣款但入账请求异常 → 待补入账记录已落盘，提示会自动补
      final keep = !cashMode && myNo.isNotEmpty;
      toast(context,
          '${e.message}${keep ? '（扫码扣款若已成功，软件会自动补入账）' : ''}',
          error: true);
      if (keep) {
        unawaited(Future.delayed(const Duration(seconds: 8), () {
          PendingRecharge.retryAll();
        }));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => submitting = false);
      final keep = !cashMode && myNo.isNotEmpty;
      toast(context, '充值失败：$e${keep ? '（扫码扣款若已成功，软件会自动补入账）' : ''}',
          error: true);
      if (keep) {
        unawaited(Future.delayed(const Duration(seconds: 8), () {
          PendingRecharge.retryAll();
        }));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vip;
    // 点弹窗外空白即可关闭（showDialog 默认 barrierDismissible），不再放关闭按钮
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: EdgeInsets.zero,
      contentPadding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
      actionsPadding: const EdgeInsets.fromLTRB(22, 4, 22, 20),
      title: _header(v),
      content: SizedBox(
        width: 520,
        child: FutureBuilder<List>(
          future: tiersFuture,
          builder: (_, snap) {
            final tiers = snap.data ?? [];
            // 有充值档次时默认选中第一个（按金额升序），无需手动点选（v3.3.166）
            if (tier == null && tiers.isNotEmpty) tier = tiers.first;
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (snap.connectionState != ConnectionState.done)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(child: CircularProgressIndicator(color: PosTheme.accent)),
                )
              else if (tiers.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 26),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12)),
                  child: const Text('暂无充值活动，请联系店长配置充值档次', style: TextStyle(fontSize: 13.5, color: PosTheme.textHint)),
                )
              else
                // 档次太多时只显示 2 行（每行 3 个），其余上下滑动选择（v3.3.175）
                SizedBox(
                  height: 158,
                  child: SingleChildScrollView(
                    child: Wrap(spacing: 12, runSpacing: 12, children: [
                      for (final t in tiers)
                        _tierCard(t),
                    ]),
                  ),
                ),
              const SizedBox(height: 18),
              // ---- 充值方式（扫码支付排第一，v3.3.168）----
              Row(children: [
                Expanded(child: _modeChip(
                    '扫码支付',
                    WechatPayLogo(size: 19,
                        color: !cashMode ? PosTheme.accent : PosTheme.textSub),
                    !cashMode,
                    () {
                      setState(() => cashMode = false);
                      // v3.3.250：切回扫码支付时输入框刚重建，下一帧再要焦点
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) codeFocus.requestFocus();
                      });
                    })),
                const SizedBox(width: 12),
                Expanded(child: _modeChip('现金充值（权限码）',
                    Icon(Icons.payments_outlined, size: 18,
                        color: cashMode ? PosTheme.accent : PosTheme.textSub),
                    cashMode,
                    () => setState(() => cashMode = true))),
              ]),
              const SizedBox(height: 14),
              if (cashMode) ...[
                _pwdBox(),
                const SizedBox(height: 10),
                _pwdPad(),
              ] else
                PosField(
                  controller: codeCtrl,
                  focusNode: codeFocus,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  maxLength: 32,
                  enabled: !submitting,
                  onSubmitted: (_) => _submit(),
                  cleanScan: true,
                  label: '顾客付款码',
                  icon: Icons.qr_code,
                ),
            ]);
          },
        ),
      ),
      actions: [
        // 渐变大按钮（v3.3.168）：取消已移到右上角 X
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFF8A5C), Color(0xFFFF5B2E)]),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFFFF5B2E).withOpacity(0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4)),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: submitting ? null : _submit,
              child: Container(
                height: 56,
                alignment: Alignment.center,
                child: submitting
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                    : const Text('确认充值',
                        style: TextStyle(
                            fontSize: 17.5,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: 1)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 渐变头部：会员信息 + 当前余额（v3.3.118 美化）
  Widget _header(Map v) {
    final name = '${v['name'] ?? v['phone'] ?? '会员'}';
    final avatarRaw = '${v['avatar'] ?? ''}'.trim();
    final avatarUrl = avatarRaw.isEmpty
        ? ''
        : avatarRaw.startsWith('http')
            ? avatarRaw
            : Api.base + (avatarRaw.startsWith('/') ? '' : '/') + avatarRaw;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFF7A45), Color(0xFFFF5B2E)],
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: Colors.white.withOpacity(0.25),
              backgroundImage: avatarUrl.isEmpty ? null : NetworkImage(avatarUrl),
              onBackgroundImageError: avatarUrl.isEmpty ? null : (_, __) {},
              child: avatarUrl.isEmpty
                  ? Text(name.characters.isNotEmpty ? name.characters.first : '?',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white))
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('会员充值',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
                const SizedBox(height: 2),
                Text('${v['name'] ?? ''}　${v['phone'] ?? ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: Colors.white70)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _headerStat('当前余额', '¥${Fmt.money(v['amount'])}')),
            Expanded(child: _headerStat('赠送余额', '¥${Fmt.money(v['gift_balance'])}')),
            Expanded(child: _headerStat('积分', '${v['score'] ?? 0}')),
          ]),
        ]),
      ),
    );
  }

  Widget _headerStat(String k, String val) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(k, style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
      const SizedBox(height: 2),
      Text(val, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
    ]);
  }

  /// 充值档次卡（选中态橙色渐变，v3.3.118）
  Widget _tierCard(Map t) {
    final on = '${tier?['id']}' == '${t['id']}';
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: submitting ? null : () {
        setState(() => tier = t);
        // v3.3.250：点档次会把焦点抢走，付款码光标消失 → 扫码枪再扫输不进；还回去
        if (!cashMode) codeFocus.requestFocus();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 150,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          gradient: on
              ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [Color(0xFFFF8A5C), Color(0xFFFF5B2E)])
              : null,
          color: on ? null : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line, width: on ? 1.5 : 1),
          boxShadow: on
              ? [BoxShadow(color: PosTheme.accent.withOpacity(0.25), blurRadius: 10, offset: const Offset(0, 3))]
              : null,
        ),
        child: Column(children: [
          Text('¥${t['amount'] ?? 0}',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: on ? Colors.white : PosTheme.accent)),
          const SizedBox(height: 3),
          Text('送 ¥${t['zengsong'] ?? 0}',
              style: TextStyle(fontSize: 12, color: on ? Colors.white.withOpacity(0.9) : PosTheme.textSub)),
        ]),
      ),
    );
  }

  Widget _modeChip(String text, Widget icon, bool on, VoidCallback onTap) {
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
          icon,
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
