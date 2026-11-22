import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'session.dart';

/// 扫码充值「待补入账」管理（v3.3.256）：
/// 背景（546 商户 11-22 ¥200 孤儿充值）：付款码 codePay 星驿已扣款成功，
/// 但随后调 /shouyin/vip/chongzhi 入账时断网/异常 → 钱收了、会员余额没加，
/// 此前无任何兜底，商户实收 400 顾客只入账 200。
/// 机制：codePay 发起前把整笔充值（单号/会员/金额/赠送）写本地 SharedPreferences；
/// 入账成功即删除；失败则保留，由 retryAll 自动重试补入账。
/// 后端 chongzhi 已按星驿流水号幂等（同一流水重复提交只入账一次），重试安全。
class PendingRecharge {
  static const _key = 'pending_recharges';

  /// 一笔待补入账充值
  /// {order_no: 入账用的流水号（优先星驿渠道单号，其次 XYFC 业务单号）,
  ///  vip_id, vip_name, phone, amount(本金), gift(赠送), time, tries}
  static Future<List<Map<String, dynamic>>> list() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key) ?? '[]';
      final arr = jsonDecode(raw);
      if (arr is List) {
        return arr.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<void> _write(List<Map<String, dynamic>> arr) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(arr));
  }

  /// 落一笔待补入账（codePay 发起前调用；同单号覆盖旧记录）
  static Future<void> save({
    required String orderNo,
    required int vipId,
    String vipName = '',
    String phone = '',
    required double amount,
    double gift = 0,
  }) async {
    if (orderNo.isEmpty || vipId <= 0 || Session.wenxunId <= 0) return;
    final arr = await list();
    arr.removeWhere((e) => '${e['order_no']}' == orderNo);
    arr.add({
      'order_no': orderNo,
      'vip_id': vipId,
      'vip_name': vipName,
      'phone': phone,
      'amount': amount,
      'gift': gift,
      'wenxun_id': Session.wenxunId,
      'time': DateTime.now().toIso8601String(),
      'tries': 0,
    });
    await _write(arr);
  }

  static Future<void> remove(String orderNo) async {
    final arr = await list();
    arr.removeWhere((e) => '${e['order_no']}' == orderNo);
    await _write(arr);
  }

  /// 是否存在待补入账（会员页可用来显示角标提示）
  static Future<bool> has() async => (await list()).isNotEmpty;

  /// 自动补入账：逐笔重试 chongzhi（后端幂等，重复提交不会双入账）。
  /// 返回成功补入账的笔数；[onProgress] 每补成一笔回调一次（用于 toast 提示）。
  /// 渠道明确未扣款（支付失败/超时关单）的记录自动清理，不误入账。
  static Future<int> retryAll({void Function(String msg)? onProgress}) async {
    if (Session.wenxunId <= 0) return 0;
    final arr = await list();
    if (arr.isEmpty) return 0;
    var okCount = 0;
    for (final rec in List<Map<String, dynamic>>.from(arr)) {
      // 商户隔离：同机多商户，只补当前登录商户的记录，其余留着
      final recWid = int.tryParse('${rec['wenxun_id'] ?? 0}') ?? 0;
      if (recWid > 0 && recWid != Session.wenxunId) continue;
      final orderNo = '${rec['order_no'] ?? ''}';
      if (orderNo.isEmpty) {
        await _write(arr..remove(rec));
        continue;
      }
      // 最多重试 8 次，防止坏记录永远卡在列表里
      final tries = int.tryParse('${rec['tries'] ?? 0}') ?? 0;
      try {
        final r = await Api.vipRechargeSubmit(
          vipId: int.tryParse('${rec['vip_id'] ?? 0}') ?? 0,
          wenxunId: Session.wenxunId,
          amount: double.tryParse('${rec['amount'] ?? 0}') ?? 0,
          gift: double.tryParse('${rec['gift'] ?? 0}') ?? 0,
          method: '付款码',
          orderNo: orderNo,
        );
        final code = '${r['code']}';
        if (code == '200') {
          // 入账成功（含后端幂等「已入账」情形）→ 清记录
          await remove(orderNo);
          arr.removeWhere((e) => '${e['order_no']}' == orderNo);
          okCount++;
          final amt = double.tryParse('${rec['amount'] ?? 0}') ?? 0;
          final name = '${rec['vip_name'] ?? rec['phone'] ?? '会员'}';
          onProgress?.call('检测到一笔未完成的扫码充值，已自动补入账：$name ¥${amt.toStringAsFixed(2)}');
          continue;
        }
        final msg = '${r['msg'] ?? ''}';
        if (code == '400' && msg.contains('未查询到已支付')) {
          // 星驿还没成功：查渠道终态。已关闭/失败（钱没扣）→ 安全清记录；
          // 仍在处理中 → 保留下次再试
          final dropped = await _dropIfChannelDead(orderNo);
          if (dropped) {
            arr.removeWhere((e) => '${e['order_no']}' == orderNo);
          } else {
            rec['tries'] = tries + 1;
          }
          continue;
        }
        // 其他业务错误（如会员被删）：保留，下次再试；超过 8 次放弃
        rec['tries'] = tries + 1;
        if (tries + 1 >= 8) {
          arr.removeWhere((e) => '${e['order_no']}' == orderNo);
          onProgress?.call('一笔充值补入账多次失败（${msg.isEmpty ? r['code'] : msg}），请到充值记录里人工核对');
        }
      } on ApiError {
        // 网络/服务异常：保留，等下次重试
        rec['tries'] = tries + 1;
      } catch (_) {
        rec['tries'] = tries + 1;
      }
    }
    await _write(arr);
    return okCount;
  }

  /// 渠道终态核对：支付失败(4)/超时关单(5) → 钱没扣，安全清记录；返回是否已清
  static Future<bool> _dropIfChannelDead(String orderNo) async {
    try {
      final q = await Api.xyfQueryOrder(orderNo);
      if ('${q['code']}' == '0' && q['data'] is Map) {
        final st = int.tryParse('${(q['data'] as Map)['status']}') ?? 0;
        if (st == 4 || st == 5) {
          await remove(orderNo);
          return true;
        }
      }
    } catch (_) {}
    return false;
  }
}
