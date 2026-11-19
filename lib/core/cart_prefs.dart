import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 赠送计价模式（v3.3.235，商户在「设置 → 功能设置」自选）
///
/// - `deduct`（默认）：购物车数量 = 顾客拿走的总量，收钱自动扣掉赠送
///   （买2送1：数量录 3、赠送填 1 → 收 2 件的钱；称重 0.75kg 送 0.25 → 收 0.5kg 的钱）
/// - `keep`：购物车数量 = 付钱部分，赠送的额外拿走
///   （买2送1：数量录 2、赠送填 1 → 顾客共拿 3 件，收 2 件的钱）
class GiftMode {
  GiftMode._();

  static const _key = 'cart_gift_mode';
  static const deductMode = 'deduct';
  static const keepMode = 'keep';

  /// 当前模式（ValueNotifier：设置页改完收银页即时生效）
  static final value = ValueNotifier<String>(deductMode);

  static bool get isDeduct => value.value == deductMode;

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    value.value = sp.getString(_key) == keepMode ? keepMode : deductMode;
  }

  static Future<void> set(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, v);
    value.value = v;
  }
}

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
