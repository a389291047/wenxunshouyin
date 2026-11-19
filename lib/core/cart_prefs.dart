import 'package:shared_preferences/shared_preferences.dart';

/// 购物车单行商品相关配置（v3.3.205）
///
/// - 改价是否需要权限密码（按设备保存，密码校验走云端员工权限密码，本机不存密码）
/// - v3.3.231：商品行备注（常用语/最近使用）整体移除，改为「赠送数量」，本类只剩改价密码开关
class CartPrefs {
  CartPrefs._();

  static const _pricePinKey = 'cart_price_need_pin';

  /// 改价是否需要权限密码（默认否，商户可在「设置 → 功能设置」开启）
  static Future<bool> priceNeedPin() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_pricePinKey) ?? false;
  }

  static Future<void> setPriceNeedPin(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_pricePinKey, v);
  }
}
