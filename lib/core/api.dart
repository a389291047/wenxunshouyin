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

  static Future<Map<String, dynamic>> vipAdd({
    required int wenxunId,
    required String phone,
    String? name,
    String amount = '0.00',
    String score = '0',
  }) async {
    return post('/shouyin/vip/xcxadd', {
      'vip_id': wenxunId,
      'phone': phone,
      if (name != null && name.isNotEmpty) 'name': name,
      'amount': amount,
      'score': score,
    });
  }

  static Future<Map<String, dynamic>> vipRecharge({
    required int vipId,
    required double czamount,
    required double zengsong,
    required String paymentMethod,
  }) async {
    return post('/shouyin/vip/chongzhi', {
      'id': vipId,
      'czamount': czamount,
      'zengsong': zengsong,
      'paymentMethod': paymentMethod,
    });
  }

  static Future<Map<String, dynamic>> vipDeduct({
    required int wenxunId,
    required int vipId,
    required double kcamount,
    String beizhu = '',
  }) async {
    return post('/shouyin/vip/kouchu', {
      'wenxun_id': wenxunId,
      'id': vipId,
      'kcamount': kcamount,
      'beizhu': beizhu,
    });
  }

  static Future<List> vipOrders(int vipId) async {
    final r = await post('/shouyin/vip/dingdanshouyinyuan', {'vip_id': vipId});
    return (r['dingdan'] ?? []) as List;
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
