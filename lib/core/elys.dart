/// 无限聚核（服务零售）· 纯逻辑层（v3.3.271）
/// 文档：https://doc.elys.cn/index.md —— 成功判断/错误口径/字段映射的唯一事实来源
/// API Key 只存服务端（tp8 代理转发），本层不含任何网络请求，全部可单测。
library;

class ElysLogic {
  ElysLogic._();

  // ==================== Key 掩码回显 ====================

  /// API Key 掩码：前4后4保留，中间 ****；<=8位或空全打码/空串
  static String maskKey(String key) {
    final k = key.trim();
    if (k.isEmpty) return '';
    if (k.length <= 8) return '****';
    return '${k.substring(0, 4)}****${k.substring(k.length - 4)}';
  }

  // ==================== 错误分类（重试口径按文档） ====================

  /// 仅这四个 errorCode 可用「原请求原参数」自动重试；ALREADY_CONSUMED /
  /// PLATFORM_REJECTED 绝不重试（提示操作员核对券码/门店）
  static const retryableErrors = {
    'CONSUME_IN_PROGRESS',
    'RESULT_UNKNOWN',
    'SERVICE_UNAVAILABLE',
    'PROVIDER_UNAVAILABLE',
  };

  /// 分类结果
  /// ok=业务成功；already=已核销重放（不要重试、不要重复发放权益）；
  /// rejected=平台拒绝（券不存在/已用/过期/不适用本店，不要重试）；
  /// retryable=可用原请求重试
  static ({bool ok, bool already, bool rejected, bool retryable}) classify({
    required bool success,
    required int code,
    String errorCode = '',
  }) {
    if (success) return (ok: true, already: false, rejected: false, retryable: false);
    final ec = errorCode.trim().toUpperCase();
    final already = code == 10500 || ec == 'ALREADY_CONSUMED';
    final rejected = ec == 'PLATFORM_REJECTED' || (!already && code > 10000 && code != 10001);
    final retryable = !already && !rejected && retryableErrors.contains(ec);
    return (ok: false, already: already, rejected: rejected, retryable: retryable);
  }

  // ==================== 金额口径 ====================

  /// 分 → 元字符串（payAmount / actualPayAmount 用）：7990 分 → 79.90 元
  static String fen2yuan(Object? fen) {
    final v = (double.tryParse('${fen ?? ''}') ?? 0) / 100;
    return v.toStringAsFixed(2);
  }

  // ==================== 预核销 prepare ====================

  /// prepare 响应 data 解析：ticketInfo 整段原文透传（禁止解析/修改/重序列化）
  static Map<String, dynamic> parsePrepare(Map data) {
    return {
      'ticketName': '${data['ticketName'] ?? ''}',
      'dealId': '${data['dealId'] ?? ''}',
      'payAmountText': fen2yuan(data['payAmount']),
      'actualPayText': fen2yuan(data['actualPayAmount']),
      'dealPriceText': data['dealPrice'] == null ? '' : '${data['dealPrice']}',
      'marketPriceText': data['dealMarketPrice'] == null ? '' : '${data['dealMarketPrice']}',
      'ticketInfo': '${data['ticketInfo'] ?? ''}', // 原文透传，核销时原样回传
      'ticketData': '${data['ticketData'] ?? ''}',
    };
  }

  // ==================== 核销 verify ====================

  /// 核销成功响应解析：rows 与 consumeCredential 一一对应（撤销按凭证）
  static Map<String, dynamic> parseVerify(Map resp) {
    final rows = <Map<String, dynamic>>[];
    final list = (resp['data'] ?? []) as List;
    for (final d in list) {
      if (d is Map) {
        rows.add({
          'orderId': '${d['orderId'] ?? ''}',
          'dealId': '${d['dealId'] ?? ''}',
          'dealTitle': '${d['dealTitle'] ?? ''}',
          'receiptCode': '${d['receiptCode'] ?? ''}',
          'payAmountText': fen2yuan(d['payAmount']),
          'dealPriceText': '${d['dealPrice'] ?? ''}',
        });
      }
    }
    return {
      'wxdgOrderNo': '${resp['wxdgOrderNo'] ?? ''}',
      'rows': rows,
      'credentials': ((resp['consumeCredential'] ?? []) as List)
          .map((e) => '$e')
          .where((e) => e.isNotEmpty)
          .toList(),
    };
  }

  // ==================== 撤销 cancel ====================

  /// 撤销响应解析：success 仅全部成功为 true；unknown 不代表失败，需查券核实
  static Map<String, dynamic> parseCancel(Map resp) {
    final items = <Map<String, dynamic>>[];
    final list = (resp['data'] ?? []) as List;
    for (final d in list) {
      if (d is Map) {
        items.add({
          'consumeCredential': '${d['consumeCredential'] ?? ''}',
          'status': '${d['status'] ?? ''}',
          'message': '${d['message'] ?? ''}',
        });
      }
    }
    final allOk = resp['success'] == true;
    return {'allOk': allOk, 'items': items};
  }

  // ==================== 团购列表 deals ====================

  /// 团购列表解析：dealId 统一字符串化（美团=平台 dealId，抖音=SKU ID）
  static List<Map<String, dynamic>> parseDeals(List list) {
    final rows = <Map<String, dynamic>>[];
    for (final d in list) {
      if (d is Map) {
        rows.add({
          'dealId': '${d['dealId'] ?? ''}',
          'title': '${d['title'] ?? ''}',
          'priceText': (double.tryParse('${d['price'] ?? ''}') ?? 0).toStringAsFixed(2),
          'marketPriceText': '${d['marketPrice'] ?? ''}',
          'endDate': '${d['endDate'] ?? ''}',
          'channel': '${d['saleChannelName'] ?? ''}',
          'saleStatus': d['saleStatus'] ?? 0,
        });
      }
    }
    return rows;
  }
}
