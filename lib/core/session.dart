import 'package:shared_preferences/shared_preferences.dart';

/// 登录会话（收银员 + 商户上下文）
/// token = wx_wenxun.api_token（商户长期令牌）
class Session {
  static String token = '';
  static int wenxunId = 0;
  static String shopName = '';
  static String shopPhone = '';
  static int staffId = 0;
  static String staffName = '';
  static int roleId = 0;
  static String roleName = '';
  static int hangye = 1; // 1零售 2餐饮 3生鲜
  static bool vipadd = false; // 添加会员权限

  static bool get isCashierOnly => roleId != 0;

  /// 订单数据可见范围（v3.3.214）：店长(role_id=1)与商户主账号(role_id=0)可看全部，
  /// 收银员/服务员等其他角色只能查看当天的订单
  static bool get canSeeAllOrders =>
      roleId == 0 || roleId == 1 || roleName.contains('店长');

  static Future<void> load() async {
    // 防御式读取：旧版 APP 缓存里同一 key 可能存的是字符串/布尔，
    // 直接 getInt/getBool 会抛类型转换异常导致启动黑屏，全部经字符串转换兜底
    try {
      final p = await SharedPreferences.getInstance();
      token = '${p.get('token') ?? ''}';
      wenxunId = int.tryParse('${p.get('wenxun_id') ?? ''}') ?? 0;
      shopName = '${p.get('shop_name') ?? ''}';
      shopPhone = '${p.get('shop_phone') ?? ''}';
      staffId = int.tryParse('${p.get('staff_id') ?? ''}') ?? 0;
      staffName = '${p.get('staff_name') ?? ''}';
      roleId = int.tryParse('${p.get('role_id') ?? ''}') ?? 0;
      roleName = '${p.get('role_name') ?? ''}';
      hangye = int.tryParse('${p.get('hangye') ?? ''}') ?? 1;
      final va = '${p.get('vipadd') ?? ''}'.toLowerCase();
      vipadd = va == 'true' || va == '1';
    } catch (_) {
      // 缓存损坏时按未登录处理，不影响启动
    }
  }

  static Future<void> save(Map<String, dynamic> data) async {
    token = (data['token'] ?? '').toString();
    wenxunId = int.tryParse('${data['id']}') ?? 0;
    shopName = (data['name'] ?? data['wenxun_name'] ?? '').toString();
    shopPhone = (data['phone'] ?? '').toString();
    staffId = int.tryParse('${data['staff_id']}') ?? 0;
    staffName = (data['staff_name'] ?? '').toString();
    roleId = int.tryParse('${data['role_id']}') ?? 0;
    roleName = (data['role_name'] ?? '').toString();
    hangye = int.tryParse('${data['hangye']}') ?? 1;
    vipadd = int.tryParse('${data['vipadd']}') == 1;

    final p = await SharedPreferences.getInstance();
    await p.setString('token', token);
    await p.setInt('wenxun_id', wenxunId);
    await p.setString('shop_name', shopName);
    await p.setString('shop_phone', shopPhone);
    await p.setInt('staff_id', staffId);
    await p.setString('staff_name', staffName);
    await p.setInt('role_id', roleId);
    await p.setString('role_name', roleName);
    await p.setInt('hangye', hangye);
    await p.setBool('vipadd', vipadd);
  }

  static Future<void> clear() async {
    token = '';
    wenxunId = 0;
    shopName = '';
    shopPhone = '';
    staffId = 0;
    staffName = '';
    roleId = 0;
    roleName = '';
    hangye = 1;
    vipadd = false;
    // 只删登录相关的键：绝不能 p.clear()——那会把本机配置（称重设备、
    // USB/蓝牙打印机、钱箱、主题、显示设置…）一起抹掉，收银员换班退出后
    // 又要重新设置一遍。见 v3.3.209 修复。
    final p = await SharedPreferences.getInstance();
    for (final k in const [
      'token', 'wenxun_id', 'shop_name', 'shop_phone',
      'staff_id', 'staff_name', 'role_id', 'role_name',
      'hangye', 'vipadd',
    ]) {
      await p.remove(k);
    }
  }

  /// 上班时间（当天首次登录，交班单用；取自登录时间兜底）
  static String get shiftStart {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}
