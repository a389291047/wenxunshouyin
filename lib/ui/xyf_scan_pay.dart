import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/theme.dart';
import '../core/voice.dart';
import 'brand_logos.dart';
import 'widgets.dart';

/// 星驿付 · 扫码收款弹窗（v3.3.165，收银机接扫码枪）
///
/// 流程：扫码枪扫顾客付款码（或手动输入）→ 星驿付付款码下单（B扫C）
/// → 待输密码自动轮询（先快后慢，最长 60 秒，v3.3.248）→ 成功返回 {'payNo': 渠道单号, 'orderNo': 我方单号, 'order': 订单行}
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

/// 渠道主题（官方品牌色）
class _PayChannel {
  final String key;
  final Color color; // 主色（官方品牌色）
  final Color dark; // 渐变深色
  const _PayChannel(this.key, this.color, this.dark);
}

// 微信支付官方绿 07C160 / 支付宝官方蓝 1677FF / 云闪付红 E21836
const _chWechat = _PayChannel('wechat', Color(0xFF07C160), Color(0xFF06AD56));
const _chAlipay = _PayChannel('alipay', Color(0xFF1677FF), Color(0xFF0E5FD8));
const _chUnion = _PayChannel('union', Color(0xFFE21836), Color(0xFFB50E26));
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

/// 付款码前缀 → 数值渠道（1支付宝 2微信 9云闪付），未知返回 0（v3.3.260）
int _channelNoByCode(String code) {
  final c = _channelByCode(code);
  if (c == _chAlipay) return 1;
  if (c == _chWechat) return 2;
  if (c == _chUnion) return 9;
  return 0;
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
  String _payNo = ''; // 本次/上次提交用的我方单号（重试前先查它，防重复收款）
  bool _needNewNo = false; // 上一笔已确认失败，下次提交换新单号

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
  /// [forceNew]=true 时忽略外部单号重新生成（上一笔已确认失败，重试必须换号）
  String _genOrderNo({bool forceNew = false}) {
    if (!forceNew && (widget.orderNo ?? '').isNotEmpty) return widget.orderNo!;
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
      // v3.3.250：焦点必须还给输入框，否则扫码枪再扫时数字落不进来（收银员以为坏了）
      focusNode.requestFocus();
      return;
    }
    setState(() {
      submitting = true;
      phase = 'paying';
      payStatus = 'scanned';
      errorMsg = '';
    });
    _startElapsed();
    final no = _genOrderNo(forceNew: _needNewNo);
    _payNo = no;
    _needNewNo = false;
    try {
      final o = await Api.xyfScanPay(
        amount: widget.amount,
        authCode: code,
        orderNo: no,
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
          'channel': (int.tryParse('${o['pay_channel'] ?? 0}') ?? 0) > 0
              ? int.tryParse('${o['pay_channel'] ?? 0}') ?? 0
              : _channelNoByCode(codeCtrl.text),
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

  /// 重新扫码（v3.3.220）：先回查上一笔单号，避免「上一笔其实已付款」还让顾客再付一次。
  /// - 已支付成功 → 直接按成功回传（正常落单，不再产生未落单流水）
  /// - 仍在处理中 → 拦住并提示等待，不重复收款
  /// - 已明确失败 / 查不到 → 换新单号重新扫码
  Future<void> _retry() async {
    final lastNo = _payNo;
    if (lastNo.isNotEmpty) {
      try {
        final q = await Api.xyfQueryOrder(lastNo);
        final d = q['data'];
        if ('${q['code']}' == '0' && d is Map) {
          final m = Map<String, dynamic>.from(d);
          final st = int.tryParse('${m['status'] ?? 0}') ?? 0;
          if (st == 3) {
            // 上一笔其实已经付成功了：按成功回传，避免重复收款 + 未落单
            if (!mounted) return;
            VoiceService.instance.pay('扫码', widget.amount);
            setState(() {
              order = m;
              phase = 'success';
              errorMsg = '';
            });
            Future.delayed(const Duration(milliseconds: 1200), () {
              if (!mounted) return;
              Navigator.pop(context, {
                'payNo': '${m['order_no'] ?? ''}',
                'orderNo': '${m['three_order_no'] ?? lastNo}',
                'channel': (int.tryParse('${m['pay_channel'] ?? 0}') ?? 0) > 0
                    ? int.tryParse('${m['pay_channel'] ?? 0}') ?? 0
                    : _channelNoByCode(codeCtrl.text),
                'order': m,
              });
            });
            return;
          }
          if (st == 1 || st == 2) {
            if (!mounted) return;
            setState(() => errorMsg = '上一笔仍在等待支付结果，请稍等片刻再点「重新扫码」，请勿重复向顾客收款');
            toast(context, '上一笔仍在处理中，稍等再试', error: true);
            return;
          }
        }
      } catch (_) {
        // 查询失败：按未完成处理，换新单号
      }
    }
    _needNewNo = true;
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

  /// 头部 logo（微信支付/支付宝官方品牌 logo，其余用扫码图标）
  Widget _logo() {
    final c = _channel;
    return Container(
      width: 48, height: 48,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: c.key == 'wechat'
          // 微信支付官方 logo（气泡+对勾），绿色头部上用白色版
          ? WechatPayLogo(size: 32, color: Colors.white)
          : c.key == 'alipay'
              ? AlipayLogo(size: 30, color: Colors.white)
              : const Icon(Icons.qr_code_scanner, size: 26, color: Colors.white),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _channel;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
        SizedBox(
        width: 520,
        height: 545,
        child: Column(children: [
          // ===== 头部：官方品牌色渐变 + logo + 金额 =====
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
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
      // ===== 悬浮关闭按钮：凸出右上角，透明底白色 X（触屏热区 44px）=====
      if (phase != 'paying')
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
        if ((widget.moreLabel ?? '').isNotEmpty) ...[
          const SizedBox(height: 12),
          // v3.3.250：由文字链改为触屏大按钮「更换支付」（收银员点完确认收款没反应时的出口）
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                side: const BorderSide(color: PosTheme.line),
                backgroundColor: const Color(0xFFF7F8FA),
              ),
              onPressed: () => Navigator.pop(context, {'more': true}),
              icon: const Icon(Icons.swap_horiz, size: 20),
              label: Text(widget.moreLabel!,
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
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
        Text('已等待 $elapsedSec 秒 · 最长 60 秒',
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
            _step('支付受理完成',
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
