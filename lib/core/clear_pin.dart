import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'session.dart';

/// 清空购物车二次确认（v3.3.192）
///
/// 场景：收银界面「清空」按钮误点会把整单商品清掉，开启后需输入权限密码。
///
/// 密码不落本机：直接校验云端 `wx_renyuan.quanxian_password`
/// （与「订单退款 / 现金充值」同一套密码，由商户在「设置 → 权限密码」为每位收银员分配 6 位数字），
/// 换电脑 / 换账号判定一致，收银员本人无法自行修改。
class ClearPin {
  ClearPin._();

  static const _enabledKey = 'clear_cart_need_pin';

  /// 开关（按设备保存：某台收银机是否需要二次确认）
  static Future<bool> enabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_enabledKey) ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_enabledKey, v);
  }

  /// 云端校验权限密码：ok=true 通过；ok=false 时 msg 为服务端返回的原因
  /// （未设置密码 / 密码错误 / 员工信息缺失等，文案与退款接口保持一致）
  static Future<ClearPinResult> verify(String input) async {
    final pwd = input.trim();
    if (pwd.isEmpty) return const ClearPinResult(false, '请输入权限密码');
    if (Session.staffId <= 0) {
      return const ClearPinResult(
          false, '当前账号未关联收银员，请用收银员账号登录后再试');
    }
    try {
      final r = await Api.checkQuanxian(staffId: Session.staffId, password: pwd);
      if ('${r['code']}' == '200') return const ClearPinResult(true, '');
      final msg = '${r['msg'] ?? ''}'.trim();
      return ClearPinResult(false, msg.isEmpty ? '权限密码错误' : msg);
    } on ApiError catch (e) {
      return ClearPinResult(false, e.message);
    } catch (_) {
      return const ClearPinResult(false, '网络异常，请检查网络后重试');
    }
  }
}

/// 校验结果（ok + 失败原因）
class ClearPinResult {
  final bool ok;
  final String msg;
  const ClearPinResult(this.ok, this.msg);
}
