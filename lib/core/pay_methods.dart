import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 支付方式排序（v3.3.163）：商户在「设置 → 支付方式排序」自定义顺序，
/// 结账弹窗按此顺序展示；新上线的支付方式自动追加到末尾。
class PayMethods {
  static const prefKey = 'pay_method_order';

  /// 全部支付方式（v3.3.176 餐饮+零售统一复用：扫码收款/会员支付=零售/生鲜/不开台/挂账核销用，
  /// 会员余额=餐饮结账用；商户排序全局生效，各场景只显示自己有的方式）
  static const all = ['微信支付', '支付宝', '现金', '扫码收款', '挂账', '会员余额', '会员支付'];

  /// 默认排序：微信 → 支付宝 → 现金 → 扫码收款 → 挂账 → 会员余额 → 会员支付
  static const defaultOrder = ['微信支付', '支付宝', '现金', '扫码收款', '挂账', '会员余额', '会员支付'];

  /// 读取商户自定义排序（含默认值兜底 + 未知方式追加）
  static Future<List<String>> load() async {
    final sp = await SharedPreferences.getInstance();
    try {
      final raw = sp.getString(prefKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).map((e) => '$e').toList();
        // 只保留有效方式 + 漏掉的追加到末尾（保持配置健壮）
        final valid = list.where(all.contains).toList();
        for (final m in all) {
          if (!valid.contains(m)) valid.add(m);
        }
        return valid;
      }
    } catch (_) {}
    return List<String>.from(defaultOrder);
  }

  /// 保存排序
  static Future<void> save(List<String> order) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefKey, jsonEncode(order));
  }

  /// 是否与默认一致
  static bool isDefault(List<String> order) =>
      order.length == defaultOrder.length &&
      List.generate(order.length, (i) => order[i] == defaultOrder[i]).every((e) => e);
}
