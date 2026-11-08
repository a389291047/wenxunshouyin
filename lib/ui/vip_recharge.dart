import 'package:flutter/material.dart';
import '../core/api.dart';
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
/// - 关闭按钮为右上角悬浮白色 X
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
        // ---- 付款码充值（v3.3.161）：星驿付付款码支付 + 轮询，成功后入账 ----
        final code = codeCtrl.text.replaceAll(RegExp(r'[\r\n\t\s]'), '').trim();
        if (!RegExp(r'^\d{16,32}$').hasMatch(code)) {
          setState(() => submitting = false);
          toast(context, '请输入有效的付款码（16-32位数字）', error: true);
          return;
        }
        final myNo = 'XYFC${DateTime.now().millisecondsSinceEpoch}'
            '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
        try {
          final o = await Api.xyfScanPay(
            amount: amount,
            authCode: code,
            orderNo: myNo,
            bizType: 'recharge',
          );
          if (!mounted) return;
          VoiceService.instance.pay('扫码', amount);
          // 入账单号优先星驿渠道单号，其次我方业务单号（后端双匹配）
          orderNo = '${o['order_no'] ?? ''}';
          if (orderNo.isEmpty) orderNo = '${o['three_order_no'] ?? myNo}';
        } on ApiError catch (e) {
          if (!mounted) return;
          setState(() => submitting = false);
          final raw = e.message;
          // 未开通星驿付：明确提示联系客服
          if (raw.contains('开通支付') || raw.contains('商户号') || raw.contains('cust')) {
            toast(context, '商户未开通星驿付收款，请联系客服开通支付', error: true);
          } else {
            toast(context, raw, error: true);
          }
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
    return Stack(
      clipBehavior: Clip.none,
      children: [
      AlertDialog(
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
                Wrap(spacing: 12, runSpacing: 12, children: [
                  for (final t in tiers)
                    _tierCard(t),
                ]),
              const SizedBox(height: 18),
              // ---- 充值方式（扫码支付排第一，v3.3.168）----
              Row(children: [
                Expanded(child: _modeChip(
                    '扫码支付',
                    WechatPayLogo(size: 19,
                        color: !cashMode ? PosTheme.accent : PosTheme.textSub),
                    !cashMode,
                    () => setState(() => cashMode = false))),
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
      ),
      // ===== 悬浮关闭按钮：凸出右上角，透明底白色 X =====
      Positioned(
        top: -8,
        right: -8,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => Navigator.pop(context),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.close_rounded,
                  size: 26,
                  color: Colors.white,
                  shadows: const [
                    Shadow(
                        color: Color(0x4D000000),
                        blurRadius: 6,
                        offset: Offset(0, 2)),
                  ]),
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
      onTap: submitting ? null : () => setState(() => tier = t),
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
