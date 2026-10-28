import 'dart:convert';
import 'package:http/http.dart' as http;
import 'session.dart';

/// 稳讯后端 API 客户端
/// 全部 POST + form-urlencoded；管理接口带 header token（= 商户 api_token）
class Api {
  static const base = 'https://shop.wx-zf.com';

  /// 统一 POST，返回解码后的 JSON Map（失败抛 ApiError）
  static Future<Map<String, dynamic>> post(String path, Map<String, dynamic> data,
      {bool withToken = true}) async {
    try {
      final body = <String, String>{};
      data.forEach((k, v) {
        if (v == null) return;
        body[k] = v is String ? v : jsonEncode(v);
      });
      // list/对象参数直接 jsonEncode
      final headers = {'Content-Type': 'application/x-www-form-urlencoded'};
      if (withToken && Session.token.isNotEmpty) headers['token'] = Session.token;
      final res = await http
          .post(Uri.parse(base + path), headers: headers, body: body)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        // 尽量把服务端的 msg 带出来，而不是笼统的“服务器异常”
        String msg = '服务器异常（${res.statusCode}）';
        try {
          final j = jsonDecode(utf8.decode(res.bodyBytes));
          if (j is Map && '${j['msg'] ?? ''}'.isNotEmpty) msg = '${j['msg']}';
        } catch (_) {}
        throw ApiError(msg);
      }
      final s = utf8.decode(res.bodyBytes);
      final json = jsonDecode(s);
      if (json is Map<String, dynamic>) return json;
      // 服务端偶发返回裸字符串
      return {'code': 200, 'msg': s.replaceAll('"', '').trim()};
    } on ApiError {
      rethrow;
    } catch (e) {
      throw ApiError('网络异常，请检查网络连接');
    }
  }

  // ==================== 登录 ====================

  /// 收银员账号登录（手机号 + 明文密码）
  /// code=200 成功；code=300 多店铺需选择（返回 shops）
  static Future<Map<String, dynamic>> login(
      String phone, String password, int? wenxunId) async {
    return post('/api/shouyinyuan/login', {
      'phone': phone,
      'password': password,
      if (wenxunId != null) 'wenxun_id': wenxunId,
    }, withToken: false);
  }

  // ==================== 商品 ====================

  /// 分类 + 商品一次拉全（零售点单页用）
  static Future<Map<String, dynamic>> goodsAll(int wenxunId) async {
    final r = await post('/shouyin/goodscat/index', {'wenxun_id': wenxunId});
    return {'cat': r['cat'] ?? [], 'goods': r['goods'] ?? []};
  }

  /// 商户分类列表
  static Future<List> goodsCats(int wenxunId) async {
    final r = await post('/shouyin/goods/cate', {'wenxun_id': wenxunId});
    return (r['data'] ?? []) as List;
  }

  /// 餐饮分类商品
  static Future<List> goodsByCat(int wenxunId, int catId) async {
    final r = await post('/shouyin/goods/canyin', {
      'wenxun_id': wenxunId,
      'cat_id': catId,
    });
    return (r['goods'] ?? []) as List;
  }

  // ==================== 零售订单 ====================

  /// 创建店内零售单（POS）
  static Future<Map<String, dynamic>> retailOrderAdd({
    required int wenxunId,
    required int renyuanId,
    required double total,
    required String paymentMethod,
    required List<Map<String, dynamic>> cart,
    int vipId = 0,
  }) async {
    return post('/shouyin/order/add', {
      'id': wenxunId,
      'renyuan_id': renyuanId,
      'total': total,
      'paymentMethod': paymentMethod,
      'cart': cart,
      if (vipId > 0) 'vip_id': vipId,
    });
  }

  /// 会员余额支付（零售收银台）：后端先扣会员余额（联拓富会员走联拓富真实扣款）
  /// 再落订单，扣款失败不落单。POST /api/order/huiyuanzhifu
  static Future<Map<String, dynamic>> memberPay({
    required int wenxunId,
    required int vipId,
    required String phone,
    required double total,
    required double originalTotal,
    required List<Map<String, dynamic>> cart,
    int totalCount = 0,
    double vipDiscount = 1.0,
  }) async {
    return post('/api/order/huiyuanzhifu', {
      'id': wenxunId,
      'vip_id': vipId,
      'phone': phone,
      'realTotal': total,
      'total': originalTotal,
      'totalCount': totalCount,
      'vipDiscount': vipDiscount,
      'paymentMethod': '会员支付',
      'cart': cart,
    });
  }

  /// 收银端订单列表（店内+小程序混合，按 order_from 前端区分）
  static Future<List> ordersAll(int wenxunId) async {
    final r = await post('/shouyin/order/dingdanshouyinyuan', {
      'wenxun_id': wenxunId,
    });
    return (r['dingdan'] ?? []) as List;
  }

  // ==================== 会员 ====================

  static Future<List> vipList(int wenxunId) async {
    final r = await post('/shouyin/vip/mac', {'wenxun_id': wenxunId});
    return (r['data'] ?? []) as List;
  }

  static Future<List> vipSearch(int wenxunId, String kw) async {
    final r = await post('/shouyin/vip/vipp', {'vip_id': wenxunId, 'phone': kw});
    return (r['huiyuan'] ?? []) as List;
  }

  /// 会员等级列表（与小程序添加会员页同源 v1.Vip/getLevelAndCount）
  static Future<List> vipLevels(int wenxunId) async {
    final r = await post('/api/v1.Vip/getLevelAndCount', {'wenxun_id': wenxunId});
    if ('${r['code']}' == '200' && r['list'] is List) return r['list'] as List;
    throw ApiError('${r['msg'] ?? '获取会员等级失败'}');
  }

  /// 添加会员（与微信小程序 pages/vip/add 一致，走 v1.Vip/chushi2）
  /// 服务端校验：phone 必填、xm（姓名）必填、lv_id 必填
  static Future<Map<String, dynamic>> vipAdd({
    required int wenxunId,
    required String phone,
    required String name,
    required int lvId,
    required String levelName,
    String amount = '0',
    String score = '0',
    String shika = '',
    String chepai = '',
  }) async {
    return post('/api/v1.Vip/chushi2', {
      'wenxun_id': wenxunId,
      'vip_id': wenxunId,
      'staff_id': Session.staffId,
      'xm': name,
      'phone': phone,
      'amount': amount,
      'score': score,
      'chepai': chepai,
      'shika': shika,
      'lv_id': lvId,
      'level_name': levelName,
    });
  }

  /// 充值档次列表（与小程序充值页同源 viphuodong/lst）
  static Future<List> vipRechargeTiers(int wenxunId) async {
    final r = await post('/api/viphuodong/lst', {'wenxun_id': wenxunId}, withToken: false);
    return (r['huodong'] ?? []) as List;
  }

  /// 会员充值 · 扫顾客付款码支付（与小程序充值页同源 payment/codePay，type=A 充值）
  /// amount 单位元（两位小数字符串），code 为 18-30 位付款码
  static Future<Map<String, dynamic>> rechargeCodePay({
    required int wenxunId,
    required double amount,
    required String code,
  }) async {
    final amt = amount.toStringAsFixed(2);
    final txamt = (amount * 100).round().toString();
    return post('/api/payment/codePay', {
      'denglu': wenxunId,
      'amount': amt,
      'txamt': txamt,
      'code': code,
      'type': 'A',
    }, withToken: false);
  }

  static Future<List> vipOrders(int vipId) async {
    final r = await post('/shouyin/vip/dingdanshouyinyuan', {'vip_id': vipId});
    return (r['dingdan'] ?? []) as List;
  }

  // ==================== 订单配送（美团/京东秒送/淘宝闪购） ====================

  /// 平台配置列表
  static Future<List> deliveryConfigs(int wenxunId) async {
    final r = await post('/api/delivery/configList', {'wenxun_id': wenxunId});
    if ('${r['code']}' == '200') return (r['data']['platforms'] ?? []) as List;
    throw ApiError('${r['msg'] ?? '获取平台配置失败'}');
  }

  /// 保存平台配置
  static Future<void> deliveryConfigSave({
    required int wenxunId,
    required String platform,
    required String appId,
    required String appSecret,
    String sourceId = '',
    String env = 'prod',
    required String storeId,
    required String accessToken,
    required bool enabled,
  }) async {
    final r = await post('/api/delivery/configSave', {
      'wenxun_id': wenxunId,
      'platform': platform,
      'app_id': appId,
      'app_secret': appSecret,
      'source_id': sourceId,
      'env': env,
      'store_id': storeId,
      'access_token': accessToken,
      'enabled': enabled ? 1 : 0,
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '保存失败'}');
  }

  /// 订单池列表（platform 空=全部平台，status 空=全部状态）
  static Future<List> deliveryOrders(int wenxunId, {String platform = ''}) async {
    final r = await post('/api/delivery/orders', {'wenxun_id': wenxunId, 'platform': platform});
    if ('${r['code']}' == '200') return (r['data']['list'] ?? []) as List;
    throw ApiError('${r['msg'] ?? '获取订单失败'}');
  }

  /// 从平台拉单
  static Future<Map<String, dynamic>> deliveryPull(int wenxunId, String platform) async {
    final r = await post('/api/delivery/pull', {'wenxun_id': wenxunId, 'platform': platform});
    if ('${r['code']}' == '200') return r;
    throw ApiError('${r['msg'] ?? '拉单失败'}');
  }

  /// 平台配置诊断：返回请求地址 / HTTP 状态 / 平台响应原文
  static Future<Map<String, dynamic>> deliveryProbe(int wenxunId, String platform) async {
    final r = await post('/api/delivery/probe', {'wenxun_id': wenxunId, 'platform': platform});
    if ('${r['code']}' == '200') return (r['data'] ?? {}) as Map<String, dynamic>;
    throw ApiError('${r['msg'] ?? '诊断失败'}');
  }

  /// 配送操作 action=accept|delivering|delivered|cancel
  static Future<Map<String, dynamic>> deliveryOp(int wenxunId, int orderId, String action) async {
    final r = await post('/api/delivery/ops', {'wenxun_id': wenxunId, 'order_id': orderId, 'action': action});
    if ('${r['code']}' == '200') return r;
    throw ApiError('${r['msg'] ?? '操作失败'}');
  }

  // ==================== 交班 / 打印 ====================

  static Future<Map<String, dynamic>> shiftStats(int renyuanId) async {
    return post('/shouyin/jiaoban/jintian', {'renyuan_id': renyuanId});
  }

  static Future<List> printers(int wenxunId) async {
    final r = await post('/shouyin/jiaoban/huoqudayinji', {'wenxun_id': wenxunId});
    return (r['yilianyun'] ?? []) as List;
  }

  /// 云打印（易联云）：content 为小票文本，\n 分行
  static Future<Map<String, dynamic>> cloudPrint({
    required int wenxunId,
    required String machineCode,
    required String content,
  }) async {
    return post('/shouyin/jiaoban/dayin', {
      'wenxun_id': wenxunId,
      'machine_code': machineCode,
      'content': content,
    });
  }

  // ==================== 餐饮桌台 ====================

  static Future<List> tables(int wenxunId) async {
    final r = await post('/api/zhuotai/lst', {'id': wenxunId});
    return (r['wancheng'] ?? []) as List;
  }

  static Future<Map<String, dynamic>> tableOpen({
    required int wenxunId,
    required int tableId,
    required int peopleNum,
    required int operatorId,
    required String operatorName,
  }) async {
    return post('/api/zhuotai/kaitai', {
      'wenxun_id': wenxunId,
      'table_id': tableId,
      'people_num': peopleNum,
      'operator_id': operatorId,
      'operator_name': operatorName,
    });
  }

  static Future<Map<String, dynamic>> tableCancelOpen({
    required int wenxunId,
    required int tableId,
    required String kaitaiId,
  }) async {
    return post('/api/zhuotai/cancel_kaitai', {
      'wenxun_id': wenxunId,
      'table_id': tableId,
      'kaitai_id': kaitaiId,
    });
  }

  static Future<Map<String, dynamic>> tableChange({
    required int wenxunId,
    required int sourceTableId,
    required int targetTableId,
  }) async {
    return post('/api/zhuotai/changeTable', {
      'wenxun_id': wenxunId,
      'source_table_id': sourceTableId,
      'target_table_id': targetTableId,
    });
  }

  /// 预约桌台（仅空闲桌可预约，桌台状态 0→1）
  static Future<Map<String, dynamic>> tableBook({
    required int wenxunId,
    required int tableId,
    required int operatorId,
    required String operatorName,
  }) async {
    return post('/api/zhuotai/bookTable', {
      'wenxun_id': wenxunId,
      'table_id': tableId,
      'operator_id': operatorId,
      'operator_name': operatorName,
    });
  }

  /// 取消预约（仅已预定桌可取消，桌台状态 1→0）
  static Future<Map<String, dynamic>> tableCancelBook({
    required int wenxunId,
    required int tableId,
    required int operatorId,
    required String operatorName,
  }) async {
    return post('/api/zhuotai/cancelBookTable', {
      'wenxun_id': wenxunId,
      'table_id': tableId,
      'operator_id': operatorId,
      'operator_name': operatorName,
    });
  }

  /// 已点菜品（临时未结算明细）
  static Future<Map<String, dynamic>> tableBill({
    required int wenxunId,
    required String kaitaiId,
  }) async {
    return post('/api/tableorder/getTableOrder', {
      'wenxun_id': wenxunId,
      'kaitai_id': kaitaiId,
    });
  }

  /// 中途加菜
  static Future<Map<String, dynamic>> tableAddDish({
    required int wenxunId,
    required String kaitaiId,
    required List<Map<String, dynamic>> cart,
  }) async {
    return post('/api/tableorder/addxc', {
      'wenxun_id': wenxunId,
      'kaitai_id': kaitaiId,
      'cart': cart,
    });
  }

  // ==================== 收银员预点餐 ====================

  /// 保存预点单（全量替换；cart 空数组 = 仅预约不出菜）
  static Future<Map<String, dynamic>> preorderSave({
    required int wenxunId,
    required int tableId,
    required String remark,
    required List<Map<String, dynamic>> cart,
    required int operatorId,
    required String operatorName,
  }) async {
    return post('/api/tableorder/preorderSave', {
      'wenxun_id': wenxunId,
      'table_id': tableId,
      'remark': remark,
      'cart': cart,
      'operator_id': operatorId,
      'operator_name': operatorName,
    });
  }

  /// 查询预点单（list/total/remark/status）
  static Future<Map<String, dynamic>> preorderGet({
    required int wenxunId,
    required int tableId,
  }) async {
    return post('/api/tableorder/preorderGet', {
      'wenxun_id': wenxunId,
      'table_id': tableId,
    });
  }

  /// 清空预点单（保留预约状态）
  static Future<Map<String, dynamic>> preorderClear({
    required int wenxunId,
    required int tableId,
  }) async {
    return post('/api/tableorder/preorderClear', {
      'wenxun_id': wenxunId,
      'table_id': tableId,
    });
  }

  /// 顾客到店：一键开台 + 预点菜品转入正式账单，返回 kaitai_id/items/remark
  static Future<Map<String, dynamic>> preorderArrival({
    required int wenxunId,
    required int tableId,
    required int peopleNum,
    required int operatorId,
    required String operatorName,
  }) async {
    return post('/api/tableorder/preorderArrival', {
      'wenxun_id': wenxunId,
      'table_id': tableId,
      'people_num': peopleNum,
      'operator_id': operatorId,
      'operator_name': operatorName,
    });
  }

  /// 堂食结算（先吃后付统一收款）
  static Future<Map<String, dynamic>> tableSettle({
    required int wenxunId,
    required String kaitaiId,
    required int tableId,
    required String tableTitle,
    required String tableQuyu,
    required int peopleNum,
    required int operatorId,
    required String operatorName,
    required double goodsTotal,
    required double finalTotal,
    required String pay1Type,
    required double pay1Money,
    required List<Map<String, dynamic>> cart,
    int vipId = 0,
    String phone = '',
  }) async {
    return post('/api/tableorder/add', {
      'wenxun_id': wenxunId,
      'kaitai_id': kaitaiId,
      'table_id': tableId,
      'table_title': tableTitle,
      'table_quyu': tableQuyu,
      'people_num': peopleNum,
      'operator_id': operatorId,
      'operator_name': operatorName,
      'goods_total': goodsTotal,
      'final_total': finalTotal,
      'pay1_type': pay1Type,
      'pay1_money': pay1Money,
      'cart': cart,
      if (vipId > 0) 'vip_id': vipId,
      if (phone.isNotEmpty) 'phone': phone,
    });
  }

  /// 堂食订单列表（分页）
  static Future<Map<String, dynamic>> diningOrders(
      int wenxunId, int page, int limit, int? status) async {
    return post('/api/canyinorder/getList', {
      'wenxun_id': wenxunId,
      'page': page,
      'limit': limit,
      if (status != null) 'status': status,
    });
  }
}

class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}
