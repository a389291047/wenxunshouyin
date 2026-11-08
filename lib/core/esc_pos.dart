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

  /// 把云打印文本格式转成 ESC/POS 字节流（热敏小票机）
  /// mode = 'pos'（热敏 ESC/POS）| 'escp'（针式 ESC/P2，如 EPSON LQ 系列）
  /// [textW] 版心宽（针式用）：小票内容排版列数，整张小票按版心在页面上水平居中；
  /// 缺省等于 paperWidth
  /// [offsetCols] 水平微调（v3.3.159）：正值右移、负值左移（半角列），
  /// 商户按进纸位置自定义；针式在居中基础上偏移，热敏在贴左基础上偏移
  static Uint8List encode(String content,
      {int paperWidth = 58, String mode = 'pos', int? textW, int offsetCols = 0}) {
    if (mode == 'escp') return _encodeEscP(content, paperWidth, textW ?? paperWidth, offsetCols);
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
      // 标记识别（剥标签前）：center=居中，fs2=倍大，fs=加高一档，fb=加粗
      final lower = t.toLowerCase();
      final center = lower.contains('<center>') || lower.contains('<cb>');
      final double = lower.contains('<fs2>') || lower.contains('<cb>');
      final big = !double && lower.contains('<fs>'); // <FS> 中文32高（默认24），按倍高渲染
      final bold = lower.contains('<fb>') || lower.contains('<cb>') || lower.contains('<bold>');
      final text = t.replaceAll(_tagRe, '');
      if (text.isEmpty) {
        out.add([0x0A]);
        continue;
      }
      if (offsetCols == 0) {
        if (center || double || big || bold) {
          for (final line in _wrap(text, double ? width ~/ 2 : width)) {
            _text(out, line, center: center, double: double, bold: bold, big: big);
            out.add([0x0A]);
          }
          if (double) out.add([0x0A]); // 倍大标题后空一行
        } else {
          for (final line in _wrap(text, width)) {
            _text(out, line);
            out.add([0x0A]);
          }
        }
      } else {
        // 微调模式：全部改为手动空格定位（居中行也手工计算，避免 ESC a 覆盖缩进）
        final wrapW = double ? width ~/ 2 : (offsetCols > 0 ? width - offsetCols : width);
        for (final line in _wrap(text, wrapW < 1 ? 1 : wrapW)) {
          final printed = double ? _dispWidth(line) * 2 : _dispWidth(line); // big 仅倍高不改宽
          var pad = offsetCols;
          if (center) pad += ((width - printed) ~/ 2).clamp(0, width);
          if (pad > 0) out.add(List<int>.filled(pad, 0x20));
          _text(out, line, double: double, bold: bold, big: big);
          out.add([0x0A]);
        }
        if (double) out.add([0x0A]);
      }
    }

    out.add([0x0A, 0x0A]);
    out.add([0x1B, 0x64, 0x04]); // ESC d 4 走纸 4 行
    out.add([0x1D, 0x56, 0x42, 0x00]); // GS V B 0 半切纸
    return out.toBytes();
  }

  /// 针式打印机（ESC/P2，EPSON LQ 系列等）：
  /// - [pageW] 页宽：整张纸可打印的半角列数（10cpi，如 241mm 连续纸约 92 列）；
  ///   [textW] 版心宽：小票内容排版列数。整张小票按版心在页面上**水平居中**，
  ///   解决 241mm 连续纸 / A4 上内容全部贴左打印的问题
  /// - 分隔线统一拉伸到版心宽，标题类行在版心内再居中
  /// - 不发热敏专用指令（GS ! 倍大 / GS V 切刀 / ESC d 走纸），
  ///   针式机不认切刀指令会导致任务卡在「正在打印」
  /// - 末尾发 FF（0x0C）换页：手动送纸/连续纸立即走纸出页，不再卡住
  /// - [offsetCols] 水平微调：在居中位置基础上再偏移（正=右移，负=左移）
  static Uint8List _encodeEscP(String content, int pageW, int textW, int offsetCols) {
    final out = BytesBuilder();
    out.add([0x1B, 0x40]); // ESC @ 初始化（10cpi）
    out.add([0x1C, 0x26]); // FS & 中文模式（针式机内置 GB2312 字库）

    // 1) 解析行：剥标签、识别居中/倍大/加粗/分隔线
    final rows = <Map<String, Object?>>[];
    for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
      final t = raw.trim();
      if (t.isEmpty) {
        rows.add({'empty': true});
        continue;
      }
      final lower = t.toLowerCase();
      final center = lower.contains('<center>') || lower.contains('<cb>');
      final double = lower.contains('<fs2>') || lower.contains('<cb>');
      final bold = lower.contains('<fb>') || lower.contains('<cb>') || lower.contains('<bold>');
      final text = t.replaceAll(_tagRe, '');
      if (text.isEmpty) {
        rows.add({'empty': true});
        continue;
      }
      // 分隔线（纯符号且较长）：统一拉伸到版心宽
      if (text.length >= 8 && RegExp(r'^[-=*_~·— ]+$').hasMatch(text)) {
        rows.add({'sep': true});
        continue;
      }
      for (final line in _wrap(text, double ? textW ~/ 2 : textW)) {
        rows.add({'text': line, 'center': center, 'double': double, 'bold': bold});
      }
      if (double) rows.add({'empty': true}); // 倍大标题后空一行
    }

    // 2) 计算版心（整张小票的实际宽度）：分隔线定宽，其余取最长行
    var blockW = textW;
    for (final r in rows) {
      if (r['text'] is! String) continue;
      final w = (r['double'] == true ? 2 : 1) * _dispWidth(r['text'] as String);
      if (w > blockW) blockW = w;
    }
    if (blockW > pageW) blockW = pageW;
    // 整张小票在纸上的水平位置：居中基础 + 商户微调，夹在 [0, 页宽-版心] 内
    final left = (((pageW - blockW) ~/ 2) + offsetCols).clamp(0, pageW - blockW);

    void emit(String text, int pad, {bool double = false, bool bold = false}) {
      if (pad > 0) out.add(List<int>.filled(pad, 0x20));
      if (double) {
        out.add([0x1B, 0x77, 1]); // ESC w 1 倍高
        out.add([0x1B, 0x57, 1]); // ESC W 1 倍宽
      }
      if (bold) out.add([0x1B, 0x45, 1]); // ESC E 加粗
      out.add(gbk.encode(text));
      if (double) {
        out.add([0x1B, 0x77, 0]);
        out.add([0x1B, 0x57, 0]);
      }
      if (bold) out.add([0x1B, 0x45, 0]);
      out.add([0x0A]);
    }

    // 3) 输出：整块右移 left 列；标题类行在版心内再居中
    for (final r in rows) {
      if (r['empty'] == true) {
        out.add([0x0A]);
        continue;
      }
      if (r['sep'] == true) {
        emit(''.padRight(blockW, '-'), left);
        continue;
      }
      final double = r['double'] == true;
      final w = (double ? 2 : 1) * _dispWidth(r['text'] as String);
      var pad = left;
      if (r['center'] == true) pad += ((blockW - w) ~/ 2).clamp(0, blockW);
      emit(r['text'] as String, pad, double: double, bold: r['bold'] == true);
    }

    out.add([0x0A, 0x0A]);
    out.add([0x0C]); // FF 换页出纸（针式手动送纸的收尾关键）
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
      {bool center = false, bool double = false, bool bold = false, bool big = false}) {
    out.add([0x1B, 0x61, center ? 1 : 0]); // ESC a n 对齐
    out.add([0x1D, 0x21, double ? 0x11 : (big ? 0x10 : 0x00)]); // GS ! n 倍大（fs=倍高）
    out.add([0x1B, 0x45, bold ? 1 : 0]); // ESC E n 加粗
    out.add(gbk.encode(s));
    if (double || bold || center) {
      out.add([0x1B, 0x61, 0]);
      out.add([0x1D, 0x21, 0x00]);
      out.add([0x1B, 0x45, 0]);
    }
  }
}
