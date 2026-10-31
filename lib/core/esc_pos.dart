import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

/// ESC/POS 小票指令编码
///
/// 输入为与云打印一致的文本格式：
/// - `<CB>标题</CB>` → 居中 + 倍大 + 加粗
/// - 其余行 → 左对齐正文
/// 中文用 GBK 编码（热敏打印机内置 GB2312/GBK 中文字库），并先发 FS& 开启汉字模式。
class EscPos {
  EscPos._();

  /// 58mm 纸有效行宽（半角字符数）
  static const int width58 = 32;

  /// 80mm 纸有效行宽
  static const int width80 = 48;

  /// 把云打印文本格式转成 ESC/POS 字节流
  static Uint8List encode(String content, {int paperWidth = 58}) {
    final width = paperWidth >= 80 ? width80 : width58;
    final out = BytesBuilder();
    out.add([0x1B, 0x40]); // ESC @ 初始化
    out.add([0x1C, 0x26]); // FS & 开启中文模式

    final lines = content.replaceAll('\r\n', '\n').split('\n');
    for (final raw in lines) {
      final t = raw.trim();
      if (t.startsWith('<CB>') && t.contains('</CB>')) {
        final title = t.substring(4, t.indexOf('</CB>'));
        for (final line in _wrap(title, width)) {
          _text(out, line, center: true, double: true, bold: true);
          out.add([0x0A]);
        }
        out.add([0x0A]); // 标题后空一行
      } else if (t.isEmpty) {
        out.add([0x0A]);
      } else {
        for (final line in _wrap(t, width)) {
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
