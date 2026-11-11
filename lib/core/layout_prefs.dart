import 'package:shared_preferences/shared_preferences.dart';

/// 收银页购物车面板显示位置（v3.3.189）
/// 默认右侧；小屏/个人习惯可切左侧。桌面零售收银页使用。
class CartSide {
  CartSide._();

  static const prefKey = 'cashier_cart_side';

  /// 返回 'left' 或 'right'（默认 right）
  static Future<String> side() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(prefKey) == 'left' ? 'left' : 'right';
  }

  static Future<void> setSide(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefKey, v == 'left' ? 'left' : 'right');
  }
}
