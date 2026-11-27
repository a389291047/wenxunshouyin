import 'dart:convert';
import 'package:http/http.dart' as http;
import 'goods_store.dart';
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

  /// JSON POST（星驿付 v1.Payment 系列用：Content-Type application/json +
  /// merchant-no 头标商户身份，与小程序充值页同源）
  static Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> data,
      {Map<String, String> headers = const {}, int timeoutSec = 20}) async {
    try {
      final h = <String, String>{'Content-Type': 'application/json', ...headers};
      final res = await http
          .post(Uri.parse(base + path),
              headers: h, body: jsonEncode(data))
          .timeout(Duration(seconds: timeoutSec));
      if (res.statusCode != 200) {
        String msg = '服务器异常（${res.statusCode}）';
        try {
          final j = jsonDecode(utf8.decode(res.bodyBytes));
          if (j is Map && '${j['message'] ?? j['msg'] ?? ''}'.isNotEmpty) {
            msg = '${j['message'] ?? j['msg']}';
          }
        } catch (_) {}
        throw ApiError(msg);
      }
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is Map<String, dynamic>) return json;
      throw ApiError('接口返回数据异常');
    } on ApiError {
      rethrow;
    } catch (e) {
      throw ApiError('网络异常，请检查网络连接');
    }
  }

  // ==================== 星驿付 · 付款码支付（服务商模式，v3.3.161） ====================

  /// 付款码下单（B 扫 C：扫码枪扫顾客付款码）。商户身份走 merchant-no 头。
  /// 返回 {code, message, data:{星驿原始返回}, pending, outOrderNo}
  /// pending=true 表示受理成功（code=222222），顾客待输入密码，需轮询查询
  static Future<Map<String, dynamic>> xyfCodePay({
    required double amount,
    required String authCode,
    required String orderNo,
    String bizType = 'retail',
  }) {
    return postJson('/api/v1.payment/codePay', {
      'wenxun_id': Session.wenxunId,
      'orderNo': orderNo,
      'totalAmount': amount.toStringAsFixed(2),
      'authCode': authCode,
      'bizType': bizType,
    }, headers: {'merchant-no': '${Session.wenxunId}'});
  }

  /// 订单状态查询：data = wx_pay_orders 行
  /// status: 1待支付 2处理中 3成功 4失败 5超时
  static Future<Map<String, dynamic>> xyfQueryOrder(String orderNo) {
    return postJson('/api/v1.payment/queryOrder', {'orderNo': orderNo},
        headers: {'merchant-no': '${Session.wenxunId}'}, timeoutSec: 15);
  }

  /// 付款码前缀识别支付渠道（v3.3.260）：支付宝 25-30 / 微信 10-15 / 云闪付(银联) 62 开头。
  /// 背景：星驿回调异步更新 wx_pay_orders.pay_channel，桌面查到「已支付」时渠道
  /// 可能还是 0，导致支付宝单落成「其他支付」；按付款码前缀判断不依赖回调时序。
  static int xyfChannelFromCode(String authCode) {
    final c = authCode.replaceAll(RegExp(r'[\r\n\t\s]'), '').trim();
    if (c.length < 2) return 0;
    final p2 = int.tryParse(c.substring(0, 2)) ?? 0;
    if (p2 >= 25 && p2 <= 30) return 1; // 支付宝
    if (p2 >= 10 && p2 <= 15) return 2; // 微信支付
    if (c.startsWith('62')) return 9; // 云闪付
    return 0;
  }

  /// 付款码支付一体流程：下单 → （待输密码则轮询）→ 成功返回订单行 / 失败抛 ApiError
  /// 轮询节奏先快后慢（v3.3.248）：前 15 秒每秒一查（顾客输密码大多很快），
  /// 之后每 3 秒一查，总时长约 60 秒 —— 旧版 25 次×(查询RTT约3s+1s)≈100 秒太久，
  /// 收银员观感是「卡死/失败」。
  /// [onStatus] 进度回调：scanned=付款码已识别 / accepted=星驿付已受理 / waiting=顾客输入密码中
  static Future<Map<String, dynamic>> xyfScanPay({
    required double amount,
    required String authCode,
    required String orderNo,
    String bizType = 'retail',
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('scanned');
    final r = await xyfCodePay(
        amount: amount, authCode: authCode, orderNo: orderNo, bizType: bizType);
    if ('${r['code']}' != '0') {
      throw ApiError('${r['message'] ?? '下单失败'}');
    }
    onStatus?.call('accepted');
    Future<Map<String, dynamic>?> queryOnce() async {
      try {
        final q = await xyfQueryOrder('${r['outOrderNo'] ?? orderNo}');
        if ('${q['code']}' != '0') return null;
        return q['data'] is Map ? (q['data'] as Map).cast<String, dynamic>() : null;
      } on ApiError {
        return null; // 单次查询失败继续轮询
      }
    }

    if (r['pending'] != true) {
      // 星驿同步完成（免密小额常见）：立即查一次
      final o = await queryOnce();
      if (o != null) {
        final st = int.tryParse('${o['status']}') ?? 0;
        if (st == 3) return o;
        if (st == 4) throw ApiError('${o['error_msg'] ?? '支付失败'}');
      }
    }
    // 处理中（顾客输密码）：先快后慢轮询，总时长约 60 秒（v3.3.248）
    onStatus?.call('waiting');
    final sw = Stopwatch()..start();
    while (true) {
      // 前 15 秒每秒一查（多数顾客 10 秒内完成支付），之后每 3 秒一查
      final waitSec = sw.elapsedMilliseconds < 15000 ? 1 : 3;
      await Future.delayed(Duration(seconds: waitSec));
      if (sw.elapsedMilliseconds >= 60000) break; // 60 秒总预算
      onStatus?.call('waiting');
      final o = await queryOnce();
      if (o == null) continue;
      final st = int.tryParse('${o['status']}') ?? 0;
      if (st == 3) return o;
      if (st == 4) throw ApiError('${o['error_msg'] ?? '顾客取消支付'}');
    }
    throw ApiError('支付超时（60 秒未确认）：顾客可能仍在输入密码，点「重新扫码」会先核对上一笔结果');
  }

  /// 退款状态轮询（零售）：refundStatus = none无退款中记录 | processing | success | fail
  static Future<Map<String, dynamic>> refundStatusRetail(
      {required int orderId}) {
    return post('/shouyin/order/refundStatus', {
      'wenxun_id': Session.wenxunId,
      'order_id': orderId,
    });
  }

  /// 退款状态轮询（堂食）
  static Future<Map<String, dynamic>> refundStatusDining(
      {required int orderId}) {
    return post('/api/canyinorder/refundStatus', {
      'wenxun_id': Session.wenxunId,
      'order_id': orderId,
    });
  }

  /// 未落单流水列表（收银机崩溃兜底）：今日星驿付已收款但未关联订单
  static Future<Map<String, dynamic>> xyfOrphanList() {
    return postJson('/api/v1.payment/orphanList', {},
        headers: {'merchant-no': '${Session.wenxunId}'});
  }

  /// 未落单流水原路退款（需权限密码）
  static Future<Map<String, dynamic>> xyfOrphanRefund({
    required String threeOrderNo,
    required String password,
    required int operatorId,
  }) {
    return postJson('/api/v1.payment/orphanRefund', {
      'three_order_no': threeOrderNo,
      'password': password,
      'operator_id': operatorId,
    }, headers: {'merchant-no': '${Session.wenxunId}'});
  }

  /// 退款中轮询：until success/fail 或超时（约 40 秒），返回最终 refundStatus
  static Future<String> pollRefundStatus({
    required bool dining,
    required int orderId,
  }) async {
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(seconds: 2));
      try {
        final r = dining
            ? await refundStatusDining(orderId: orderId)
            : await refundStatusRetail(orderId: orderId);
        final st = '${r['refundStatus'] ?? 'processing'}';
        if (st == 'success' || st == 'fail' || st == 'none') return st;
      } on ApiError {
        // 单次查询失败继续轮询
      }
    }
    return 'processing';
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

  /// 商家自助注册（一次建齐：商户 + 默认分类 + 会员等级 + 店长账号）
  /// hangye: 1零售 2餐饮 3生鲜 4商超 5服装
  static Future<Map<String, dynamic>> register({
    required String name,
    required String phone,
    required String password,
    required int hangye,
    String model = 'desktop',
  }) {
    return post('/api/s1.reg/index', {
      'name': name,
      'phone': phone,
      'password': password,
      'confirm_password': password,
      'hangye': hangye,
      'model': model,
    }, withToken: false);
  }

  // ==================== 商品 ====================

  /// 分类 + 商品一次拉全（零售点单页用）。
  /// v3.3.276b 方案 C：fingerprint 非空时带指纹校验，服务器数据没变只回 unchanged
  static Future<Map<String, dynamic>> goodsAll(int wenxunId, {String fingerprint = ''}) async {
    final r = await post('/shouyin/goodscat/index', {
      'wenxun_id': wenxunId,
      if (fingerprint.isNotEmpty) 'fingerprint': fingerprint,
    });
    return {
      'unchanged': r['unchanged'] == true,
      'fingerprint': '${r['fingerprint'] ?? ''}',
      'cat': r['cat'] ?? [],
      'goods': r['goods'] ?? [],
    };
  }

  /// 商品加载（本地缓存 + 指纹后台校验，v3.3.276b 方案 C）：
  /// 有缓存先 onCache 秒显（loading 提前结束，页面可操作）；
  /// 随后带指纹请求——unchanged 返回 null（保持缓存即可）；
  /// 有变化返回新数据（已写缓存）；无缓存走全量；
  /// 网络失败但有缓存时静默返回 null（缓存兜底，不阻塞页面）；
  /// force=true（v3.3.277 收银台刷新按钮）：跳过缓存直拉全量并回写缓存（改价后手动刷新）
  static Future<Map<String, dynamic>?> goodsAllCached(
      int wenxunId, {void Function(Map<String, dynamic>)? onCache, bool force = false}) async {
    Map<String, dynamic>? cached;
    if (!force) {
      cached = await GoodsStore.load(wenxunId);
      if (cached != null) {
        onCache?.call({'cat': cached['cat'], 'goods': cached['goods']});
      }
    }
    try {
      final r = await goodsAll(wenxunId, fingerprint: force ? '' : '${cached?['fp'] ?? ''}');
      if (r['unchanged'] == true) return null;
      await GoodsStore.save(wenxunId, '${r['fingerprint']}', r['cat'], r['goods']);
      return {'cat': r['cat'], 'goods': r['goods']};
    } on ApiError {
      if (!force && cached != null) return null;
      rethrow;
    }
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

  /// 商品多规格数据（零售/餐饮通用，/api 根命名空间，v3.3.252 餐饮开台兜底用）
  /// 返回 data:{spec_dims:[{dim_id,dim_name,values:[{id,name}]}], sku_list:[{id,sku_name,amount,stock,duoguige_value_ids,code}]}
  static Future<Map<String, dynamic>> goodsSku(int wenxunId, int goodsId) async {
    return post('/api/goods/sku', {
      'wenxun_id': wenxunId,
      'goods_id': goodsId,
    });
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
    String payOrderNo = '', // 星驿付支付流水号（扫码收款单退款关联）
    int payChannel = 0, // 星驿付渠道：1支付宝 2微信 9银联 12数币
    double originalTotal = 0, // 商品原价合计（活动/优惠券前，v3.3.222 供补打小票显示优惠）
    double mollen = 0, // 现金抹零金额（v3.3.239，落 wx_order.quiling 供交班统计/补打小票）
    double wholeRate = 0, // 整单折扣（8.5 = 8.5折，0 无；v3.3.246）
    double wholeAmount = 0, // 整单优惠总额（折扣优惠额或改价差额，v3.3.246）
    List<Map<String, dynamic>> comboPay = const [], // 组合支付明细（v3.3.258，2-3 笔）
  }) async {
    return post('/shouyin/order/add', {
      'id': wenxunId,
      'renyuan_id': renyuanId,
      'total': total,
      'paymentMethod': paymentMethod,
      'cart': cart,
      if (vipId > 0) 'vip_id': vipId,
      if (payOrderNo.isNotEmpty) 'pay_order_no': payOrderNo,
      if (payChannel > 0) 'payment_channel': payChannel,
      if (originalTotal > 0) 'original_total': originalTotal,
      if (mollen > 0) 'mollen': mollen,
      if (wholeRate > 0) 'whole_rate': wholeRate,
      if (wholeAmount > 0) 'whole_amount': wholeAmount,
      // 组合支付（v3.3.258）：[{method, amount, pay_order_no, pay_channel}]，
      // 第一笔为主支付方式，其余落 payment_method_2/3；含会员支付时后端先扣余额
      if (comboPay.length >= 2) 'combo_pay': comboPay,
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
    int renyuanId = 0, // 收银员归属（v3.3.240，交班统计会员支付依赖此字段）
    String cashierName = '',
    double wholeRate = 0, // 整单折扣（8.5 = 8.5折，0 无；v3.3.246）
    double wholeAmount = 0, // 整单优惠总额（折扣优惠额或改价差额，v3.3.246）
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
      if (renyuanId > 0) 'renyuan_id': renyuanId,
      if (cashierName.isNotEmpty) 'cashier_name': cashierName,
      if (wholeRate > 0) 'whole_rate': wholeRate,
      if (wholeAmount > 0) 'whole_amount': wholeAmount,
    });
  }

  /// 收银端订单列表（店内+小程序混合，按 order_from 前端区分）
  static Future<List> ordersAll(int wenxunId) async {
    final r = await post('/shouyin/order/dingdanshouyinyuan', {
      'wenxun_id': wenxunId,
    });
    return (r['dingdan'] ?? []) as List;
  }

  /// 订单退款（支持部分退款）：需退款密码（收银员级，默认本人手机号后6位）
  /// amount 传 0/null = 整单退
  static Future<Map<String, dynamic>> orderRefund({
    required int wenxunId,
    required int orderId,
    required String reason,
    required int operatorId,
    required String operator,
    required String password,
    double amount = 0,
    List<Map<String, dynamic>> refundGoods = const [],
  }) {
    return post('/shouyin/order/refund', {
      'wenxun_id': wenxunId,
      'order_id': orderId,
      'reason': reason,
      'operator_id': operatorId,
      'operator': operator,
      'password': password,
      if (amount > 0) 'refund_amount': amount,
      if (refundGoods.isNotEmpty) 'refund_goods': refundGoods,
    });
  }

  /// 员工列表（商户管理用）：返回 [{id, renyuan, phone, role_name, has_quanxian, ...}]
  static Future<List> staffList() async {
    final r = await post('/api/shouyinyuan/lst', {});
    return ((r['list'] ?? r['yuangong']) ?? []) as List;
  }

  /// 设置员工权限密码（仅商户可操作；现金订单退款/现金充值用，6位数字）
  static Future<Map<String, dynamic>> setStaffQuanxian({
    required int staffId,
    required String password,
  }) {
    return post('/api/shouyinyuan/xiugai', {
      'id': staffId,
      'quanxian_password': password,
    });
  }

  /// 校验员工权限密码（v3.3.192）：与「订单退款 / 现金充值」同一套密码
  /// 收银端二次确认场景（如清空购物车）使用；密码不落本机，全部由服务端判定
  /// 返回 code=200 通过，否则 msg 为失败原因
  static Future<Map<String, dynamic>> checkQuanxian({
    required int staffId,
    required String password,
  }) {
    return post('/api/shouyinyuan/checkpwd', {
      'wenxun_id': Session.wenxunId,
      'staff_id': staffId,
      'password': password,
    });
  }

  // ==================== 会员 ====================

  static Future<List> vipList(int wenxunId) async {
    final r = await post('/shouyin/vip/mac', {'wenxun_id': wenxunId});
    return (r['data'] ?? []) as List;
  }

  /// 会员分页列表（v3.3.276b，会员管理页专用）：page 从 1 起；
  /// 返回 {list, summary:{count,total_amount}, hasMore}；kw 支持手机号/姓名/微信昵称模糊
  static Future<Map<String, dynamic>> vipPage({
    required int wenxunId,
    required int page,
    int limit = 50,
    String kw = '',
  }) async {
    final r = await post('/shouyin/vip/mac', {
      'wenxun_id': wenxunId,
      'page': page,
      'limit': limit,
      'kw': kw,
    });
    return {
      'list': (r['data'] ?? []) as List,
      'summary': (r['summary'] ?? {}) as Map,
      'hasMore': r['has_more'] == true,
    };
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

  /// 添加会员新版（v3.3.231，走 v3.Vip/addVip）：
  /// 不传姓名（后端缺省用手机号）、不选等级（后端自动取10折等级，没有则报「无法添加会员」）
  static Future<Map<String, dynamic>> vipAddV3({
    required int wenxunId,
    required String phone,
    String amount = '0',
    String score = '0',
    String shika = '',
    String chepai = '',
  }) async {
    return post('/api/v3.Vip/addVip', {
      'wenxun_id': wenxunId,
      'vip_id': wenxunId,
      'staff_id': Session.staffId,
      'phone': phone,
      'amount': amount,
      'score': score,
      'shika': shika,
      'chepai': chepai,
    });
  }

  /// 充值档次列表（与小程序充值页同源 v1.vip/huodonglst；wx_vip_huodong）
  static Future<List> vipRechargeTiers(int wenxunId) async {
    final r = await post('/api/v1.vip/huodonglst', {'wenxun_id': wenxunId}, withToken: false);
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '获取充值活动失败'}');
    final l = ((r['huodong'] ?? []) as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    l.sort((a, b) => (double.tryParse('${a['amount']}') ?? 0)
        .compareTo(double.tryParse('${b['amount']}') ?? 0));
    return l;
  }

  /// 会员充值提交（收银端 shouyin/vip/chongzhi，现金+付款码统一入口）
  /// 现金：需权限密码；付款码：传 codePay 成功流水号 orderNo（免密）
  static Future<Map<String, dynamic>> vipRechargeSubmit({
    required int vipId,
    required int wenxunId,
    required double amount,
    required double gift,
    required String method, // '现金' | '付款码'
    int operatorId = 0,
    String password = '',
    String orderNo = '',
  }) {
    return post('/shouyin/vip/chongzhi', {
      'id': vipId,
      'wenxun_id': wenxunId,
      'czamount': amount.toStringAsFixed(2),
      'zengsong': gift.toStringAsFixed(2),
      'paymentMethod': method,
      if (operatorId > 0) 'operator_id': operatorId,
      if (password.isNotEmpty) 'password': password,
      if (orderNo.isNotEmpty) 'order_no': orderNo,
    });
  }

  /// 收银端充值记录列表（v3.3.174，wx_vip_chongzhika 近7天，含退款可行性 can_refund/cannot_reason）
  static Future<List> chongzhikaList(int wenxunId) async {
    final r = await post('/shouyin/vip/chongzhikaList', {'wenxun_id': wenxunId});
    if ('${r['code']}' == '200') return (r['data']?['list'] ?? []) as List;
    throw ApiError('${r['msg'] ?? '获取充值记录失败'}');
  }

  /// 充值退款（v3.3.174）：现金 7 天内 / 扫码当天，权限码校验，扫码走星驿付原路
  static Future<Map<String, dynamic>> chongzhikaRefund({
    required int wenxunId,
    required int id,
    required int operatorId,
    required String password,
    String reason = '',
  }) {
    return post('/shouyin/vip/chongzhikaRefund', {
      'wenxun_id': wenxunId,
      'id': id,
      'operator_id': operatorId,
      'password': password,
      if (reason.isNotEmpty) 'reason': reason,
    });
  }

  /// 会员充值 · 扫顾客付款码支付（与小程序充值页同源 payment/codePay，type=A 充值）
  /// amount 单位元（两位小数字符串），code 为 18-30 位付款码；orderNo 客户端生成便于对账入账
  static Future<Map<String, dynamic>> rechargeCodePay({
    required int wenxunId,
    required double amount,
    required String code,
    String? orderNo,
  }) async {
    final amt = amount.toStringAsFixed(2);
    final txamt = (amount * 100).round().toString();
    return post('/api/payment/codePay', {
      'denglu': wenxunId,
      'amount': amt,
      'txamt': txamt,
      'code': code,
      'type': 'A',
      if (orderNo != null && orderNo.isNotEmpty) 'orderNo': orderNo,
    }, withToken: false);
  }

  static Future<List> vipOrders(int vipId) async {
    final r = await post('/shouyin/vip/dingdanshouyinyuan', {'vip_id': vipId});
    return (r['dingdan'] ?? []) as List;
  }

  /// 会员近期消费/充值记录（v3.3.250 会员详情右侧记录卡）
  /// 返回 {'consume': 近5笔消费, 'recharge': 近5笔充值}
  static Future<Map<String, List>> vipRecentRecords({required int vipId, required int wenxunId}) async {
    final r = await post('/shouyin/vip/recentRecords', {'id': vipId, 'wenxun_id': wenxunId});
    if ('${r['code']}' == '200') {
      return {
        'consume': (r['consume'] ?? []) as List,
        'recharge': (r['recharge'] ?? []) as List,
      };
    }
    throw ApiError('${r['msg'] ?? '获取会员记录失败'}');
  }

  // ==================== 核销管理（v3.3.262：小程序订单核销 + 抖音团购核销） ====================

  /// 核销列表
  /// platform: mini（小程序订单）| douyin（抖音团购流水）
  /// tab: undone（未核销）| done（已核销）| refund（退款）
  static Future<Map<String, dynamic>> hexiaoList({
    required int wenxunId,
    required String platform,
    required String tab,
    String day = 'today',
    String kw = '',
  }) async {
    final r = await post('/shouyin/hexiao/list', {
      'wenxun_id': wenxunId,
      'platform': platform,
      'tab': tab,
      'day': day,
      'kw': kw,
    });
    if ('${r['code']}' == '200') return r;
    throw ApiError('${r['msg'] ?? '获取核销列表失败'}');
  }

  /// 小程序订单预检（扫码/输码，不核销）
  static Future<Map<String, dynamic>> hexiaoCheck({required int wenxunId, required String code, String orderNo = ''}) async {
    final r = await post('/shouyin/hexiao/check', {
      'wenxun_id': wenxunId,
      'code': code,
      'order_no': orderNo,
    });
    if ('${r['code']}' == '200') return r['order'] as Map<String, dynamic>? ?? {};
    throw ApiError('${r['msg'] ?? '核销码校验失败'}');
  }

  /// 小程序订单确认核销（CAS 20→40）
  static Future<void> hexiaoVerifyMini({required int wenxunId, required int id, String code = '', String operatorName = ''}) async {
    final r = await post('/shouyin/hexiao/verifyMini', {
      'wenxun_id': wenxunId,
      'id': id,
      'code': code,
      'operator_name': operatorName,
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '核销失败'}');
  }

  /// 退款审核（agree / reject，仅推进状态）
  static Future<String> hexiaoRefundAudit({required int wenxunId, required int id, required String action, String operatorName = ''}) async {
    final r = await post('/shouyin/hexiao/refundAudit', {
      'wenxun_id': wenxunId,
      'id': id,
      'action': action,
      'operator_name': operatorName,
    });
    if ('${r['code']}' == '200') return '${r['msg'] ?? '操作成功'}';
    throw ApiError('${r['msg'] ?? '审核失败'}');
  }

  /// 抖音已授权门店列表
  static Future<List> douyinShops(int wenxunId) async {
    final r = await post('/shouyin/hexiao/douyinShops', {'wenxun_id': wenxunId});
    if ('${r['code']}' == '200') return (r['list'] ?? []) as List;
    throw ApiError('${r['msg'] ?? '获取抖音门店失败'}');
  }

  /// 抖音验券准备：code（明文券码）或 raw（扫码原文/短链）二选一
  static Future<Map<String, dynamic>> douyinPrepare({required int wenxunId, required String poiId, String code = '', String raw = ''}) async {
    final r = await post('/shouyin/hexiao/douyinPrepare', {
      'wenxun_id': wenxunId,
      'poi_id': poiId,
      'code': code,
      'raw': raw,
    });
    if ('${r['code']}' == '200') {
      return {
        'verify_token': '${r['verify_token'] ?? ''}',
        'certificates': (r['certificates'] ?? []) as List,
      };
    }
    throw ApiError('${r['msg'] ?? '验券失败'}');
  }

  /// 抖音确认核销
  static Future<void> douyinVerify({
    required int wenxunId,
    required String poiId,
    required String verifyToken,
    required List<String> encryptedCodes,
    required String code,
    String skuInfo = '',
    int operatorId = 0,
    String operatorName = '',
  }) async {
    final r = await post('/shouyin/hexiao/douyinVerify', {
      'wenxun_id': wenxunId,
      'poi_id': poiId,
      'verify_token': verifyToken,
      'encrypted_codes': encryptedCodes,
      'code': code,
      'sku_info': skuInfo,
      'operator_id': operatorId,
      'operator_name': operatorName,
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '核销失败'}');
  }

  /// 抖音撤销核销（验券 1 小时内有效）
  static Future<void> douyinCancel({required int wenxunId, required int logId, String operatorName = ''}) async {
    final r = await post('/shouyin/hexiao/douyinCancel', {
      'wenxun_id': wenxunId,
      'log_id': logId,
      'operator_name': operatorName,
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '撤销失败'}');
  }

  /// 智能核销识别（后端按 小程序→美团→抖音 逐平台只读探测）
  /// 成功返回 {type: mini|mt|dy, order?/prepare?/certificates?...}；失败抛出各平台汇总原因
  static Future<Map<String, dynamic>> hexiaoAutoCheck({required int wenxunId, required String code}) async {
    final r = await post('/shouyin/hexiao/autoCheck', {
      'wenxun_id': wenxunId,
      'code': code,
    });
    if ('${r['code']}' == '200') return r;
    throw ApiError('${r['msg'] ?? '未能识别券码所属平台'}');
  }

  // ==================== 无限聚核 · 美团团购核销（服务零售，v3.3.271） ====================
  // 文档：https://doc.elys.cn/index.md；API Key 只存服务端云端配置，客户端经 tp8 代理转发

  /// 读取聚核配置（Key 掩码回显）→ {api_key_masked, shop_id, configured}
  static Future<Map<String, dynamic>> elysConfig(int wenxunId) async {
    final r = await post('/shouyin/elys/config', {'wenxun_id': wenxunId, 'act': 'get'});
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '读取配置失败'}');
    return (r['data'] ?? {}) as Map<String, dynamic>;
  }

  /// 保存聚核配置（api_key 传空=不修改）
  static Future<void> elysSaveConfig({
    required int wenxunId,
    required String shopId,
    String apiKey = '',
  }) async {
    final r = await post('/shouyin/elys/config', {
      'wenxun_id': wenxunId,
      'act': 'save',
      'shop_id': shopId,
      'api_key': apiKey,
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '保存配置失败'}');
  }

  /// 美团商户授权链接 → {url}
  static Future<String> elysAuthUrl({required int wenxunId, int platform = 1}) async {
    final r = await post('/shouyin/elys/authUrl', {'wenxun_id': wenxunId, 'platform': platform});
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '获取授权链接失败'}');
    return '${(r['data'] ?? {})['url'] ?? ''}';
  }

  /// 团购列表 → data[]
  static Future<List> elysDeals({required int wenxunId, int offset = 1, int limit = 20, int platform = 1}) async {
    final r = await post('/shouyin/elys/deals', {
      'wenxun_id': wenxunId,
      'platform': platform,
      'offset': offset,
      'limit': limit,
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '获取团购列表失败'}');
    return ((r['data'] ?? {})['deals'] ?? []) as List;
  }

  /// 预核销（券码校验）→ data（ticketInfo 原文透传）
  static Future<Map<String, dynamic>> elysPrepare({
    required int wenxunId,
    required String code,
    int platform = 1,
  }) async {
    final r = await post('/shouyin/elys/prepare', {
      'wenxun_id': wenxunId,
      'platform': platform,
      'code': code,
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '验券失败'}');
    return (r['data'] ?? {}) as Map<String, dynamic>;
  }

  /// 核销 → {rows, credentials, wxdgOrderNo}
  static Future<Map<String, dynamic>> elysVerify({
    required int wenxunId,
    required String code,
    required String ticketInfo,
    int num = 1,
    int platform = 1,
    String operatorName = '',
  }) async {
    final r = await post('/shouyin/elys/verify', {
      'wenxun_id': wenxunId,
      'platform': platform,
      'code': code,
      'ticket_info': ticketInfo,
      'num': num,
      'operator_name': operatorName,
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '核销失败'}');
    return (r['data'] ?? {}) as Map<String, dynamic>;
  }

  /// 撤销核销（凭 consumeCredential 或核销流水 log_id）
  static Future<Map<String, dynamic>> elysCancel({
    required int wenxunId,
    List<String> credentials = const [],
    int logId = 0,
    int platform = 1,
    String operatorName = '',
  }) async {
    final r = await post('/shouyin/elys/cancel', {
      'wenxun_id': wenxunId,
      'platform': platform,
      'credentials': credentials,
      'log_id': logId,
      'operator_name': operatorName,
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '撤销失败'}');
    return (r['data'] ?? {}) as Map<String, dynamic>;
  }

  /// 核销记录（本地流水）→ rows[]
  static Future<List> elysRecords({required int wenxunId, String day = 'today', int platform = 1}) async {
    final r = await post('/shouyin/elys/records', {
      'wenxun_id': wenxunId,
      'platform': platform,
      'day': day,
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '查询记录失败'}');
    return ((r['data'] ?? {})['rows'] ?? []) as List;
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

  /// 云打印机实时状态同步（v3.3.122）：后端逐台查易联云 getprintstatus，
  /// token 过期自动刷新并回写库；返回 data.list（字段同 printers，is_online/has_paper 为实时值）
  static Future<List> printerStatusSync(int wenxunId) async {
    final r = await post('/api/printer/statusList', {'wenxun_id': wenxunId});
    final d = r['data'];
    if (d is Map && d['list'] is List) return d['list'] as List;
    return [];
  }

  /// 打印机路由配置读取（v3.3.125）：返回 {cfg, update_time}；
  /// cfg 为 null = 该商户从未同步过（客户端可上传本机配置）
  static Future<Map<String, dynamic>> printerRouteCfg(int wenxunId) async {
    final r = await post('/api/printer/routeGet', {'wenxun_id': wenxunId});
    if ('${r['code']}' == '200') {
      final d = r['data'];
      return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
    }
    throw ApiError('${r['msg'] ?? '读取打印机配置失败'}');
  }

  /// 打印机路由配置保存到云端（整份覆盖）
  static Future<void> printerRouteCfgSave(int wenxunId, Map<String, dynamic> cfg) async {
    final r = await post('/api/printer/routeSave', {
      'wenxun_id': wenxunId,
      'cfg': jsonEncode(cfg),
    });
    if ('${r['code']}' != '200') throw ApiError('${r['msg'] ?? '保存打印机配置失败'}');
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

  /// 就餐中桌台「未起菜」统计（未传后厨菜品数，v3.3.111）
  /// 返回 {"t<桌台ID>": {"total": 菜品总份数, "pending": 未传后厨份数}}
  static Future<Map<String, dynamic>> kitchenPending(int wenxunId) async {
    final r = await post('/api/diancan/kitchenPending', {'wenxun_id': wenxunId});
    final d = r['data'];
    final tables = d is Map ? d['tables'] : null;
    return tables is Map ? Map<String, dynamic>.from(tables) : <String, dynamic>{};
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
    int operatorId = 0,
    String password = '',
  }) async {
    return post('/api/zhuotai/cancel_kaitai', {
      'wenxun_id': wenxunId,
      'table_id': tableId,
      'kaitai_id': kaitaiId,
      'operator_id': operatorId,
      'password': password,
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

  /// 清台（v3.3.87）：已结账待清台(status=4)的桌台手动恢复为空闲
  static Future<Map<String, dynamic>> tableQingtai({
    required int wenxunId,
    required int tableId,
  }) async {
    return post('/api/zhuotai/qingtai', {
      'wenxun_id': wenxunId,
      'table_id': tableId,
      'operator_id': Session.staffId,
      'operator_name': Session.staffName,
    });
  }

  /// 修改就餐中桌台的用餐人数（v3.3.76）
  static Future<Map<String, dynamic>> tablePeople({
    required int wenxunId,
    required int tableId,
    required int peopleNum,
  }) async {
    return post('/api/zhuotai/renshu', {
      'wenxun_id': wenxunId,
      'id': tableId,
      'people_num': peopleNum,
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

  /// 退菜（未结算明细；num 为本次退几件，v3.3.70）
  static Future<Map<String, dynamic>> tableRetreatDish({
    required int wenxunId,
    required String kaitaiId,
    required int itemId,
    required int num,
  }) async {
    return post('/api/tableorder/tuicai', {
      'wenxun_id': wenxunId,
      'kaitai_id': kaitaiId,
      'item_id': itemId,
      'num': num,
    });
  }

  /// 出品划菜（itemId=0 时该桌全部划菜，v3.3.71）
  static Future<Map<String, dynamic>> tableChuhua({
    required int wenxunId,
    required String kaitaiId,
    int itemId = 0,
    bool isChu = true,
  }) async {
    return post('/api/tableorder/chuhua', {
      'wenxun_id': wenxunId,
      'kaitai_id': kaitaiId,
      'item_id': itemId,
      'is_chu': isChu ? 1 : 0,
    });
  }

  /// 并台：源桌未结算菜品并入目标桌，源桌恢复空闲（v3.3.71）
  static Future<Map<String, dynamic>> tableMerge({
    required int wenxunId,
    required String sourceKaitaiId,
    required String targetKaitaiId,
  }) async {
    return post('/api/tableorder/hebing', {
      'wenxun_id': wenxunId,
      'source_kaitai_id': sourceKaitaiId,
      'target_kaitai_id': targetKaitaiId,
    });
  }

  /// 一键传后厨/起菜：该桌所有「未传后厨」菜品置为已传（v3.3.112）
  static Future<Map<String, dynamic>> tableChuanHouchu({
    required int wenxunId,
    required String kaitaiId,
  }) async {
    return post('/api/diancan/chuanHouchu', {
      'wenxun_id': wenxunId,
      'kaitai_id': kaitaiId,
    });
  }

  /// 修改未传后厨明细的做法备注（v3.3.141）：itemIds=明细 id 列表，remark 空串=清除做法
  static Future<Map<String, dynamic>> tableItemZuofa({
    required int wenxunId,
    required String kaitaiId,
    required List<int> itemIds,
    required String remark,
  }) async {
    return post('/api/tableorder/zuofa', {
      'wenxun_id': wenxunId,
      'kaitai_id': kaitaiId,
      'item_ids': itemIds,
      'remark': remark,
    });
  }

  /// 餐饮交班对账（今日堂食统计，v3.3.71）
  static Future<Map<String, dynamic>> diningJiaoban(int wenxunId) async {
    return post('/shouyin/canyin/jiaoban', {'wenxun_id': wenxunId});
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

  // ==================== 顾客扫码预点餐（v3.3.101） ====================

  /// 顾客扫码提交的待确认预点单列表：data.list / data.counts / data.count
  static Future<Map<String, dynamic>> preorderPending({required int wenxunId}) async {
    return post('/api/diancan/pendingList', {'wenxun_id': wenxunId});
  }

  /// 预约点餐列表（全部状态，v3.3.102）：data.list / data.counts / data.total
  /// [status] 0 待安排 / 1 已安排 / 2 已拒绝 / all
  static Future<Map<String, dynamic>> preorderList({
    required int wenxunId,
    String status = '0',
    String keyword = '',
  }) async {
    return post('/api/diancan/preorderList', {
      'wenxun_id': wenxunId,
      'status': status,
      'keyword': keyword,
    });
  }

  /// 同意并开台（未开台自动开台，已开台追加菜品）：data.kaitai_id / items / is_new
  /// [tableId] 收银员安排的桌台（统一预约入口必填）
  static Future<Map<String, dynamic>> preorderApprove({
    required int wenxunId,
    required int preorderId,
    required int peopleNum,
    required int operatorId,
    required String operatorName,
    int tableId = 0,
  }) async {
    return post('/api/diancan/preorderApprove', {
      'wenxun_id': wenxunId,
      'preorder_id': preorderId,
      'table_id': tableId,
      'people_num': peopleNum,
      'operator_id': operatorId,
      'operator_name': operatorName,
    });
  }

  /// 拒绝顾客预点单
  static Future<Map<String, dynamic>> preorderReject({
    required int wenxunId,
    required int preorderId,
    required int operatorId,
    required String operatorName,
  }) async {
    return post('/api/diancan/preorderReject', {
      'wenxun_id': wenxunId,
      'preorder_id': preorderId,
      'operator_id': operatorId,
      'operator_name': operatorName,
    });
  }

  /// 桌台点餐二维码图片地址（顾客扫码入口）
  static String tableQrUrl({required int wenxunId, required int tableId}) =>
      '$base/api/diancan/qr?wenxun_id=$wenxunId&table_id=$tableId';

  /// 统一预约点餐二维码（所有顾客同一个链接，不绑桌台，v3.3.102）
  static String preorderQrUrl({required int wenxunId}) =>
      '$base/api/diancan/qr?wenxun_id=$wenxunId';

  /// 统一预约点餐 H5 链接（可发朋友圈/公众号菜单/店内海报）
  static String preorderUnionUrl({required int wenxunId}) =>
      '$base/h5/diancan.html?wenxun_id=$wenxunId';

  /// 桌台点餐 H5 链接（顾客手机直接打开）
  static String tableOrderUrl({required int wenxunId, required int tableId}) =>
      '$base/h5/diancan.html?wenxun_id=$wenxunId&table_id=$tableId';

  /// 堂食结算（先吃后付统一收款；pay1Type 传 '挂账' 时登记挂账台账，稍后核销）
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
    String guazhangName = '',
    String guazhangPhone = '',
    // v3.3.71 扩展：备注/费用/折扣/抹零/积分/发票
    String orderRemark = '',
    double kaitaiFee = 0,
    double teaFee = 0,
    double serviceFee = 0,
    double boxFee = 0,
    double discountRate = 10,
    double quiling = 0,
    int jifenNum = 0,
    double jifenDeduct = 0,
    String invoiceTitle = '',
    String invoiceNo = '',
    String payOrderNo = '', // 星驿付支付流水号（扫码收款结算单退款关联）
    int payChannel = 0, // 星驿付渠道：1支付宝 2微信 9银联 12数币
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
      if (guazhangName.isNotEmpty) 'guazhang_name': guazhangName,
      if (guazhangPhone.isNotEmpty) 'guazhang_phone': guazhangPhone,
      if (orderRemark.isNotEmpty) 'order_remark': orderRemark,
      if (kaitaiFee > 0) 'kaitai_fee': kaitaiFee,
      if (teaFee > 0) 'tea_fee': teaFee,
      if (serviceFee > 0) 'service_fee': serviceFee,
      if (boxFee > 0) 'box_fee': boxFee,
      if (discountRate != 10) 'discount_rate': discountRate,
      if (quiling > 0) 'quiling': quiling,
      if (jifenNum > 0) 'jifen_num': jifenNum,
      if (jifenDeduct > 0) 'jifen_deduct': jifenDeduct,
      if (invoiceTitle.isNotEmpty) 'invoice_title': invoiceTitle,
      if (invoiceNo.isNotEmpty) 'invoice_no': invoiceNo,
      if (payOrderNo.isNotEmpty) 'pay_order_no': payOrderNo,
      if (payChannel > 0) 'payment_channel': payChannel,
    });
  }

  // ==================== 餐饮点餐方式（不开台 / 外卖 / 排队 / 挂账，v3.3.63） ====================

  /// 不开台点餐结算（快餐/外带，无桌台，即点即收）
  static Future<Map<String, dynamic>> directSettle({
    required int wenxunId,
    required int operatorId,
    required String operatorName,
    required double goodsTotal,
    required double finalTotal,
    required String pay1Type,
    required double pay1Money,
    required List<Map<String, dynamic>> cart,
    int peopleNum = 1,
    int vipId = 0,
    String phone = '',
    String payOrderNo = '', // 星驿付支付流水号（扫码收款结算单退款关联）
    int payChannel = 0, // 星驿付渠道：1支付宝 2微信 9银联 12数币
  }) async {
    return post('/api/tableorder/add', {
      'direct': 1,
      'wenxun_id': wenxunId,
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
      if (payOrderNo.isNotEmpty) 'pay_order_no': payOrderNo,
      if (payChannel > 0) 'payment_channel': payChannel,
    });
  }

  /// 外卖流水登记（只记金额+备注）
  static Future<Map<String, dynamic>> waimaiAdd({
    required double amount,
    String beizhu = '',
  }) {
    return post('/shouyin/canyin/waimaiAdd', {
      'wenxun_id': Session.wenxunId,
      'amount': amount,
      'beizhu': beizhu,
      'operator_id': Session.staffId,
      'operator_name': Session.staffName,
    });
  }

  /// 外卖流水列表（当天 + 合计）
  static Future<Map<String, dynamic>> waimaiLst() {
    return post('/shouyin/canyin/waimaiLst', {'wenxun_id': Session.wenxunId});
  }

  /// 排队取号（persons 用餐人数）
  static Future<Map<String, dynamic>> paihaoAdd({required int persons}) {
    return post('/shouyin/canyin/paihaoAdd', {
      'wenxun_id': Session.wenxunId,
      'persons': persons,
      'operator_id': Session.staffId,
      'operator_name': Session.staffName,
    });
  }

  /// 排队队列（当天）
  static Future<Map<String, dynamic>> paihaoLst() {
    return post('/shouyin/canyin/paihaoLst', {'wenxun_id': Session.wenxunId});
  }

  /// 排队叫号
  static Future<Map<String, dynamic>> paihaoCall({required int id}) {
    return post('/shouyin/canyin/paihaoCall',
        {'wenxun_id': Session.wenxunId, 'id': id});
  }

  /// 排队标记（status: 2-完成 3-过号）
  static Future<Map<String, dynamic>> paihaoMark(
      {required int id, required int status}) {
    return post('/shouyin/canyin/paihaoMark',
        {'wenxun_id': Session.wenxunId, 'id': id, 'status': status});
  }

  /// 挂账台账列表（status 空=全部，0=未结 1=已结）
  static Future<Map<String, dynamic>> guazhangLst({int? status}) {
    return post('/shouyin/canyin/guazhangLst', {
      'wenxun_id': Session.wenxunId,
      if (status != null) 'status': status,
    });
  }

  /// 挂账核销收款
  static Future<Map<String, dynamic>> guazhangSettle(
      {required int id, required String payType}) {
    return post('/shouyin/canyin/guazhangSettle', {
      'wenxun_id': Session.wenxunId,
      'id': id,
      'pay_type': payType,
      'operator_id': Session.staffId,
      'operator_name': Session.staffName,
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

  /// 开台订单（就餐中）列表（v3.3.84）：数据源 wx_zhuotai status=2 + 明细聚合
  static Future<Map<String, dynamic>> diningKaitaiList(int wenxunId) async {
    return post('/api/canyinorder/kaitaiList', {
      'wenxun_id': wenxunId,
    });
  }

  /// 堂食订单退款（v3.3.83）：整单/部分；需权限密码
  static Future<Map<String, dynamic>> diningOrderRefund({
    required int wenxunId,
    required int orderId,
    required String reason,
    required String password,
    double amount = 0,
  }) {
    return post('/api/canyinorder/refund', {
      'wenxun_id': wenxunId,
      'order_id': orderId,
      'reason': reason,
      'operator_id': Session.staffId,
      'password': password,
      if (amount > 0) 'refund_amount': amount,
    });
  }

  /// 退款订单列表（堂食+收银+小程序统一退款记录，v3.3.83）
  static Future<List> refundList(int wenxunId) async {
    final r = await post('/api/canyinorder/refundList', {'wenxun_id': wenxunId});
    if ('${r['code']}' == '200') return (r['data']?['list'] ?? []) as List;
    throw ApiError('${r['msg'] ?? '获取退款订单失败'}');
  }

  /// 充值订单列表（会员充值流水，v3.3.83）
  static Future<List> chongzhiList(int wenxunId) async {
    final r = await post('/api/canyinorder/chongzhiList', {'wenxun_id': wenxunId});
    if ('${r['code']}' == '200') return (r['data']?['list'] ?? []) as List;
    throw ApiError('${r['msg'] ?? '获取充值订单失败'}');
  }

  /// 今日充值统计（交班页，v3.3.173）：收银端充值流水（wx_vip_chongzhika）
  /// 返回 {count: 笔数, cash: 现金充值, scan: 扫码充值}
  static Future<Map<String, dynamic>> chongzhiStats(int wenxunId) async {
    final r = await post('/api/canyinorder/chongzhiStats', {'wenxun_id': wenxunId});
    if ('${r['code']}' == '200') {
      final d = r['data'];
      return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
    }
    throw ApiError('${r['msg'] ?? '获取充值统计失败'}');
  }
}

class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}
