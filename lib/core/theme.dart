import 'package:flutter/material.dart';

/// 稳讯收银桌面版 · 全局主题
/// 深色侧边栏 + 浅色工作区，大号触控字号，商用收银风格
class PosTheme {
  static const accent = Color(0xFFFF5B2E);      // 主色（稳讯橙）
  static const accentDeep = Color(0xFFF4471B);
  static const sidebar = Color(0xFF1E2430);     // 侧边栏深色
  static const sidebarActive = Color(0xFFFF5B2E);
  static const bg = Color(0xFFF5F6F8);          // 工作区背景
  static const card = Colors.white;
  static const line = Color(0xFFEDEEF2);
  static const textMain = Color(0xFF1F2329);
  static const textSub = Color(0xFF646A73);
  static const textHint = Color(0xFFB8BCC3);
  static const green = Color(0xFF07C160);
  static const red = Color(0xFFF53F3F);
  static const blue = Color(0xFF2B7FFF);
  static const amber = Color(0xFFFF9F0A);

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: accent,
      brightness: Brightness.light,
      fontFamily: 'PingFang SC',
    );
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      textTheme: base.textTheme.apply(bodyColor: textMain, displayColor: textMain),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF7F8FA),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1.4),
        ),
      ),
    );
  }
}

/// 通用格式化
class Fmt {
  static String money(dynamic v) {
    final n = double.tryParse('$v') ?? 0;
    return n.toStringAsFixed(2);
  }

  static String date(dynamic v) {
    final s = '$v';
    return s.length >= 16 ? s.substring(0, 16) : s;
  }
}
