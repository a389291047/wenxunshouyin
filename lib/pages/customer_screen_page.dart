import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:window_manager/window_manager.dart';

import '../core/api.dart';
import '../core/customer_display.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../ui/ocean_background.dart';

bool get _desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 副屏（客显）入口 v3.3.212
///
/// 两种运行方式：
/// 1. Windows 双屏收银机：同程序第二实例（--customer-display），本机回环取数据；
/// 2. 安卓平板 / 手机 / 第二台电脑：局域网连主收银机（remoteHost + remotePort）。
class CustomerScreenApp extends StatelessWidget {
  const CustomerScreenApp({
    super.key,
    this.windowMode = false,
    this.remoteHost,
    this.remotePort,
  });

  /// true = 独立窗口（单显示器调试/临时用）：右上角有关闭按钮
  final bool windowMode;

  /// 非空表示远程客显（安卓端连主收银机），走局域网 HTTP 拉快照
  final String? remoteHost;
  final int? remotePort;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '稳讯收银 · 客显屏',
      debugShowCheckedModeBanner: false,
      theme: PosTheme.light(),
      home: CustomerScreenPage(
        windowMode: windowMode,
        remoteHost: remoteHost,
        remotePort: remotePort,
      ),
    );
  }
}

class CustomerScreenPage extends StatefulWidget {
  const CustomerScreenPage({
    super.key,
    this.windowMode = false,
    this.remoteHost,
    this.remotePort,
  });

  final bool windowMode;
  final String? remoteHost;
  final int? remotePort;

  @override
  State<CustomerScreenPage> createState() => _CustomerScreenPageState();
}

class _CustomerScreenPageState extends State<CustomerScreenPage> {
  Map<String, dynamic> state = CustomerDisplay.empty();
  bool online = false; // 数据通道正常
  bool offlineCopy = false; // HTTP 不通，用本地快照兜底（仅本机模式）
  int? _okPort;
  Timer? _timer;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);

  // 会员激活码（v3.3.212）
  Uint8List? _qr;
  bool _qrLoading = false;
  String? _qrError;
  int _qrVipId = 0;
  DateTime _qrAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // 安卓端沉浸式全屏，顾客看不到状态栏
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _tick();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close(force: true);
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Future<void> _tick() async {
    Map<String, dynamic>? m;
    if (widget.remoteHost != null) {
      // 远程客显（安卓平板等）：直连主收银机的局域网快照服务
      m = await CustomerDisplay.fetchRemote(
          _client, widget.remoteHost!, widget.remotePort ?? CustomerDisplay.portBase);
      if (m != null && mounted) {
        setState(() {
          state = m!;
          online = true;
          offlineCopy = false;
        });
      } else if (mounted && online) {
        setState(() => online = false);
      }
    } else {
      // 本机模式：HTTP 优先，失败回落本地快照
      m = await CustomerDisplay.fetch(_client, preferPort: _okPort);
      if (m != null) {
        _okPort = CustomerDisplay.lastOkPort;
        if (!mounted) return;
        setState(() {
          state = m!;
          online = true;
          offlineCopy = false;
        });
      } else {
        final local = await CustomerDisplay.readLocal();
        if (local != null) {
          final ts = (local['ts'] as num?)?.toInt() ?? 0;
          final fresh =
              DateTime.now().millisecondsSinceEpoch - ts < 120000; // 2 分钟内有效
          final changed = ts != ((state['ts'] as num?)?.toInt() ?? 0);
          if (fresh && changed && mounted) {
            setState(() {
              state = local;
              online = false;
              offlineCopy = true;
            });
          }
        } else if (mounted && (online || offlineCopy)) {
          setState(() {
            online = false;
            offlineCopy = false;
          });
        }
      }
    }
    _syncQr();
  }

  /// 商户 ID：优先取主屏快照（安卓客显没登录也有），本机兜底 Session
  int get _vipId {
    final v = (state['vip_id'] as num?)?.toInt() ?? 0;
    return v > 0 ? v : Session.wenxunId;
  }

  void _syncQr() {
    final id = _vipId;
    if (id <= 0) return;
    final expired = DateTime.now().difference(_qrAt).inMinutes > 30;
    if (id == _qrVipId && _qr != null && !expired) return;
    if (id == _qrVipId && _qrLoading) return;
    _loadQr(id);
  }

  Future<void> _loadQr(int id) async {
    _qrVipId = id;
    setState(() {
      _qrLoading = true;
      _qrError = null;
    });
    try {
      final url = Uri.parse('${Api.base}/index/vip/qrcode?vip_id=$id&size=1200');
      final res = await http.get(url).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (res.statusCode == 200 && res.bodyBytes.length > 600) {
        setState(() {
          _qr = res.bodyBytes;
          _qrLoading = false;
          _qrAt = DateTime.now();
        });
      } else {
        setState(() {
          _qrLoading = false;
          _qrError = '二维码加载失败';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _qrLoading = false;
        _qrError = '网络异常，点击重试';
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

    return Scaffold(
      backgroundColor: const Color(0xFF06283A),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const OceanBackground(),
          // 轻压暗：保证卡片与白字对比度，又不遮挡海景
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.16),
                  Colors.black.withValues(alpha: 0.02),
                  Colors.black.withValues(alpha: 0.30),
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
              child: Column(
                children: [
                  _topBar(shop, count),
                  const SizedBox(height: 12),
                  Expanded(
                    child: LayoutBuilder(builder: (context, box) {
                      final wide = box.maxWidth >= 640; // 左右两卡布局；更窄（竖屏手机）才上下排
                      final gap = wide ? 18.0 : 14.0;
                      final qrCard = _qrCard(wide ? box.maxWidth * 0.30 : box.maxWidth);
                      final cartCard = _cartCard(items, count);
                      if (wide) {
                        final qrW = (box.maxWidth * 0.30).clamp(240.0, 430.0);
                        return Row(children: [
                          Expanded(child: cartCard),
                          SizedBox(width: gap),
                          SizedBox(width: qrW, child: qrCard),
                        ]);
                      }
                      // 竖屏（安卓平板/手机客显）：上下排，卡片同样留足间距
                      final qrH = (box.maxHeight * 0.44).clamp(230.0, 380.0);
                      return Column(children: [
                        Expanded(child: cartCard),
                        SizedBox(height: gap),
                        SizedBox(height: qrH, child: qrCard),
                      ]);
                    }),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===== 顶部：店名 / 同步状态 / 关闭 =====
  Widget _topBar(String shop, int count) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) {
        if (_desktop) windowManager.startDragging();
      },
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFF8A4C), Color(0xFFFF5B2E)],
            ),
            borderRadius: BorderRadius.circular(13),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF5B2E).withValues(alpha: 0.4),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(Icons.storefront, size: 24, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              shop.isEmpty ? '欢迎光临' : shop,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                shadows: [Shadow(color: Color(0x66000000), blurRadius: 10)],
              ),
            ),
            const SizedBox(height: 2),
            Row(children: [
              _statusDot(),
              const SizedBox(width: 6),
              Text(
                online
                    ? '消费明细 · 实时同步'
                    : offlineCopy
                        ? '快照同步中'
                        : widget.remoteHost != null
                            ? '正在连接主收银机…'
                            : '等待收银端连接…',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.white.withValues(alpha: 0.78),
                  shadows: const [Shadow(color: Color(0x55000000), blurRadius: 8)],
                ),
              ),
            ]),
          ]),
        ),
        if (widget.windowMode && _desktop)
          IconButton(
            tooltip: '关闭副屏',
            onPressed: () => windowManager.close(),
            icon: const Icon(Icons.close, color: Colors.white70, size: 20),
          ),
      ]),
    );
  }

  Widget _statusDot() {
    final color = online
        ? const Color(0xFF3DDC84)
        : offlineCopy
            ? const Color(0xFFFFC85A)
            : const Color(0xFFFF8A80);
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: 6)],
      ),
    );
  }

  // ===== 左卡：购物车 =====
  Widget _cartCard(List<Map<String, dynamic>> items, int count) {
    final total = (state['total'] as num?)?.toDouble() ?? 0;
    final discount = (state['discount'] as num?)?.toDouble() ?? 0;
    final payable = (state['payable'] as num?)?.toDouble() ?? total;

    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final s = (w / 760).clamp(0.82, 1.35);
      return Container(
        decoration: _cardDecoration(),
        child: Column(children: [
          // 卡头
          Padding(
            padding: EdgeInsets.fromLTRB(20 * s, 16 * s, 20 * s, 12 * s),
            child: Row(children: [
              Icon(Icons.shopping_bag_outlined,
                  size: 20 * s, color: const Color(0xFF1E8FA8)),
              SizedBox(width: 8 * s),
              Text('购物车',
                  style: TextStyle(
                      fontSize: 17 * s,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF16222F))),
              const Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 4 * s),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E8FA8).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('$count 件',
                    style: TextStyle(
                        fontSize: 13 * s,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF14708A))),
              ),
            ]),
          ),
          Divider(height: 1, color: Colors.black.withValues(alpha: 0.06)),
          // 明细
          Expanded(
            child: items.isEmpty
                ? _welcome(s)
                : ListView.separated(
                    padding: EdgeInsets.symmetric(horizontal: 18 * s, vertical: 6 * s),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => Divider(
                        height: 1,
                        color: Colors.black.withValues(alpha: 0.05)),
                    itemBuilder: (_, i) => _line(items[i], s),
                  ),
          ),
          // 结算条
          Container(
            padding: EdgeInsets.fromLTRB(20 * s, 12 * s, 20 * s, 14 * s),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFFF7FBFD),
                  const Color(0xFFEFF7FA),
                ],
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(20 * s)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('合计 ¥${total.toStringAsFixed(2)}',
                      style: TextStyle(
                          fontSize: 13 * s,
                          color: const Color(0xFF6B7686),
                          fontWeight: FontWeight.w600)),
                  if (discount > 0) ...[
                    SizedBox(height: 3 * s),
                    Text('优惠 -¥${discount.toStringAsFixed(2)}',
                        style: TextStyle(
                            fontSize: 12.5 * s,
                            color: const Color(0xFFE5484D),
                            fontWeight: FontWeight.w600)),
                  ],
                ]),
              ),
              Text('应收',
                  style: TextStyle(fontSize: 14 * s, color: const Color(0xFF6B7686))),
              SizedBox(width: 8 * s),
              Text('¥${payable.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: 38 * s,
                      fontWeight: FontWeight.w900,
                      color: const Color(0xFFFF5B2E),
                      height: 1.0)),
            ]),
          ),
        ]),
      );
    });
  }

  Widget _line(Map<String, dynamic> it, double s) {
    final name = '${it['n'] ?? ''}';
    final qty = '${it['q'] ?? ''}';
    final unit = '${it['u'] ?? ''}';
    final price = (it['p'] as num?)?.toDouble() ?? 0;
    final amount = (it['a'] as num?)?.toDouble() ?? 0;
    // 一行三段等分平均分配（v3.3.216）：品名 / 数量×单价 / 小计，
    // 全部弹性伸缩，超长省略号，任何一段都不会被挤压
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 9 * s),
      child: Row(children: [
        Expanded(
          flex: 2,
          child: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 19 * s,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF16222F))),
        ),
        SizedBox(width: 10 * s),
        Expanded(
          flex: 2,
          child: Text('$qty$unit × ${price.toStringAsFixed(2)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 14 * s, color: const Color(0xFF6B7686))),
        ),
        SizedBox(width: 10 * s),
        Expanded(
          flex: 1,
          child: Text('¥${amount.toStringAsFixed(2)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 19 * s,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF16222F))),
        ),
      ]),
    );
  }

  Widget _welcome(double s) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 82 * s,
          height: 82 * s,
          decoration: BoxDecoration(
            color: const Color(0xFF1E8FA8).withValues(alpha: 0.08),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.shopping_basket_outlined,
              size: 40 * s, color: const Color(0xFF1E8FA8).withValues(alpha: 0.5)),
        ),
        SizedBox(height: 14 * s),
        Text('欢迎光临',
            style: TextStyle(
                fontSize: 26 * s,
                fontWeight: FontWeight.w800,
                color: const Color(0xFF16222F))),
        SizedBox(height: 6 * s),
        Text('扫商品后，明细会实时显示在这里',
            style: TextStyle(fontSize: 13.5 * s, color: const Color(0xFF9AA4B2))),
      ]),
    );
  }

  // ===== 右卡：会员激活码 =====
  Widget _qrCard(double w) {
    final s = (w / 340).clamp(0.8, 1.3);
    return Container(
      decoration: _cardDecoration(),
      padding: EdgeInsets.fromLTRB(16 * s, 16 * s, 16 * s, 14 * s),
      child: Column(children: [
        Row(children: [
          Container(
            width: 34 * s,
            height: 34 * s,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFF8A4C), Color(0xFFFF5B2E)],
              ),
              borderRadius: BorderRadius.circular(10 * s),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFFFF5B2E).withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4)),
              ],
            ),
            child: Icon(Icons.qr_code_2, size: 19 * s, color: Colors.white),
          ),
          SizedBox(width: 9 * s),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('会员激活码',
                  style: TextStyle(
                      fontSize: 15 * s,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF16222F))),
              Text('微信扫一扫 · 免费注册会员',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11 * s, color: const Color(0xFF9AA4B2))),
            ]),
          ),
        ]),
        SizedBox(height: 12 * s),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: _qrFrame(s),
            ),
          ),
        ),
        SizedBox(height: 10 * s),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 6 * s),
          decoration: BoxDecoration(
            color: const Color(0xFFFF5B2E).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.card_giftcard,
                size: 13 * s, color: const Color(0xFFFF5B2E)),
            SizedBox(width: 5 * s),
            Text('注册会员 · 充值享赠送',
                style: TextStyle(
                    fontSize: 11.5 * s,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFFD9421C))),
          ]),
        ),
      ]),
    );
  }

  /// 二维码：渐变描边 + 白底留白（保证可扫） + 四角定位标记
  Widget _qrFrame(double s) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // 柔光
        Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(colors: [
              const Color(0xFFFFC9A8).withValues(alpha: 0.45),
              const Color(0xFFFFC9A8).withValues(alpha: 0),
            ]),
            shape: BoxShape.circle,
          ),
        ),
        Padding(
          padding: EdgeInsets.all(6 * s),
          child: LayoutBuilder(builder: (context, box) {
            return Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFFC79A), Color(0xFFFF7A45), Color(0xFF2AA5BE)],
                ),
                borderRadius: BorderRadius.circular(18 * s),
              ),
              padding: EdgeInsets.all(3 * s),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16 * s),
                ),
                padding: EdgeInsets.all(8 * s),
                child: _qrContent(s),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _qrContent(double s) {
    if (_qr != null) {
      return Image.memory(
        _qr!,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
      );
    }
    if (_qrLoading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    // 未取到：给收银员/顾客一个可点的重试入口
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.qr_code_2,
            size: 44 * s, color: const Color(0xFFB9C2CE)),
        SizedBox(height: 8 * s),
        Text(_qrError ?? (_vipId <= 0 ? '等待收银端信息…' : '二维码加载中…'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5 * s, color: const Color(0xFF9AA4B2))),
        if (_qrError != null && _vipId > 0) ...[
          SizedBox(height: 6 * s),
          InkWell(
            onTap: () => _loadQr(_vipId),
            child: Text('点击重试',
                style: TextStyle(
                    fontSize: 12 * s,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFFFF5B2E))),
          ),
        ],
      ]),
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: Colors.white.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: 0.65)),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF04202F).withValues(alpha: 0.28),
          blurRadius: 28,
          offset: const Offset(0, 12),
        ),
      ],
    );
  }
}
