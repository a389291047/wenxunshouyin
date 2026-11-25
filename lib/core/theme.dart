import 'package:flutter/material.dart';

import 'theme_prefs.dart';

/// 稳讯收银桌面版 · 全局主题
/// 深色侧边栏 + 浅色工作区，大号触控字号，商用收银风格
class PosTheme {
  /// ===== 主体风格（配色方案，v3.3.194 / v3.3.195 选了才生效）=====
  /// 商户没选配色方案时（[hasSkin] == false），下面这些动态取值全部回落到
  /// v3.3.194 之前的旧版外观（品牌橙 + 纯色侧边栏 + 纯色主按钮 + #FFF2ED 浅底），
  /// 保证升级后老商户看到的界面与原来完全一致。
  static bool get hasSkin => ThemePrefs.hasSkin;
  static PosSkin get skin => ThemePrefs.active;
  static Color get accentLive => hasSkin ? ThemePrefs.active.accent : accent;
  static Color get deepLive => hasSkin ? ThemePrefs.active.accentDeep : accentDeep;
  static Color get sidebarLive => hasSkin ? ThemePrefs.active.sidebar : sidebar;

  // 旧版浅底（写死过 0xFFFFF2ED / 0xFFFFF7F4，换色后由主色算）
  static const _legacyTint = Color(0xFFFFF2ED);
  static const _legacyTintSoft = Color(0xFFFFF7F4);
  static const _legacyTintStrong = Color(0xFFFFE6DC);

  static Color get tint => hasSkin ? ThemePrefs.active.tint : _legacyTint;
  static Color get tintSoft => hasSkin ? ThemePrefs.active.tintSoft : _legacyTintSoft;
  static Color get tintStrong => hasSkin ? ThemePrefs.active.tintStrong : _legacyTintStrong;

  /// 品牌渐变色（登录页品牌区、Logo）
  /// 未选择配色时用旧版登录页的橙红四段渐变。
  static List<Color> get brandColors => hasSkin
      ? ThemePrefs.active.gradient
      : const [Color(0xFFFF9A56), Color(0xFFFF6A2C), Color(0xFFF4471B), Color(0xFFD93212)];

  static LinearGradient get brandGradient => hasSkin
      ? ThemePrefs.active.linear
      : const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF9A56), Color(0xFFFF6A2C), Color(0xFFF4471B), Color(0xFFD93212)],
        );

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

  /// [weight]：全局字重（设置 → 显示设置 → 字体粗细）。
  /// null = 正常（沿用默认主题）；w700=加粗；w300=细。
  /// 只覆盖主题里的正文/标题字重，组件内显式写死 fontWeight 的强调文字保持原样。
  ///
  /// [skin]：主体风格（设置 → 主题风格）。不传则用当前商户选中的方案。
  static ThemeData light({FontWeight? weight, PosSkin? skin}) {
    final sk = skin ?? ThemePrefs.active;
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: sk.accent).copyWith(primary: sk.accent),
      brightness: Brightness.light,
      fontFamily: 'PingFang SC',
    );
    var tt = base.textTheme.apply(bodyColor: textMain, displayColor: textMain);
    if (weight != null) {
      tt = TextTheme(
        displayLarge: tt.displayLarge?.copyWith(fontWeight: weight),
        displayMedium: tt.displayMedium?.copyWith(fontWeight: weight),
        displaySmall: tt.displaySmall?.copyWith(fontWeight: weight),
        headlineLarge: tt.headlineLarge?.copyWith(fontWeight: weight),
        headlineMedium: tt.headlineMedium?.copyWith(fontWeight: weight),
        headlineSmall: tt.headlineSmall?.copyWith(fontWeight: weight),
        titleLarge: tt.titleLarge?.copyWith(fontWeight: weight),
        titleMedium: tt.titleMedium?.copyWith(fontWeight: weight),
        titleSmall: tt.titleSmall?.copyWith(fontWeight: weight),
        bodyLarge: tt.bodyLarge?.copyWith(fontWeight: weight),
        bodyMedium: tt.bodyMedium?.copyWith(fontWeight: weight),
        bodySmall: tt.bodySmall?.copyWith(fontWeight: weight),
        labelLarge: tt.labelLarge?.copyWith(fontWeight: weight),
        labelMedium: tt.labelMedium?.copyWith(fontWeight: weight),
        labelSmall: tt.labelSmall?.copyWith(fontWeight: weight),
      );
    }
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      textTheme: tt,
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
          borderSide: BorderSide(color: sk.accent, width: 1.4),
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

  /// 商品单位清洗：空 / 'null' / 'undefined'（历史脏数据）→ 默认单位（缺省 kg）
  static String unit(dynamic v, [String def = 'kg']) {
    final u = '$v'.trim();
    if (u.isEmpty || u == 'null' || u == 'undefined') return def;
    return u;
  }
}
