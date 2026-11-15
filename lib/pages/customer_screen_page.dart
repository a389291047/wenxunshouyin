import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/customer_display.dart';
import '../core/theme.dart';

/// 副屏（客显）界面 v3.3.209
///
/// 运行在同一个程序的第二个进程里，数据来自主程序本机 127.0.0.1:19877/state，
/// 只读展示：店名、商品明细（名称/数量/单价/金额）、件数、合计/优惠/应收。
/// 不提供任何操作按钮，顾客碰不到收银数据。
class CustomerScreenApp extends StatelessWidget {
  const CustomerScreenApp({super.key, this.windowMode = false});

  /// true = 独立窗口（单显示器调试/临时用）：标题区可拖动，右上角有关闭按钮
  final bool windowMode;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '稳讯收银 · 客显屏',
      debugShowCheckedModeBanner: false,
      theme: PosTheme.light(),
      home: CustomerScreenPage(windowMode: windowMode),
    );
  }
}

class CustomerScreenPage extends StatefulWidget {
  const CustomerScreenPage({super.key, this.windowMode = false});

  final bool windowMode;

  @override
  State<CustomerScreenPage> createState() => _CustomerScreenPageState();
}

class _CustomerScreenPageState extends State<CustomerScreenPage> with WindowListener {
  Map<String, dynamic> state = CustomerDisplay.empty();
  bool online = false; // HTTP 通道正常（主程序快照服务可达）
  bool offlineCopy = false; // HTTP 不通，正在用本地快照兜底显示
  int? _okPort; // 记住可用的端口，优先复用
  Timer? _timer;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _tick();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _timer?.cancel();
    _client.close(force: true);
    super.dispose();
  }

  Future<void> _tick() async {
    // 通道 1：HTTP（主程序快照服务，端口自动探测）
    final m = await CustomerDisplay.fetch(_client, preferPort: _okPort);
    if (m != null) {
      _okPort = CustomerDisplay.lastOkPort;
      if (!mounted) return;
      setState(() {
        state = m;
        online = true;
        offlineCopy = false;
      });
      return;
    }
    // 通道 2：本地快照兜底（主程序发布时同步落地的 JSON，跨进程共享）
    final local = await CustomerDisplay.readLocal();
    if (local != null) {
      final ts = (local['ts'] as num?)?.toInt() ?? 0;
      final fresh = DateTime.now().millisecondsSinceEpoch - ts < 120000; // 2 分钟内视为有效
      final changed = ts != ((state['ts'] as num?)?.toInt() ?? 0);
      if (fresh && changed) {
        if (!mounted) return;
        setState(() {
          state = local;
          online = false;
          offlineCopy = true;
        });
        return;
      }
    }
    if (mounted && (online || offlineCopy)) {
      setState(() {
        online = false;
        offlineCopy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = (state['items'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final shop = '${state['shop'] ?? ''}';
    final count = (state['count'] as num?)?.toInt() ?? 0;
    final total = (state['total'] as num?)?.toDouble() ?? 0;
    final discount = (state['discount'] as num?)?.toDouble() ?? 0;
    final payable = (state['payable'] as num?)?.toDouble() ?? total;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      body: SafeArea(
        child: Column(
          children: [
            // ===== 顶部：店名 + 状态 =====
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              child: Container(
              padding: const EdgeInsets.fromLTRB(26, 18, 26, 16),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1E2430), Color(0xFF31394A)],
                ),
              ),
              child: Row(children: [
                const Icon(Icons.storefront, size: 26, color: Colors.white70),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(shop.isEmpty ? '欢迎光临' : shop,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white)),
                    const SizedBox(height: 3),
                    Text(online
                            ? '消费明细 · 实时同步'
                            : offlineCopy
                                ? '快照同步中（直连被拦截，已走本地通道）'
                                : '等待收银端连接…',
                        style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.62))),
                  ]),
                ),
                if (!online)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: offlineCopy
                          ? const Color(0xFF2FBF71).withValues(alpha: 0.16)
                          : const Color(0xFFF5A623).withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: offlineCopy
                              ? const Color(0xFF2FBF71).withValues(alpha: 0.5)
                              : const Color(0xFFF5A623).withValues(alpha: 0.5)),
                    ),
                    child: Text(offlineCopy ? '快照同步' : '未连接',
                        style: TextStyle(
                            fontSize: 12,
                            color: offlineCopy ? const Color(0xFF9FE7C0) : const Color(0xFFFFD08A),
                            fontWeight: FontWeight.w700)),
                  )
                else
                  Text('$count 件',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white70)),
                if (widget.windowMode)
                  IconButton(
                    tooltip: '关闭副屏',
                    onPressed: () => windowManager.close(),
                    icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                  ),
              ]),
            ),
            ),
            // ===== 明细清单 =====
            Expanded(
              child: items.isEmpty
                  ? _welcome()
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(22, 14, 22, 14),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFE8EAEE)),
                      itemBuilder: (_, i) {
                        final it = items[i];
                        final name = '${it['n'] ?? ''}';
                        final qty = '${it['q'] ?? ''}';
                        final unit = '${it['u'] ?? ''}';
                        final price = (it['p'] as num?)?.toDouble() ?? 0;
                        final amount = (it['a'] as num?)?.toDouble() ?? 0;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          child: Row(children: [
                            Expanded(
                              child: Text(name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 132,
                              child: Text('$qty$unit × ${price.toStringAsFixed(2)}',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 16, color: PosTheme.textSub)),
                            ),
                            const SizedBox(width: 14),
                            SizedBox(
                              width: 116,
                              child: Text('¥${amount.toStringAsFixed(2)}',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                            ),
                          ]),
                        );
                      },
                    ),
            ),
            // ===== 底部：合计 / 优惠 / 应收 =====
            Container(
              padding: const EdgeInsets.fromLTRB(26, 16, 26, 18),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xFFE8EAEE))),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('共 $count 件商品',
                        style: const TextStyle(fontSize: 15, color: PosTheme.textSub)),
                    if (discount > 0) ...[
                      const SizedBox(height: 6),
                      Text('优惠 -¥${discount.toStringAsFixed(2)}',
                          style: const TextStyle(fontSize: 16, color: Color(0xFFE5484D), fontWeight: FontWeight.w600)),
                    ],
                  ]),
                ),
                const Text('应收', style: TextStyle(fontSize: 18, color: PosTheme.textSub)),
                const SizedBox(width: 12),
                Text('¥${payable.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontSize: 46, fontWeight: FontWeight.w900, color: PosTheme.accent, height: 1.0)),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _welcome() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.shopping_basket_outlined, size: 76, color: PosTheme.accent.withValues(alpha: 0.25)),
        const SizedBox(height: 16),
        const Text('欢迎光临', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        const Text('收银员扫码 / 称重后，商品会在这里实时显示',
            style: TextStyle(fontSize: 15, color: PosTheme.textHint)),
      ]),
    );
  }
}
