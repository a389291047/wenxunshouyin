import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 无码商品/无码菜品「常用」清单（v3.3.181）
///
/// - 本机配置（SharedPreferences，key: no_code_common），最多 5 条，只记名称不记价格
///   （自动滚动：新记录置顶去重，超出裁掉最旧）
/// - 来源：自动记录——零售/生鲜支付成功、餐饮加菜成功的无码项名称；设置页仅可删除
/// - 无码弹窗名称输入框右侧「常用」按钮（有记录才显示）→ 弹窗选名称，一键带入名称，价格仍需手输
class NoCodeCommon {
  static const _key = 'no_code_common';
  static const max = 5;

  /// 加载常用名称列表（兼容旧版 {name, price} 结构，只取名称）
  static Future<List<String>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final out = <String>[];
      for (final e in (jsonDecode(raw) as List)) {
        final name = e is Map ? '${e['name'] ?? ''}'.trim() : '$e'.trim();
        if (name.isEmpty) continue;
        if (out.contains(name)) continue;
        out.add(name);
        if (out.length >= max) break;
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<String> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(list.take(max).toList()));
  }

  /// 记录一条名称：同名去重置顶；超出 5 条裁掉最旧的
  static Future<void> add(String name) async {
    final name0 = name.trim();
    if (name0.isEmpty) return;
    // 无名（用了默认标题）的不记录：没有复用价值
    if (name0 == '无码商品' || name0 == '无码菜品') return;
    final list = await load();
    list.removeWhere((e) => e == name0);
    await save([name0, ...list]);
  }

  static Future<void> removeAt(int index) async {
    final list = await load();
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    await save(list);
  }
}
