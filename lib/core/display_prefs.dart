import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 显示自定义设置（v3.3.193）：整体字体缩放 / 字体粗细 / 商品字体 / 商品每行个数
/// 本机持久化（SharedPreferences），通过 ValueNotifier 全局通知，
/// 设置页改完 main.dart 与收银页即时生效，无需重启。
class DisplayPrefs {
  DisplayPrefs._();

  static const prefScale = 'display_font_scale';    // double，整体字体缩放 0.8~1.4，默认 1.0
  static const prefWeight = 'display_font_weight';  // normal=正常 bold=加粗 light=细
  static const prefGoodsFont = 'display_goods_font'; // ''=标准 s=小 m=大 l=特大
  static const prefGoodsCols = 'display_goods_cols'; // int，0=自动（按屏宽自适应），3~8=固定每行个数
  static const prefGoodsImage = 'display_goods_image'; // bool，商品卡是否显示图片，默认 true

  /// 全局通知器
  static final ValueNotifier<double> fontScale = ValueNotifier(1.0);
  static final ValueNotifier<String> fontWeight = ValueNotifier('normal');
  static final ValueNotifier<String> goodsFont = ValueNotifier('');
  static final ValueNotifier<int> goodsCols = ValueNotifier(0);
  static final ValueNotifier<bool> goodsImage = ValueNotifier(true);

  /// App 启动时调用一次（main.dart）
  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    fontScale.value = (sp.getDouble(prefScale) ?? 1.0).clamp(0.8, 1.4).toDouble();
    fontWeight.value = sp.getString(prefWeight) ?? 'normal';
    goodsFont.value = sp.getString(prefGoodsFont) ?? '';
    goodsCols.value = sp.getInt(prefGoodsCols) ?? 0;
    goodsImage.value = sp.getBool(prefGoodsImage) ?? true;
    cartNewestFirst.value = sp.getBool(prefCartNewestFirst) ?? false;
  }

  static Future<void> setFontScale(double v) async {
    v = v.clamp(0.8, 1.4).toDouble();
    fontScale.value = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(prefScale, v);
  }

  /// 字体粗细：normal=正常 / bold=加粗 / light=细
  static Future<void> setFontWeight(String v) async {
    fontWeight.value = (v == 'bold' || v == 'light') ? v : 'normal';
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefWeight, fontWeight.value);
  }

  static Future<void> setGoodsFont(String v) async {
    goodsFont.value = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefGoodsFont, v);
  }

  static Future<void> setGoodsCols(int v) async {
    goodsCols.value = (v < 0 ? 0 : (v > 8 ? 8 : v));
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(prefGoodsCols, goodsCols.value);
  }

  /// 商品卡是否显示图片（false = 纯文字卡片，适合没上传图片或只按名称点单的商户）
  static Future<void> setGoodsImage(bool v) async {
    goodsImage.value = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(prefGoodsImage, v);
  }

  // ===== 购物车排序（v3.3.243）：false=顺序（先点的在前），true=倒序（最后点的在最上） =====
  static const prefCartNewestFirst = 'cart_newest_first';
  static final ValueNotifier<bool> cartNewestFirst = ValueNotifier(false);

  /// 购物车显示排序开关（仅影响列表显示顺序，落单/小票/挂单保持原顺序）
  static Future<void> setCartNewestFirst(bool v) async {
    cartNewestFirst.value = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(prefCartNewestFirst, v);
  }

  static Future<void> resetAll() async {
    await setFontScale(1.0);
    await setFontWeight('normal');
    await setGoodsFont('');
    await setGoodsCols(0);
    await setGoodsImage(true);
    await setCartNewestFirst(false);
  }

  /// 主题用的字重（正常返回 null = 不改主题）
  static FontWeight? get weightOf => switch (fontWeight.value) {
        'bold' => FontWeight.w700,
        'light' => FontWeight.w300,
        _ => null,
      };

  /// 商品卡片文字缩放系数：小 0.85 / 标准 1.0 / 大 1.2 / 特大 1.4
  static double get goodsFontFactor => switch (goodsFont.value) {
        's' => 0.85,
        'm' => 1.2,
        'l' => 1.4,
        _ => 1.0,
      };
}
