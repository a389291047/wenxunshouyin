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
    scanMode.value = sp.getBool(prefScanMode) ?? false;
    await _loadGoodsSort(sp);
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

  // ===== 超市便利店视图（v3.3.282）：收银页隐藏商品列表/图片，扫码枪扫条码直接加购 =====
  static const prefScanMode = 'display_scan_mode';
  static final ValueNotifier<bool> scanMode = ValueNotifier(false);

  static Future<void> setScanMode(bool v) async {
    scanMode.value = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(prefScanMode, v);
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

  // ===== 商品排序（v3.3.266）：收银页商品区展示顺序，本机保存 =====
  // ''=默认(后台顺序=添加时间新→旧) sales=销量高→低 new=添加时间新→旧 old=旧→新
  // price_asc=价格低→高 price_desc=高→低 name=名称(拼音首字母 A→Z)
  static const prefGoodsSort = 'display_goods_sort';
  static final ValueNotifier<String> goodsSort = ValueNotifier('');

  /// 排序选项（key → 设置页显示）
  static const List<Map<String, String>> goodsSortItems = [
    {'key': '',          'label': '默认（后台排序）'},
    {'key': 'sales',     'label': '按销量 高→低'},
    {'key': 'new',       'label': '按添加时间 新→旧'},
    {'key': 'old',       'label': '按添加时间 旧→新'},
    {'key': 'price_asc', 'label': '按价格 低→高'},
    {'key': 'price_desc','label': '按价格 高→低'},
    {'key': 'name',      'label': '按名称 A→Z'},
  ];

  static Future<void> setGoodsSort(String v) async {
    goodsSort.value = goodsSortItems.any((it) => it['key'] == v) ? v : '';
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefGoodsSort, goodsSort.value);
  }

  static Future<void> _loadGoodsSort(SharedPreferences sp) async {
    goodsSort.value = sp.getString(prefGoodsSort) ?? '';
  }

  /// 商品列表排序（收银页展示用，不改原始数据）：
  /// 销量/价格缺字段的按 0 兜底；名称排序优先用简拼首字母（jianpin），无则按名称码元比较
  static List<Map> sortGoods(List goods, String mode) {
    double numv(Object? v) => double.tryParse('${v ?? ''}') ?? 0;
    int idOf(Map g) => numv(g['id']).toInt();
    String createTimeOf(Map g) => '${g['create_time'] ?? ''}';
    final list = List<Map>.from(goods);
    switch (mode) {
      case 'sales':
        list.sort((a, b) {
          final d = numv(b['sales'] ?? b['xiaoliang'] ?? 0).compareTo(numv(a['sales'] ?? a['xiaoliang'] ?? 0));
          return d != 0 ? d : idOf(b).compareTo(idOf(a));
        });
        return list;
      case 'new':
        list.sort((a, b) {
          final d = createTimeOf(b).compareTo(createTimeOf(a));
          return d != 0 ? d : idOf(b).compareTo(idOf(a));
        });
        return list;
      case 'old':
        list.sort((a, b) {
          final d = createTimeOf(a).compareTo(createTimeOf(b));
          return d != 0 ? d : idOf(a).compareTo(idOf(b));
        });
        return list;
      case 'price_asc':
      case 'price_desc':
        final desc = mode == 'price_desc';
        list.sort((a, b) {
          final pa = numv(a['amount'] ?? a['price'] ?? 0);
          final pb = numv(b['amount'] ?? b['price'] ?? 0);
          final d = desc ? pb.compareTo(pa) : pa.compareTo(pb);
          return d != 0 ? d : idOf(a).compareTo(idOf(b));
        });
        return list;
      case 'name':
        String key(Map g) {
          final jp = '${g['jianpin'] ?? ''}'.trim().toLowerCase();
          return jp.isNotEmpty ? jp : '${g['title'] ?? ''}';
        }
        list.sort((a, b) => key(a).compareTo(key(b)));
        return list;
      default:
        return list; // 默认：保持后台返回顺序，不重排
    }
  }

  static Future<void> resetAll() async {
    await setFontScale(1.0);
    await setFontWeight('normal');
    await setGoodsFont('');
    await setGoodsCols(0);
    await setGoodsImage(true);
    await setGoodsSort('');
    await setScanMode(false);
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
