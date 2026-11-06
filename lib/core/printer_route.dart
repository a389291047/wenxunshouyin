import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 云打印机路由配置（v3.3.82）：商户在设置页自定义
/// 1. 前台单打印模式：整单打印（一桌一张票，全部商品条目）/ 分单打印（每道菜一张票）
/// 2. 前台打印机：指定发往前台的云打印机（空=自动选收银小票类型）
/// 3. 后厨分单：指定每台后厨云打印机负责哪些商品分类，点菜/加菜按分类路由出票
/// 配置按商户隔离（wenxun_id 前缀），存在本机 SharedPreferences。
class PrinterRoute {
  static const modeWhole = 'whole'; // 整单打印
  static const modeSplit = 'split'; // 分单打印

  static String _k(String wenxunId, String key) => 'pr_route_${wenxunId}_$key';

  // ==================== 前台单模式 ====================
  static Future<String> frontMode(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_k(wenxunId, 'front_mode')) ?? modeWhole;
  }

  static Future<void> setFrontMode(String wenxunId, String mode) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_k(wenxunId, 'front_mode'), mode);
  }

  // ==================== 前台打印机 ====================
  /// 返回指定前台打印机 machine_code；空串 = 自动（收银小票类型优先）
  static Future<String> frontPrinter(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_k(wenxunId, 'front_printer')) ?? '';
  }

  static Future<void> setFrontPrinter(String wenxunId, String machineCode) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_k(wenxunId, 'front_printer'), machineCode);
  }

  // ==================== 后厨分类路由 ====================
  /// {machine_code: [cat_id, ...]}：每台后厨打印机负责的商品分类
  static Future<Map<String, List<String>>> routes(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_k(wenxunId, 'routes'));
    if (raw == null || raw.isEmpty) return {};
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      return d.map((k, v) => MapEntry(k, (v as List).map((e) => '$e').toList()));
    } catch (_) {
      return {};
    }
  }

  static Future<void> setRoutes(String wenxunId, Map<String, List<String>> routes) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_k(wenxunId, 'routes'), jsonEncode(routes));
  }

  /// 某商品分类应发往哪些后厨打印机（按配置顺序；未配置返回空 = 走默认后厨打印机）
  static Future<List<String>> printersForCat(String wenxunId, String catId) async {
    final r = await routes(wenxunId);
    return r.entries.where((e) => e.value.contains(catId)).map((e) => e.key).toList();
  }

  // ==================== 后厨单模式（v3.3.123） ====================
  /// 后厨单打印模式：whole=整单打印（同一台打印机上的菜合并一张票）
  /// split=一菜一切（每个菜品条目单独一张票，出菜方便分拣）
  static Future<String> kitchenMode(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_k(wenxunId, 'kitchen_mode')) ?? modeWhole;
  }

  static Future<void> setKitchenMode(String wenxunId, String mode) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_k(wenxunId, 'kitchen_mode'), mode);
  }

  /// 米饭只打前台单：开启后米饭类商品不出后厨票（主食由前台单统一出，v3.3.123）
  static Future<bool> riceFrontOnly(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_k(wenxunId, 'rice_front_only')) ?? false;
  }

  static Future<void> setRiceFrontOnly(String wenxunId, bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_k(wenxunId, 'rice_front_only'), v);
  }

  /// 米饭类商品判断（名称含「米饭」即视为主食，如 米饭/米饭(小)/紫米饭）
  static bool isRiceItem(String goodsName) => goodsName.contains('米饭');
}
