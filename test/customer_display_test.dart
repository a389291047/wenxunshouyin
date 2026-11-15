import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxun/core/customer_display.dart';

/// v3.3.210 副屏数据链路回归：
/// 1) 19877 被占时快照服务自动顺延端口，显示端探测能拉到数据
/// 2) 发布的快照会落地本地 JSON（HTTP 不通时副屏兜底显示）
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CustomerDisplay.stopServer();
    CustomerDisplay.enabled = false;
  });

  test('端口被占自动顺延 + HTTP 拉取', () async {
    // 占住 19877（模拟其他软件/残留进程）
    final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, 19877);
    addTearDown(blocker.close);

    CustomerDisplay.enabled = true;
    final ok = await CustomerDisplay.startServer();
    expect(ok, isTrue, reason: '19877 被占也应能顺延到 19878~19886 启动');
    expect(CustomerDisplay.port, greaterThan(19877));
    expect(CustomerDisplay.running, isTrue);

    CustomerDisplay.publish(shop: '测试店', total: 12.5, items: [
      {'n': '面包', 'q': '1', 'u': '', 'p': 8.8, 'a': 8.8},
    ]);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    addTearDown(client.close);
    final m = await CustomerDisplay.fetch(client);
    expect(m, isNotNull);
    expect(m!['shop'], '测试店');
    expect((m['items'] as List).length, 1);
    await CustomerDisplay.stopServer();
  });

  test('发布快照落地本地 JSON，可离线兜底读取', () async {
    CustomerDisplay.publish(shop: '兜底店', total: 3.0, items: const []);
    // 发布有 800ms 节流，等一拍再发布一次确保落地
    await Future<void>.delayed(const Duration(milliseconds: 900));
    CustomerDisplay.publish(shop: '兜底店', total: 3.0, items: const []);
    final local = await CustomerDisplay.readLocal();
    expect(local, isNotNull);
    expect(local!['shop'], '兜底店');
    expect(local['ts'], greaterThan(0));
  });
}
