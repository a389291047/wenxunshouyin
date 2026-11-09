import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 无码商品/无码菜品「常用」清单（v3.3.179）
///
/// - 本机配置（SharedPreferences，key: no_code_common），最多 5 条
///   （自动滚动：新记录置顶去重，超出裁掉最旧）
/// - 来源：自动记录——零售/生鲜支付成功、餐饮加菜成功的无码项；设置页仅可删除
/// - 无码弹窗名称输入框右侧「常用」按钮 → 弹窗展示最多 5 张渐变卡片，点击一键带入
class NoCodeCommon {
  static const _key = 'no_code_common';
  static const max = 5;

  static Future<List<Map>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final l = (jsonDecode(raw) as List).whereType<Map>().toList();
      return l.take(max).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<Map> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(list.take(max).toList()));
  }

  /// 记录一条：同名同价置顶去重；同名不同价视为不同项（都可保留）
  static Future<void> add(String name, double price) async {
    final name0 = name.trim();
    if (name0.isEmpty || price <= 0) return;
    final list = await load();
    list.removeWhere((e) =>
        '${e['name']}'.trim() == name0 &&
        (double.tryParse('${e['price']}') ?? 0) == price);
    // 无名（用了默认标题）的不记录：没有复用价值
    if (name0 == '无码商品' || name0 == '无码菜品') return;
    await save([
      {'name': name0, 'price': price},
      ...list,
    ]);
  }

  static Future<void> removeAt(int index) async {
    final list = await load();
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    await save(list);
  }

  /// 显示用价格文本：整数不带小数点，非整数保留原样（最多 2 位）
  static String priceText(num price) {
    final d = double.tryParse('$price') ?? 0;
    if (d % 1 == 0) return d.toInt().toString();
    return d.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  }
}
