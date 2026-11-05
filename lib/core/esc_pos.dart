import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

/// ESC/POS 小票指令编码
///
/// 输入为与云打印一致的文本格式，同时兼容易联云新旧两套排版标签：
/// - `<CB>标题</CB>`（旧协议）→ 居中 + 倍大 + 加粗
/// - `<FS2><center>标题</center></FS2>`（新协议 K4/K5/K6/K7/K8）→ 居中 + 倍大 + 加粗
/// - `<center>` / `<FB>` / `<FS>` 等新协议标签按各自效果渲染
/// - 其余行 → 左对齐正文
/// 中文用 GBK 编码（热敏打印机内置 GB2312/GBK 中文字库），并先发 FS& 开启汉字模式。
class EscPos {
  EscPos._();

  /// 58mm 纸有效行宽（半角字符数）
  static const int width58 = 32;

  /// 80mm 纸有效行宽
  static const int width80 = 48;

  /// 已知排版标签（新旧协议），渲染时剥除
  static final RegExp _tagRe =
      RegExp(r'</?(CB|C|B|BOLD|FS|FS2|FB|FH|FH2|FW|FW2|center|right|left)>', caseSensitive: false);

  /// 把云打印文本格式转成 ESC/POS 字节流
  static Uint8List encode(String content, {int paperWidth = 58}) {
    final width = paperWidth >= 80 ? width80 : width58;
    final out = BytesBuilder();
    out.add([0x1B, 0x40]); // ESC @ 初始化
    out.add([0x1C, 0x26]); // FS & 开启中文模式

    final lines = content.replaceAll('\r\n', '\n').split('\n');
    for (final raw in lines) {
      final t = raw.trim();
      if (t.isEmpty) {
        out.add([0x0A]);
        continue;
      }
      // 标记识别（剥标签前）：center=居中，fs2=倍大，fb=加粗
      final lower = t.toLowerCase();
      final center = lower.contains('<center>') || lower.contains('<cb>');
      final double = lower.contains('<fs2>') || lower.contains('<cb>');
      final bold = lower.contains('<fb>') || lower.contains('<cb>') || lower.contains('<bold>');
      final text = t.replaceAll(_tagRe, '');
      if (text.isEmpty) {
        out.add([0x0A]);
        continue;
      }
      if (center || double || bold) {
        for (final line in _wrap(text, double ? width ~/ 2 : width)) {
          _text(out, line, center: center, double: double, bold: bold);
          out.add([0x0A]);
        }
        if (double) out.add([0x0A]); // 倍大标题后空一行
      } else {
        for (final line in _wrap(text, width)) {
          _text(out, line);
          out.add([0x0A]);
        }
      }
    }

    out.add([0x0A, 0x0A]);
    out.add([0x1B, 0x64, 0x04]); // ESC d 4 走纸 4 行
    out.add([0x1D, 0x56, 0x42, 0x00]); // GS V B 0 半切纸
    return out.toBytes();
  }

  /// 按显示宽度折行（中文/全角占 2，半角占 1）
  static List<String> _wrap(String s, int width) {
    if (_dispWidth(s) <= width) return [s];
    final out = <String>[];
    final buf = StringBuffer();
    var w = 0;
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      final cw = _dispWidth(ch);
      if (w + cw > width) {
        out.add(buf.toString());
        buf.clear();
        w = 0;
      }
      buf.write(ch);
      w += cw;
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  static int _dispWidth(String s) {
    var w = 0;
    for (final cu in s.codeUnits) {
      w += cu > 0xFF ? 2 : 1;
    }
    return w;
  }

  static void _text(BytesBuilder out, String s,
      {bool center = false, bool double = false, bool bold = false}) {
    out.add([0x1B, 0x61, center ? 1 : 0]); // ESC a n 对齐
    out.add([0x1D, 0x21, double ? 0x11 : 0x00]); // GS ! n 倍大
    out.add([0x1B, 0x45, bold ? 1 : 0]); // ESC E n 加粗
    out.add(gbk.encode(s));
    if (double || bold || center) {
      out.add([0x1B, 0x61, 0]);
      out.add([0x1D, 0x21, 0x00]);
      out.add([0x1B, 0x45, 0]);
    }
  }
}
