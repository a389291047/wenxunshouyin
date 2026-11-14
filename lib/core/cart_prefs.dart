import 'package:shared_preferences/shared_preferences.dart';

/// 购物车单行商品相关配置（v3.3.205）
///
/// - 改价是否需要权限密码（按设备保存，密码校验走云端员工权限密码，本机不存密码）
/// - 商品备注最近使用记录（最多 8 条，备注弹窗优先展示）
class CartPrefs {
  CartPrefs._();

  static const _pricePinKey = 'cart_price_need_pin';
  static const _recentNotesKey = 'cart_recent_notes';

  /// 改价是否需要权限密码（默认否，商户可在「设置 → 功能设置」开启）
  static Future<bool> priceNeedPin() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_pricePinKey) ?? false;
  }

  static Future<void> setPriceNeedPin(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_pricePinKey, v);
  }

  /// 最近用过的商品备注（新的在前）
  static Future<List<String>> recentNotes() async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_recentNotesKey) ?? const [];
    return list.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// 记一条备注（去重、最多 8 条；空串忽略）
  static Future<void> addRecentNote(String note) async {
    final n = note.trim();
    if (n.isEmpty) return;
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_recentNotesKey) ?? <String>[];
    list.remove(n);
    list.insert(0, n);
    if (list.length > 8) list.removeRange(8, list.length);
    await sp.setStringList(_recentNotesKey, list);
  }
}
