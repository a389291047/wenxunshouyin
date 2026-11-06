import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api.dart';
import '../core/cloud_printer.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// 纸张规格：58mm 热敏（32 字符/行）/ 80mm 热敏（48 字符/行）
class _PaperSpec {
  final String label;
  final String desc;
  final double width; // 预览纸宽（px）
  final double fontSize; // 正文字号
  final int chars; // 每行字符数
  const _PaperSpec({
    required this.label,
    required this.desc,
    required this.width,
    required this.fontSize,
    required this.chars,
  });
}

const _p58 = _PaperSpec(label: '58mm', desc: '32 字符/行 · 小票机常用', width: 296, fontSize: 11.0, chars: 32);
const _p80 = _PaperSpec(label: '80mm', desc: '48 字符/行 · 宽度更大', width: 424, fontSize: 12.2, chars: 48);

/// 小票预览弹窗（v3.3.77 设置页预览；v3.3.82 抽为公开组件供账单「预结单」等复用）
/// v3.3.95：新增 58mm / 80mm 双规格预览切换 + 整体美化
class ReceiptPreviewDialog extends StatefulWidget {
  final String title;
  final String content;

  /// 指定云打印机 machine_code（空 = 自动选收银小票类型打印机）
  final String machineCode;
  const ReceiptPreviewDialog({super.key, required this.title, required this.content, this.machineCode = ''});

  @override
  State<ReceiptPreviewDialog> createState() => _ReceiptPreviewDialogState();
}

class _ReceiptPreviewDialogState extends State<ReceiptPreviewDialog> {
  bool printing = false;
  bool _wide = false; // false = 58mm，true = 80mm
  static const _kPref80 = 'receipt_preview_80mm';

  _PaperSpec get _spec => _wide ? _p80 : _p58;

  @override
  void initState() {
    super.initState();
    // 记住上次选择的纸张规格
    SharedPreferences.getInstance().then((sp) {
      final v = sp.getBool(_kPref80);
      if (v != null && mounted && v != _wide) setState(() => _wide = v);
    });
  }

  void _switchSize(bool wide) {
    if (_wide == wide) return;
    setState(() => _wide = wide);
    SharedPreferences.getInstance().then((sp) => sp.setBool(_kPref80, wide));
  }

  Future<void> _testPrint() async {
    if (printing) return;
    setState(() => printing = true);
    try {
      await CloudPrinter.printFront(widget.content, machineCode: widget.machineCode);
      if (!mounted) return;
      toast(context, '已发送打印');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) toast(context, '打印失败：$e', error: true);
    }
    if (mounted) setState(() => printing = false);
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.88;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: _wide ? 592 : 464,
        constraints: BoxConstraints(maxHeight: maxH),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 40, offset: const Offset(0, 16))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(),
          _sizePicker(),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: _canvas(),
            ),
          ),
          _footer(),
        ]),
      ),
    );
  }

  // ==================== 头部 ====================
  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PosTheme.line)),
      ),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFF8A3D), Color(0xFFF25C2A)],
            ),
            borderRadius: BorderRadius.circular(11),
            boxShadow: [BoxShadow(color: const Color(0xFFF25C2A).withOpacity(0.28), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: const Icon(Icons.receipt_long_outlined, size: 21, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('小票预览', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.2)),
            const SizedBox(height: 3),
            Text(widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: PosTheme.textHint, height: 1.2)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF5EC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFFFDDC2)),
          ),
          child: Row(children: [
            const Icon(Icons.print_outlined, size: 13, color: Color(0xFFE2703A)),
            const SizedBox(width: 4),
            Text('${_spec.label} 热敏纸',
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFFE2703A))),
          ]),
        ),
      ]),
    );
  }

  // ==================== 58 / 80 规格切换 ====================
  Widget _sizePicker() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: const Color(0xFFF2F3F7), borderRadius: BorderRadius.circular(11)),
          child: Row(children: [
            _sizeChip('58mm 小票', false),
            _sizeChip('80mm 小票', true),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(_spec.desc,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
        ),
      ]),
    );
  }

  Widget _sizeChip(String label, bool wide) {
    final on = _wide == wide;
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () => _switchSize(wide),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: on ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          boxShadow: on
              ? [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 6, offset: const Offset(0, 2))]
              : null,
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              color: on ? PosTheme.accent : PosTheme.textSub,
            )),
      ),
    );
  }

  // ==================== 纸张画布 ====================
  Widget _canvas() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFEDEFF4),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: _spec.width,
          child: Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFFFFFF), Color(0xFFFFFEF8)],
              ),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.14), blurRadius: 20, offset: const Offset(0, 6)),
                BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 3, offset: const Offset(0, 1)),
              ],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // 纸头（撕口质感）
              Container(
                height: 5,
                margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF1F5),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _renderLines(widget.content, _spec),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// 把纯文本小票内容按行渲染成有层次的排版（标题居中加粗、分隔线虚线化、明细缩进弱化、金额加粗）
  List<Widget> _renderLines(String content, _PaperSpec s) {
    final lines = content.replaceAll('\r', '').split('\n');
    final out = <Widget>[];
    final sepRe = RegExp(r'^[-=_·]{3,}$');
    final moneyRe = RegExp(r'(合计|实收|营业总额|应付|退款金额|收款笔数|抹零)');

    for (final raw in lines) {
      final rawTrim = raw.replaceAll('\r', '').trim();
      // 居中大标题需在剥标签之前识别：旧协议 <CB></CB> / 新协议 <FS2><center></center></FS2>
      final low = rawTrim.toLowerCase();
      final isTitle = low.contains('<cb>') ||
          (low.contains('<center>') && (low.contains('<fs2>') || low.contains('<fs>')));
      if (isTitle) {
        final title = rawTrim.replaceAll(RegExp(r'<[A-Za-z/][^>]*>'), '').trim();
        out.add(Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: s.fontSize + 5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.6,
              height: 1.3,
              color: const Color(0xFF1B1D22),
            ),
          ),
        ));
        continue;
      }
      final line = raw.replaceAll(RegExp(r'<[A-Za-z/][^>]*>'), '');
      final t = line.trimRight();
      final trimmed = t.trim();

      if (trimmed.isEmpty) {
        out.add(SizedBox(height: s.fontSize * 0.8));
        continue;
      }
      // 分隔线 → 虚线
      if (sepRe.hasMatch(trimmed)) {
        out.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: CustomPaint(painter: _DashPainter(color: const Color(0xFFD8DBE3)), child: const SizedBox(height: 1, width: double.infinity)),
        ));
        continue;
      }
      // 备注行（缩进 / 以「做法」「备注」开头）弱化
      final isNote = t.startsWith('  ') || trimmed.startsWith('做法:') || trimmed.startsWith('备注:');
      final isMoney = moneyRe.hasMatch(trimmed);
      // 居中提示行（※ 开头）单独处理
      final isTip = trimmed.startsWith('※') || trimmed.startsWith('谢谢惠顾');
      // 字体大小标签（v3.3.126）：<FS> 加大一档 / <FS2> 特大（预览同步呈现，实机以打印机为准）
      final lowLine = rawTrim.toLowerCase();
      final fsDelta = lowLine.contains('<fs2>') ? 4.0 : (lowLine.contains('<fs>') ? 2.0 : 0.0);

      out.add(Padding(
        padding: EdgeInsets.only(top: isTip ? 3 : 0.5, bottom: isTip ? 3 : 0.5),
        child: Text(
          isNote ? t : trimmed,
          textAlign: isTip ? TextAlign.center : TextAlign.left,
          style: TextStyle(
            fontFamily: 'Menlo',
            fontFamilyFallback: const ['Menlo', 'Courier New', 'monospace'],
            fontSize: fsDelta > 0
                ? s.fontSize + fsDelta
                : (isNote ? s.fontSize - 0.8 : s.fontSize),
            height: 1.62,
            letterSpacing: 0.1,
            color: isNote ? PosTheme.textHint : (isTip ? PosTheme.textSub : const Color(0xFF23262D)),
            fontWeight: isMoney || fsDelta > 0 ? FontWeight.w700 : FontWeight.w400,
            fontStyle: isTip ? FontStyle.italic : FontStyle.normal,
          ),
        ),
      ));
    }
    // 纸尾撕口
    out.add(Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 0),
      child: CustomPaint(painter: _DashPainter(color: const Color(0xFFE2E5EC)), child: const SizedBox(height: 1, width: double.infinity)),
    ));
    return out;
  }

  // ==================== 底部操作 ====================
  Widget _footer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(18)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Icon(Icons.info_outline, size: 13, color: PosTheme.textHint),
          const SizedBox(width: 5),
          Expanded(
            child: Text('预览排版与实机打印一致（${_spec.chars} 字符/行），实际字体以打印机为准',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: BigButton('关闭',
                onTap: () => Navigator.pop(context),
                color: const Color(0xFFF2F3F7),
                textColor: PosTheme.textSub,
                height: 46),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: BigButton(printing ? '打印中…' : '打印', onTap: printing ? null : _testPrint, height: 46),
          ),
        ]),
      ]),
    );
  }
}

/// 虚线分割（模拟热敏纸分隔 / 撕口）
class _DashPainter extends CustomPainter {
  final Color color;
  _DashPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    const dash = 4.0;
    const gap = 3.0;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0.5), Offset((x + dash).clamp(0, size.width), 0.5), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashPainter old) => old.color != color;
}
