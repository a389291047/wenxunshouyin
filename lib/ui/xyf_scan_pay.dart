import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../core/api.dart';
import '../core/theme.dart';
import '../core/voice.dart';

/// 星驿付 · 扫码收款弹窗（v3.3.165，收银机接扫码枪）
///
/// 流程：扫码枪扫顾客付款码（或手动输入）→ 星驿付付款码下单（B扫C）
/// → 待输密码自动轮询 25 秒 → 成功返回 {'payNo': 渠道单号, 'orderNo': 我方单号, 'order': 订单行}
/// 取消/失败返回 null。
///
/// 视觉：弹窗近正方形（触屏友好）、微信支付/支付宝官方品牌色 + 官方 logo，
/// 付款码前缀实时识别渠道自动换主题（微信绿 07C160 / 支付宝蓝 1677FF / 云闪付红），
/// 取消改为右上角 X，确认收款为渐变大按钮。
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

// ---------- 官方品牌 logo（simple-icons 矢量，白色填充，viewBox 24x24） ----------
const String _svgWechat = '<svg fill="#ffffff" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">'
    '<path d="M8.691 2.188C3.891 2.188 0 5.476 0 9.53c0 2.212 1.17 4.203 3.002 5.55a.59.59 0 0 1 .213.665l-.39 1.48c-.019.07-.048.141-.048.213 0 .163.13.295.29.295a.326.326 0 0 0 .167-.054l1.903-1.114a.864.864 0 0 1 .717-.098 10.16 10.16 0 0 0 2.837.403c.276 0 .543-.027.811-.05-.857-2.578.157-4.972 1.932-6.446 1.703-1.415 3.882-1.98 5.853-1.838-.576-3.583-4.196-6.348-8.596-6.348zM5.785 5.991c.642 0 1.162.529 1.162 1.18a1.17 1.17 0 0 1-1.162 1.178A1.17 1.17 0 0 1 4.623 7.17c0-.651.52-1.18 1.162-1.18zm5.813 0c.642 0 1.162.529 1.162 1.18a1.17 1.17 0 0 1-1.162 1.178 1.17 1.17 0 0 1-1.162-1.178c0-.651.52-1.18 1.162-1.18zm5.34 2.867c-1.797-.052-3.746.512-5.28 1.786-1.72 1.428-2.687 3.72-1.78 6.22.942 2.453 3.666 4.229 6.884 4.229.826 0 1.622-.12 2.361-.336a.722.722 0 0 1 .598.082l1.584.926a.272.272 0 0 0 .14.047c.134 0 .24-.111.24-.247 0-.06-.023-.12-.038-.177l-.327-1.233a.582.582 0 0 1-.023-.156.49.49 0 0 1 .201-.398C23.024 18.48 24 16.82 24 14.98c0-3.21-2.931-5.837-6.656-6.088V8.89c-.135-.01-.27-.027-.407-.03zm-2.53 3.274c.535 0 .969.44.969.982a.976.976 0 0 1-.969.983.976.976 0 0 1-.969-.983c0-.542.434-.982.97-.982zm4.844 0c.535 0 .969.44.969.982a.976.976 0 0 1-.969.983.976.976 0 0 1-.969-.983c0-.542.434-.982.969-.982z"/></svg>';

const String _svgAlipay = '<svg fill="#ffffff" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">'
    '<path d="M19.695 15.07c3.426 1.158 4.203 1.22 4.203 1.22V3.846c0-2.124-1.705-3.845-3.81-3.845H3.914C1.808.001.102 1.722.102 3.846v16.31c0 2.123 1.706 3.845 3.813 3.845h16.173c2.105 0 3.81-1.722 3.81-3.845v-.157s-6.19-2.602-9.315-4.119c-2.096 2.602-4.8 4.181-7.607 4.181-4.75 0-6.361-4.19-4.112-6.949.49-.602 1.324-1.175 2.617-1.497 2.025-.502 5.247.313 8.266 1.317a16.796 16.796 0 0 0 1.341-3.302H5.781v-.952h4.799V6.975H4.77v-.953h5.81V3.591s0-.409.411-.409h2.347v2.84h5.744v.951h-5.744v1.704h4.69a19.453 19.453 0 0 1-1.986 5.06c1.424.52 2.702 1.011 3.654 1.333m-13.81-2.032c-.596.06-1.71.325-2.321.869-1.83 1.608-.735 4.55 2.968 4.55 2.151 0 4.301-1.388 5.99-3.61-2.403-1.182-4.438-2.028-6.637-1.809"/></svg>';

/// 渠道主题（官方品牌色）
class _PayChannel {
  final String key;
  final Color color; // 主色（官方品牌色）
  final Color dark; // 渐变深色
  final String? logo; // 官方 logo SVG（白），空则用扫码图标
  const _PayChannel(this.key, this.color, this.dark, {this.logo});
}

// 微信支付官方绿 07C160 / 支付宝官方蓝 1677FF / 云闪付红 E21836
const _chWechat =
    _PayChannel('wechat', Color(0xFF07C160), Color(0xFF06AD56), logo: _svgWechat);
const _chAlipay =
    _PayChannel('alipay', Color(0xFF1677FF), Color(0xFF0E5FD8), logo: _svgAlipay);
const _chUnion =
    _PayChannel('union', Color(0xFFE21836), Color(0xFFB50E26));
const _chDefault = _PayChannel('default', Color(0xFF2E6BFF), Color(0xFF1F4FD8));

_PayChannel? _channelByCode(String code) {
  code = code.replaceAll(RegExp(r'[\r\n\t\s]'), '');
  if (code.length >= 2) {
    final p = int.tryParse(code.substring(0, 2)) ?? 0;
    if (p >= 10 && p <= 15) return _chWechat; // 微信付款码 10-15 开头
    if (p >= 25 && p <= 30) return _chAlipay; // 支付宝付款码 25-30 开头
    if (code.startsWith('62')) return _chUnion; // 云闪付 62 开头
  }
  return null;
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

  /// 当前渠道主题：优先按已输入付款码前缀识别（实时换色），否则按标题文字
  _PayChannel get _channel {
    final byCode = _channelByCode(codeCtrl.text);
    if (byCode != null) return byCode;
    final t = widget.title;
    if (t.contains('微信')) return _chWechat;
    if (t.contains('支付宝')) return _chAlipay;
    return _chDefault;
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
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        if (done)
          const Icon(Icons.check_circle, size: 18, color: PosTheme.green)
        else if (active)
          const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: PosTheme.blue))
        else
          const Icon(Icons.radio_button_unchecked, size: 18, color: PosTheme.textHint),
        const SizedBox(width: 9),
        Text(text,
            style: TextStyle(
                fontSize: 14,
                fontWeight: done || active ? FontWeight.w700 : FontWeight.w400,
                color: done
                    ? PosTheme.green
                    : active
                        ? PosTheme.textMain
                        : PosTheme.textHint)),
      ]),
    );
  }

  /// 渐变主按钮（官方品牌色渐变 + 光晕阴影，触屏大按钮）
  Widget _mainButton(String label, VoidCallback onPressed) {
    final c = _channel;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c.color, c.dark]),
        boxShadow: [
          BoxShadow(
              color: c.color.withOpacity(0.35),
              blurRadius: 14,
              offset: const Offset(0, 5)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Container(
            height: 58,
            alignment: Alignment.center,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 1)),
          ),
        ),
      ),
    );
  }

  /// 头部 logo（官方品牌白 logo / 默认扫码图标）
  Widget _logo() {
    final c = _channel;
    return Container(
      width: 46, height: 46,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: c.logo != null
          ? SvgPicture.string(c.logo!, width: 28, height: 28)
          : const Icon(Icons.qr_code_scanner, size: 26, color: Colors.white),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _channel;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        width: 520,
        height: 545,
        child: Column(children: [
          // ===== 头部：官方品牌色渐变 + logo + 金额 + 右上角 X =====
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 0, 8, 0),
              height: 96,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [c.color, c.dark]),
              ),
              child: Row(children: [
                _logo(),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(widget.title,
                      style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ),
                Text('¥${Fmt.money(widget.amount)}',
                    style: const TextStyle(
                        fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white)),
                // 支付中不允许关闭（防止漏单），其余阶段显示右上角 X
                if (phase != 'paying')
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 26, color: Colors.white),
                    tooltip: '关闭',
                    splashRadius: 22,
                  )
                else
                  const SizedBox(width: 48),
              ]),
            ),
          ),
          // ===== 内容 =====
          Expanded(
            child: Center(
              child: phase == 'input'
                  ? _buildInput()
                  : phase == 'paying'
                      ? _buildPaying()
                      : phase == 'success'
                          ? _buildSuccess()
                          : _buildFail(),
            ),
          ),
          // ===== 底部按钮 =====
          if (phase == 'input')
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 26),
              child: _mainButton('确认收款', _pay),
            )
          else if (phase == 'fail')
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 26),
              child: _mainButton('重新扫码', _retry),
            )
          else
            const SizedBox(height: 16),
        ]),
      ),
    );
  }

  // ---------- 等待扫码 ----------
  Widget _buildInput() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('扫码枪对准顾客付款码（微信/支付宝/云闪付自动识别）',
            style: TextStyle(fontSize: 14, color: PosTheme.textSub)),
        const SizedBox(height: 16),
        TextField(
          controller: codeCtrl,
          focusNode: focusNode,
          autofocus: true,
          enabled: !submitting,
          keyboardType: TextInputType.number,
          maxLength: 32,
          style: const TextStyle(
              fontSize: 23, fontWeight: FontWeight.w700, letterSpacing: 1.5),
          onChanged: (v) {
            // 清除扫码枪带回的换行/制表符等脏字符；并按前缀实时识别渠道换主题色
            final clean = v.replaceAll(RegExp(r'[\r\n\t\s]'), '');
            if (clean != v) {
              codeCtrl.value = TextEditingValue(
                  text: clean,
                  selection: TextSelection.collapsed(offset: clean.length));
            }
            setState(() {});
          },
          onSubmitted: (_) => _pay(),
          decoration: InputDecoration(
            labelText: '顾客付款码',
            counterText: '',
            prefixIcon: const Icon(Icons.qr_code, size: 24),
            contentPadding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            suffixIcon: codeCtrl.text.isEmpty
                ? null
                : IconButton(icon: const Icon(Icons.clear, size: 20), onPressed: () => setState(() => codeCtrl.clear())),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        if (errorMsg.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.error_outline, size: 16, color: PosTheme.red),
            const SizedBox(width: 5),
            Expanded(child: Text(errorMsg, style: const TextStyle(fontSize: 13, color: PosTheme.red))),
          ]),
        ],
        const SizedBox(height: 12),
        const Text('也可手动输入付款码后按回车 / 点「确认收款」',
            style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
        if ((widget.moreLabel ?? '').isNotEmpty) ...[
          const SizedBox(height: 4),
          Center(
            child: TextButton.icon(
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
              onPressed: () => Navigator.pop(context, {'more': true}),
              icon: const Icon(Icons.tune, size: 16),
              label: Text(widget.moreLabel!,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ]),
    );
  }

  // ---------- 支付中 ----------
  Widget _buildPaying() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 34),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // 大号转圈（呼吸光环），收银员一眼可见
        Container(
          width: 110, height: 110,
          decoration: BoxDecoration(
            color: PosTheme.blue.withOpacity(0.07),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const SizedBox(
              width: 72, height: 72,
              child: CircularProgressIndicator(strokeWidth: 5.5, color: PosTheme.blue)),
        ),
        const SizedBox(height: 20),
        // 当前状态大字（随进度切换）
        Text(_payStatusText,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('已等待 $elapsedSec 秒 · 最长 25 秒',
            style: const TextStyle(fontSize: 13, color: PosTheme.textHint)),
        const SizedBox(height: 18),
        // 三步进度条
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            borderRadius: BorderRadius.circular(14),
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
    );
  }

  // ---------- 成功 ----------
  Widget _buildSuccess() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 84, height: 84,
            decoration: BoxDecoration(color: PosTheme.green.withOpacity(0.12), shape: BoxShape.circle),
            child: const Icon(Icons.check, size: 48, color: PosTheme.green)),
        const SizedBox(height: 18),
        const Text('收款成功', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('¥${Fmt.money(widget.amount)}',
            style: const TextStyle(fontSize: 18, color: PosTheme.textSub,
                fontWeight: FontWeight.w700)),
        if ('${order?['pay_channel'] ?? ''}'.isNotEmpty)
          Text('渠道 ${order?['pay_channel'] ?? ''}',
              style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
      ]),
    );
  }

  // ---------- 失败 ----------
  Widget _buildFail() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 84, height: 84,
            decoration: BoxDecoration(color: PosTheme.red.withOpacity(0.1), shape: BoxShape.circle),
            child: const Icon(Icons.close, size: 48, color: PosTheme.red)),
        const SizedBox(height: 18),
        const Text('收款失败',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800, color: PosTheme.red)),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(errorMsg, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14.5, color: PosTheme.textSub)),
        ),
      ]),
    );
  }
}
