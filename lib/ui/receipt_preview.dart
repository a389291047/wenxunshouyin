import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/cloud_printer.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// 小票预览弹窗（v3.3.77 设置页预览；v3.3.82 抽为公开组件供账单「预结单」等复用）
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
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 380,
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.receipt_long_outlined, size: 19, color: PosTheme.accent),
            const SizedBox(width: 8),
            Expanded(child: Text('小票预览 · ${widget.title}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 12),
          // 纸张效果预览
          Container(
            constraints: const BoxConstraints(maxHeight: 430),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFEF9),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: PosTheme.line),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: SingleChildScrollView(
              child: Text(
                widget.content,
                style: const TextStyle(
                  fontFamily: 'Menlo',
                  fontFamilyFallback: ['Menlo', 'Courier New', 'monospace'],
                  fontSize: 12.5,
                  height: 1.55,
                  color: PosTheme.textMain,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: BigButton('关闭', onTap: () => Navigator.pop(context), color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 44)),
            const SizedBox(width: 10),
            Expanded(child: BigButton('打印', onTap: printing ? null : _testPrint, height: 44)),
          ]),
        ]),
      ),
    );
  }
}
