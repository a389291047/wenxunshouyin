import 'package:shared_preferences/shared_preferences.dart';

/// 小票打印开关（v3.3.77）：云打印 / USB 直连共用一套开关。
/// 关闭后对应类型小票不再自动/手动打印；手动打印被拦截时界面会提示。
class PrintPrefs {
  /// 可配置的小票类型（key → 设置页显示）
  /// scope: dining=餐饮专属 / retail=零售专属 / all=通用（餐饮零售都显示）
  static const List<Map<String, String>> items = [
    {'key': 'retail',  'label': '零售收银小票',  'desc': '收银台收款成功后自动打印', 'scope': 'retail'},
    {'key': 'dining',  'label': '堂食结账单',    'desc': '桌台结账 / 直连点餐 / 挂账结清小票', 'scope': 'dining'},
    {'key': 'kitchen', 'label': '后厨单 / 加菜单', 'desc': '点菜与加菜自动传后厨', 'scope': 'dining'},
    {'key': 'retreat', 'label': '退菜单',        'desc': '退菜时自动通知后厨', 'scope': 'dining'},
    {'key': 'urge',    'label': '催菜单',        'desc': '催菜时自动通知后厨', 'scope': 'dining'},
    {'key': 'reprint', 'label': '传后厨重打单',   'desc': '账单「传后厨」按钮重打', 'scope': 'dining'},
    {'key': 'queue',   'label': '排队号票',      'desc': '排队取号小票', 'scope': 'dining'},
    {'key': 'shift',   'label': '交班单',        'desc': '交接班统计小票', 'scope': 'all'},
    {'key': 'order',   'label': '订单重打小票',   'desc': '订单管理页手动重打', 'scope': 'retail'},
    {'key': 'refund',  'label': '退款单',        'desc': '订单退款小票', 'scope': 'retail'},
  ];

  /// 按当前行业过滤可显示的小票类型（餐饮跟零售分开）：
  /// 餐饮版(hangye==2) → 餐饮专属 + 通用；零售/生鲜版 → 零售专属 + 通用
  static List<Map<String, String>> itemsForHangye(int? hangye) {
    final isDining = hangye == 2;
    return items.where((it) {
      final scope = it['scope'] ?? 'all';
      if (scope == 'all') return true;
      return isDining ? scope == 'dining' : scope == 'retail';
    }).toList();
  }

  static const _prefix = 'print_on_';

  /// 某类型是否打印（默认全开）
  static Future<bool> on(String key) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool('$_prefix$key') ?? true;
  }

  static Future<void> set(String key, bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('$_prefix$key', value);
  }
}
