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
    final blocker = await HttpServer.bind(InternetAddress.anyIPv4, 19877);
    addTearDown(blocker.close);

    CustomerDisplay.enabled = true;
    final ok = await CustomerDisplay.startServer();
    expect(ok, isTrue, reason: '19877 被占也应能启动（顺延或回落 loopback）');
    expect(CustomerDisplay.running, isTrue);

    CustomerDisplay.publish(shop: '测试店', vipId: 42, total: 12.5, items: [
      {'n': '面包', 'q': '1', 'u': '', 'p': 8.8, 'a': 8.8},
    ]);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    addTearDown(client.close);
    // 本机通道（Windows 第二实例用）
    final m = await CustomerDisplay.fetch(client);
    expect(m, isNotNull);
    expect(m!['shop'], '测试店');
    expect(m['vip_id'], 42);
    expect((m['items'] as List).length, 1);
    // 远程通道（安卓平板客显用）
    final r = await CustomerDisplay.fetchRemote(client, '127.0.0.1', CustomerDisplay.port);
    expect(r, isNotNull);
    expect(r!['shop'], '测试店');
    await CustomerDisplay.stopServer();
  });

  test('件数口径：称重行按 1 件计，不把公斤数当件数', () {
    CustomerDisplay.publish(shop: '烘焙熟食店', total: 5053.4, items: [
      {'n': '面包', 'q': '5.000', 'u': 'kg', 'p': 8.8, 'a': 44.0},
      {'n': '桃酥', 'q': '253.000', 'u': 'kg', 'p': 19.8, 'a': 5009.4},
      {'n': '矿泉水', 'q': '3', 'u': '', 'p': 2.0, 'a': 6.0},
    ]);
    expect(CustomerDisplay.latestTs, greaterThan(0));
    // v3.3.211 回归：称重 2 行各算 1 件 + 按件 3 = 5，而不是 5+253+3=261
    final raw = CustomerDisplay.latestSnapshot;
    expect(raw['count'], 5);
  });

  test('发布快照落地本地 JSON，可离线兜底读取', () async {
    CustomerDisplay.publish(shop: '兜底店', total: 3.0, items: const []);
    // 发布有 800ms 节流，等一拍再发布一次确保落地
    await Future<void>.delayed(const Duration(milliseconds: 900));
    CustomerDisplay.publish(shop: '兜底店', total: 3.0, items: const []);
    await Future<void>.delayed(const Duration(milliseconds: 100)); // 等异步落地
    final local = await CustomerDisplay.readLocal();
    expect(local, isNotNull);
    expect(local!['shop'], '兜底店');
    expect(local['ts'], greaterThan(0));
  });
}
