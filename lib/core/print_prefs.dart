import 'package:shared_preferences/shared_preferences.dart';

/// 小票打印开关（v3.3.77）：云打印 / USB 直连共用一套开关。
/// 关闭后对应类型小票不再自动/手动打印；手动打印被拦截时界面会提示。
class PrintPrefs {
  /// 可配置的小票类型（key → 设置页显示）
  /// scope: dining=餐饮专属 / retail=零售专属 / all=通用（餐饮零售都显示）
  static const List<Map<String, String>> items = [
    {'key': 'retail',  'label': '零售收银小票',  'desc': '收银台收款成功后自动打印', 'scope': 'retail'},
    {'key': 'dining',  'label': '堂食结账单',    'desc': '桌台结账 / 直连点餐 / 挂账结清小票', 'scope': 'dining'},
    {'key': 'kitchen', 'label': '后厨单 / 加菜单', 'desc': '点菜与加菜自动传后厨（按「打印机分配」路由）', 'scope': 'dining'},
    {'key': 'front',   'label': '前台单',        'desc': '点单完成后自动发往前台（整单/分单在「打印机分配」设置）', 'scope': 'dining'},
    {'key': 'prebill', 'label': '预结单',        'desc': '账单「预结单」按钮，先出单后正式结算', 'scope': 'dining'},
    {'key': 'reorder', 'label': '订单补打小票',   'desc': '订单页「补打小票」按钮；USB直连优先，云打印默认前台收银小票机', 'scope': 'dining'},
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

  /// 餐饮小票合并组（v3.3.137）：同类小票合并成一行设置，避免列表过长。
  /// members 逗号分隔；组开关开=全部成员开、关=全部成员关（出票逻辑仍按单个 key 判断，零改动）。
  /// preview = 组行「预览」展示的代表样票 key；members 含 'kitchen' 的组显示「设置」按钮（明细行开关弹窗）。
  static const List<Map<String, String>> diningGroups = [
    {'label': '结账 / 补打小票', 'desc': '桌台结账、直连点餐、挂账结清、订单页补打（同是收银结账类小票）',
     'members': 'dining,reorder', 'preview': 'dining'},
    {'label': '前台单 / 预结单', 'desc': '点单完成发往前台；账单「预结单」先出单后结算（同发前台机）',
     'members': 'front,prebill', 'preview': 'front'},
    {'label': '后厨单（含加菜/退菜/催菜/重打）', 'desc': '点菜加菜、退菜催菜、传后厨重打，均按「打印机分配」路由',
     'members': 'kitchen,retreat,urge,reprint', 'preview': 'kitchen'},
    {'label': '排队号票', 'desc': '排队取号小票',
     'members': 'queue', 'preview': 'queue'},
  ];

  /// 合并组开关状态：全部成员开才显示开
  static Future<bool> groupOn(String members) async {
    final sp = await SharedPreferences.getInstance();
    for (final k in members.split(',')) {
      if (!(sp.getBool('$_prefix$k') ?? true)) return false;
    }
    return true;
  }

  /// 写合并组开关：整组统一开/关
  static Future<void> setGroup(String members, bool value) async {
    final sp = await SharedPreferences.getInstance();
    for (final k in members.split(',')) {
      await sp.setBool('$_prefix$k', value);
    }
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
