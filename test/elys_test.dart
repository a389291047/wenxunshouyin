import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/elys.dart';

/// 无限聚核（服务零售）纯逻辑测试 —— 按文档成功判断与错误处理口径
/// 文档：https://doc.elys.cn/index.md
void main() {
  group('maskKey：API Key 掩码回显', () {
    test('常规 Key：前4后4保留，中间打码', () {
      expect(ElysLogic.maskKey('abcd1234efgh5678'), 'abcd****5678');
    });
    test('短 Key（<=8位）全打码', () {
      expect(ElysLogic.maskKey('abc12345'), '****');
      expect(ElysLogic.maskKey('ab'), '****');
    });
    test('空 Key 返回空串', () {
      expect(ElysLogic.maskKey(''), '');
    });
  });

  group('classify：错误码分类（重试口径按文档）', () {
    test('成功：success=true', () {
      final r = ElysLogic.classify(success: true, code: 10000);
      expect(r.ok, isTrue);
      expect(r.retryable, isFalse);
      expect(r.already, isFalse);
      expect(r.rejected, isFalse);
    });

    test('已核销重放：code=10500 / errorCode=ALREADY_CONSUMED，不重试', () {
      final r1 = ElysLogic.classify(success: false, code: 10500);
      expect(r1.already, isTrue);
      expect(r1.retryable, isFalse);
      final r2 = ElysLogic.classify(success: false, code: 10001, errorCode: 'ALREADY_CONSUMED');
      expect(r2.already, isTrue);
      expect(r2.retryable, isFalse);
    });

    test('平台拒绝：errorCode=PLATFORM_REJECTED 或 code=10000+N，不重试', () {
      final r1 = ElysLogic.classify(success: false, code: 11006, errorCode: 'PLATFORM_REJECTED');
      expect(r1.rejected, isTrue);
      expect(r1.retryable, isFalse);
      final r2 = ElysLogic.classify(success: false, code: 11006);
      expect(r2.rejected, isTrue);
    });

    test('可重试：CONSUME_IN_PROGRESS / RESULT_UNKNOWN / SERVICE_UNAVAILABLE / PROVIDER_UNAVAILABLE', () {
      for (final ec in ['CONSUME_IN_PROGRESS', 'RESULT_UNKNOWN', 'SERVICE_UNAVAILABLE', 'PROVIDER_UNAVAILABLE']) {
        final r = ElysLogic.classify(success: false, code: 10001, errorCode: ec);
        expect(r.retryable, isTrue, reason: ec);
        expect(r.already, isFalse);
        expect(r.rejected, isFalse);
      }
    });

    test('其他错误：普通失败，不重试', () {
      final r = ElysLogic.classify(success: false, code: 10001, errorCode: 'INVALID_PARAM');
      expect(r.ok, isFalse);
      expect(r.retryable, isFalse);
      expect(r.already, isFalse);
      expect(r.rejected, isFalse);
    });
  });

  group('fen2yuan：分转元显示', () {
    test('常规转换', () {
      expect(ElysLogic.fen2yuan(7990), '79.90');
      expect(ElysLogic.fen2yuan(13900), '139.00');
    });
    test('空值兜底 0.00', () {
      expect(ElysLogic.fen2yuan(null), '0.00');
    });
  });

  group('parsePrepare：预核销响应解析', () {
    test('字段映射与金额口径（payAmount/actualPayAmount 为分）', () {
      final m = ElysLogic.parsePrepare({
        'payAmount': 13900,
        'dealPrice': 139,
        'dealMarketPrice': 159,
        'actualPayAmount': 12900,
        'ticketName': '次数卡套餐',
        'dealId': '1816849307970587',
        'ticketInfo': '{"verifyToken":"t","encryptedCodes":["c"]}',
        'ticketData': '',
      });
      expect(m['ticketName'], '次数卡套餐');
      expect(m['dealId'], '1816849307970587');
      expect(m['payAmountText'], '139.00'); // 分→元
      expect(m['actualPayText'], '129.00');
      expect(m['marketPriceText'], '159'); // 元保持
      // ticketInfo 必须整段原文透传，不得修改
      expect(m['ticketInfo'], '{"verifyToken":"t","encryptedCodes":["c"]}');
    });

    test('actualPayAmount 为 null 时兜底', () {
      final m = ElysLogic.parsePrepare({
        'payAmount': 1000,
        'ticketName': 'x',
        'ticketInfo': 'k',
        'actualPayAmount': null,
        'dealMarketPrice': null,
      });
      expect(m['actualPayText'], '0.00');
      expect(m['marketPriceText'], '');
    });
  });

  group('parseVerify：核销响应解析', () {
    test('data[] 与 consumeCredential 一一对应', () {
      final r = ElysLogic.parseVerify({
        'success': true,
        'code': 10000,
        'wxdgOrderNo': 'w1',
        'consumeCredential': ['cred-1', 'cred-2'],
        'data': [
          {
            'orderId': '1093',
            'dealTitle': '畅玩5小时',
            'receiptCode': '180886072740962',
            'payAmount': 7990,
            'dealPrice': 79.9,
          },
          {
            'orderId': '1094',
            'dealTitle': '套餐B',
            'receiptCode': '180886072740963',
            'payAmount': 5000,
            'dealPrice': 50,
          },
        ],
      });
      expect(r['wxdgOrderNo'], 'w1');
      expect((r['rows'] as List).length, 2);
      expect((r['rows'] as List)[0]['dealTitle'], '畅玩5小时');
      expect((r['rows'] as List)[0]['receiptCode'], '180886072740962');
      expect((r['rows'] as List)[0]['payAmountText'], '79.90');
      expect((r['credentials'] as List), ['cred-1', 'cred-2']);
    });
  });

  group('parseCancel：撤销响应解析', () {
    test('全部成功 status=succeeded', () {
      final r = ElysLogic.parseCancel({
        'success': true,
        'data': [
          {'consumeCredential': 'c1', 'status': 'succeeded', 'message': '撤销成功'},
        ],
      });
      expect(r['allOk'], isTrue);
      expect((r['items'] as List)[0]['status'], 'succeeded');
    });
    test('部分失败 success=false', () {
      final r = ElysLogic.parseCancel({
        'success': false,
        'data': [
          {'consumeCredential': 'c1', 'status': 'succeeded', 'message': ''},
          {'consumeCredential': 'c2', 'status': 'unknown', 'message': '结果未知'},
        ],
      });
      expect(r['allOk'], isFalse);
      expect((r['items'] as List)[1]['status'], 'unknown');
    });
  });

  group('parseDeals：团购列表解析', () {
    test('字段映射（price 元、dealId 字符串化）', () {
      final rows = ElysLogic.parseDeals([
        {'dealId': 1816849307970587, 'title': '畅玩5小时', 'price': 79.9, 'marketPrice': 92,
         'endDate': '2026-12-31 23:59:59', 'saleChannelName': '美团', 'saleStatus': 2},
      ]);
      expect(rows.length, 1);
      expect(rows[0]['dealId'], '1816849307970587');
      expect(rows[0]['priceText'], '79.90');
      expect(rows[0]['title'], '畅玩5小时');
    });
  });
}
