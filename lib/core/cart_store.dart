import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 购物车本地持久化（v3.3.255）：
/// 收银页在切到会员/订单等页面时会被销毁重建，内存购物车丢失。
/// 改为存 SharedPreferences（本机）：切页面、甚至重启应用都不丢，
/// 只有删除单行、清空购物车、收款完成才会消失。
/// 序列化格式与挂单（retail_holds）一致：[{goods, num, price, gift_qty}]
class CartStore {
  /// 读取持久化购物车行；数据损坏返回空列表，不影响收银
  static Future<List<Map<String, dynamic>>> load(String key) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存（fire-and-forget：不阻塞 UI，后写覆盖先写，最终状态正确）
  static void save(String key, List<Map<String, dynamic>> lines) {
    final payload = jsonEncode(lines);
    SharedPreferences.getInstance().then((sp) async {
      try {
        await sp.setString(key, payload);
      } catch (_) {} // 写盘失败静默，内存购物车仍是权威状态
    });
  }
}
