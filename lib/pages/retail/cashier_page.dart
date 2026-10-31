import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/cloud_printer.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/voice.dart';
import '../../ui/no_code_goods.dart';
import '../../ui/vip_recharge.dart';
import '../../ui/widgets.dart';

/// 零售版 · 收银点单页（触摸屏优化版）
/// 左：分类栏 | 中：商品网格 | 右：加宽购物车 + 大按钮结算
/// 所有可点区域 ≥ 48px，适配安卓触摸收银一体机
class RetailCashierPage extends StatefulWidget {
  const RetailCashierPage({super.key});
  @override
  State<RetailCashierPage> createState() => _RetailCashierPageState();
}

class _CartLine {
  final Map goods;
  int num;
  _CartLine(this.goods, this.num);
}

class _RetailCashierPageState extends State<RetailCashierPage> {
  List cats = [];
  List goods = [];
  int selectedCat = -1; // -1 全部
  String keyword = '';
  bool loading = true;
  String? error;

  final List<_CartLine> cart = [];
  Map? vip; // 选中的会员

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final r = await Api.goodsAll(Session.wenxunId);
      if (!mounted) return;
      setState(() {
        cats = r['cat'] ?? [];
        goods = r['goods'] ?? [];
        loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.message; });
    }
  }

  List get filtered {
    Iterable g = goods;
    if (selectedCat > 0) {
      g = g.where((x) => '${x['cat_id']}' == '$selectedCat');
    }
    if (keyword.isNotEmpty) {
      g = g.where((x) => '${x['title']}'.contains(keyword));
    }
    return g.toList();
  }

  double get total => cart.fold(0, (s, l) => s + _price(l.goods) * l.num);
  int get count => cart.fold(0, (s, l) => s + l.num);

  double _price(Map g) => double.tryParse('${g['amount'] ?? g['price'] ?? 0}') ?? 0;

  /// 商品图片候选地址（按优先级依次尝试，全部失败显示占位图）
  List<String> _imgUrls(Map g) {
    final raw = '${g['goods_image'] ?? ''}'.trim();
    final out = <String>[];
    void add(String? u) {
      final s = (u ?? '').trim();
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    // 接口给的主/备地址
    add('${g['goods_image_url']}');
    add('${g['goods_image_url_alt']}');
    // 本地兜底：相对路径按两种规则拼
    if (raw.isNotEmpty && !raw.startsWith('http')) {
      final p = raw.startsWith('/') ? raw : '/$raw';
      add('https://shop.wx-zf.com/goods$p');
      add('https://shop.wx-zf.com$p');
    } else if (raw.startsWith('http')) {
      add(raw);
    }
    return out;
  }

  /// 下单/打印用的单张图片地址
  String _img(Map g) {
    final l = _imgUrls(g);
    return l.isEmpty ? '' : l.first;
  }

  bool _hasSpecs(Map g) => g['specs'] is List && (g['specs'] as List).isNotEmpty;

  /// 购物车行唯一键：商品 id + 规格 id（多规格同一商品多个 SKU 并存）
  String _cartKey(Map g) => '${g['id']}_${g['sku_id'] ?? ''}';

  void _add(Map g, {int qty = 1}) {
    final key = _cartKey(g);
    final i = cart.indexWhere((l) => _cartKey(l.goods) == key);
    if (i > -1) {
      cart[i].num += qty;
    } else {
      cart.add(_CartLine(g, qty));
    }
    setState(() {});
  }

  /// 点击商品：多规格弹规格组合弹窗，单规格直接加购
  Future<void> _tapGoods(Map g) async {
    if (_hasSpecs(g)) {
      final sku = await showDialog<Map>(
        context: context,
        builder: (_) => RetailSkuPickerDialog(goods: g, imgs: _imgUrls(g)),
      );
      if (sku == null || !mounted) return;
      _add({
        'id': g['id'],
        'sku_id': sku['id'],
        'title': '${g['title']}·${sku['name']}',
        'amount': sku['amount'],
        'guige': '${sku['name']}',
        'goods_image': g['goods_image'] ?? '',
        'goods_image_url': g['goods_image_url'] ?? '',
        'goods_image_url_alt': g['goods_image_url_alt'] ?? '',
      });
      return;
    }
    _add(g);
  }

  void _dec(_CartLine l) {
    l.num--;
    if (l.num <= 0) cart.remove(l);
    setState(() {});
  }

  void _clearCart() {
    if (cart.isEmpty) return;
    setState(() { cart.clear(); vip = null; });
  }

  /// 无码商品：手输名称/单价/数量，直接加入购物车
  Future<void> _noCodeGoods() async {
    final r = await showDialog<Map>(
      context: context,
      builder: (_) => const NoCodeGoodsDialog(title: '无码商品'),
    );
    if (r == null || !mounted) return;
    _add({
      // 每次生成唯一 id：同名单价不同也各占一行，后端 goods_id 强转 int 得 0
      'id': 'custom_${DateTime.now().millisecondsSinceEpoch}',
      'title': r['name'],
      'amount': r['amount'],
      'guige': '',
    }, qty: r['num']);
  }

  // ==================== 结算收款 ====================
  Future<void> _checkout() async {
    if (cart.isEmpty) return;
    final t = total;
    // 未选会员时不出现「会员支付」，避免误点
    final methods = ['现金', '微信支付', '支付宝', if (vip != null) '会员支付'];
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => RetailPayDialog(total: t, vip: vip, methods: methods),
    );
    if (picked == null || !mounted) return;

    final cartPayload = cart.map((l) => {
      'id': l.goods['id'],
      'name': l.goods['title'],
      'price': _price(l.goods),
      'quantity': l.num,
      'guige': '${l.goods['guige'] ?? ''}',
      'image': _img(l.goods),
    }).toList();

    // 会员余额支付：校验余额 → 后端扣款（联拓富会员走联拓富真实扣款）+ 落单
    if (picked == '会员支付') {
      final bal = _vipBalance();
      if (bal < t) {
        toast(context, '会员余额不足（¥${Fmt.money(bal)}），请先充值', error: true);
        return;
      }
      loadingDialog(context, '会员扣款中…');
      try {
        final r = await Api.memberPay(
          wenxunId: Session.wenxunId,
          vipId: int.tryParse('${vip!['id']}') ?? 0,
          phone: '${vip!['phone'] ?? ''}',
          total: t,
          originalTotal: t,
          cart: cartPayload,
          totalCount: count,
        );
        if (!mounted) return;
        Navigator.pop(context); // loading
        if ('${r['code']}' != '200') {
          toast(context, '${r['msg'] ?? '会员扣款失败'}', error: true);
          return;
        }
        final orderNo = '${r['order_number'] ?? r['order_id'] ?? ''}';
        CloudPrinter.print(CloudPrinter.retailReceipt(
          orderNo: orderNo, payMethod: picked, total: t,
          cart: cart.map((l) => {'name': l.goods['title'], 'price': _price(l.goods), 'quantity': l.num}).toList(),
        )).catchError((_) => <String, dynamic>{});
        _clearCart();
        showDialog(context: context, builder: (_) => _SuccessDialog(orderNo: orderNo, total: t, method: picked));
      } on ApiError catch (e) {
        if (mounted) Navigator.pop(context);
        toast(context, e.message, error: true);
      }
      return;
    }

    loadingDialog(context, '创建订单…');
    try {
      final r = await Api.retailOrderAdd(
        wenxunId: Session.wenxunId,
        renyuanId: Session.staffId,
        total: t,
        paymentMethod: picked,
        vipId: vip == null ? 0 : int.tryParse('${vip!['id']}') ?? 0,
        cart: cartPayload,
      );
      if (!mounted) return;
      Navigator.pop(context);
      final orderNo = '${r['orderNumber'] ?? r['order_number'] ?? ''}';

      // 云打印（异步，不阻塞收银）
      CloudPrinter.print(CloudPrinter.retailReceipt(
        orderNo: orderNo, payMethod: picked, total: t,
        cart: cart.map((l) => {'name': l.goods['title'], 'price': _price(l.goods), 'quantity': l.num}).toList(),
      )).catchError((_) => <String, dynamic>{});

      _clearCart();
      showDialog(context: context, builder: (_) => _SuccessDialog(orderNo: orderNo, total: t, method: picked));
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  /// 会员可用余额（现金余额 + 赠送余额）
  double _vipBalance() {
    if (vip == null) return 0;
    final a = double.tryParse('${vip!['amount'] ?? 0}') ?? 0;
    final g = double.tryParse('${vip!['gift_balance'] ?? 0}') ?? 0;
    return a + g;
  }

  /// 充值后刷新会员余额（按手机号回查，保持余额/积分最新）
  Future<void> _refreshVip() async {
    if (vip == null) return;
    final phone = '${vip!['phone'] ?? ''}';
    if (phone.isEmpty) return;
    try {
      final list = await Api.vipSearch(Session.wenxunId, phone);
      if (!mounted) return;
      for (final v in list) {
        if ('${v['id']}' == '${vip!['id']}') {
          setState(() => vip = v as Map);
          return;
        }
      }
    } on ApiError {
      // 查询失败不影响收银
    }
  }

  /// 收银台给选中会员充值
  Future<void> _rechargeVip() async {
    if (vip == null) return;
    final r = await showVipRechargeDialog(context, vip: vip!);
    if (r == null || !mounted) return;
    toast(context, '充值成功 ¥${Fmt.money(r['amount'])}（送 ¥${Fmt.money(r['gift'])}）');
    await _refreshVip();
  }

  // ==================== 选会员 ====================
  Future<void> _pickVip() async {
    final picked = await showDialog<Map>(context: context, builder: (_) => const RetailVipPickerDialog());
    if (picked != null) setState(() => vip = picked);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _topBar(),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
              : error != null
                  ? _errorView()
                  : Row(
                      children: [
                        _catRail(),
                        Expanded(child: _goodsGrid()),
                        _cartPanel(),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _topBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Row(children: [
        const Text('收银', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
        const SizedBox(width: 20),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: TextField(
            onChanged: (v) => setState(() => keyword = v.trim()),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              hintText: '搜索商品名称',
              prefixIcon: const Icon(Icons.search, size: 22),
              suffixIcon: keyword.isEmpty ? null : GestureDetector(
                onTap: () => setState(() => keyword = ''),
                child: const Icon(Icons.close, size: 20),
              ),
            ),
          ),
        ),
        const Spacer(),
        // 无码商品（扫码枪扫不到的商品手动录入）
        InkWell(
          onTap: _noCodeGoods,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF2ED),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: PosTheme.accent.withOpacity(0.4)),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.keyboard_outlined, size: 20, color: PosTheme.accent),
              SizedBox(width: 8),
              Text('无码商品', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.accent)),
            ]),
          ),
        ),
        const SizedBox(width: 14),
        _clock(),
      ]),
    );
  }

  Widget _clock() {
    final n = DateTime.now();
    final t = '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}  ${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: PosTheme.line)),
      child: Text(t, style: const TextStyle(fontSize: 14, color: PosTheme.textSub)),
    );
  }

  Widget _errorView() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(error!, style: const TextStyle(color: PosTheme.red)),
      const SizedBox(height: 12),
      BigButton('重新加载', onTap: _load, width: 160, height: 52),
    ]));
  }

  // 分类栏（加宽 + 大点击区）
  Widget _catRail() {
    final all = [{'id': -1, 'title': '全部'}, ...cats];
    return Container(
      width: 124,
      color: Colors.white,
      child: ListView.builder(
        itemCount: all.length,
        itemBuilder: (_, i) {
          final c = all[i];
          final on = selectedCat == c['id'];
          return InkWell(
            onTap: () => setState(() => selectedCat = c['id']),
            child: Container(
              height: 58,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? const Color(0xFFFFF2ED) : Colors.transparent,
                border: Border(left: BorderSide(color: on ? PosTheme.accent : Colors.transparent, width: 4)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('${c['title']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, color: on ? PosTheme.accent : PosTheme.textMain, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
              ),
            ),
          );
        },
      ),
    );
  }

  // 商品网格（卡片加大，触摸友好）
  Widget _goodsGrid() {
    final list = filtered;
    if (list.isEmpty) return const EmptyView('该分类暂无在售商品', icon: Icons.storefront);
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180, mainAxisSpacing: 14, crossAxisSpacing: 14, childAspectRatio: 0.8,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) => _goodsCard(list[i]),
    );
  }

  Widget _goodsCard(Map g) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _tapGoods(g),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: PosTheme.line)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: RetailGoodsImage(urls: _imgUrls(g)),
                  ),
                  if (_hasSpecs(g))
                    Positioned(
                      top: 6, right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(color: PosTheme.accent, borderRadius: BorderRadius.circular(6)),
                        child: const Text('多规格', style: TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text('${g['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
            const SizedBox(height: 3),
            Text('¥${Fmt.money(_price(g))}', style: const TextStyle(fontSize: 17, color: PosTheme.accent, fontWeight: FontWeight.w800)),
          ]),
        ),
      ),
    );
  }

  // 购物车（加宽 440，触摸友好）
  Widget _cartPanel() {
    return Container(
      width: 440,
      color: Colors.white,
      child: Column(
        children: [
          // 会员条（加高）
          InkWell(
            onTap: _pickVip,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: PosTheme.line))),
              child: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(color: PosTheme.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                  child: Icon(vip == null ? Icons.person_add_alt : Icons.person, size: 22, color: PosTheme.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: vip == null
                      ? const Text('点击选择会员（可选）', style: TextStyle(fontSize: 15, color: PosTheme.textSub))
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${vip!['name'] ?? vip!['phone']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          Text('余额 ¥${Fmt.money(vip!['amount'])}  积分 ${vip!['score'] ?? 0}', style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
                        ]),
                ),
                if (vip != null) ...[
                  InkWell(
                    onTap: _rechargeVip,
                    borderRadius: BorderRadius.circular(9),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF2ED),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: PosTheme.accent.withOpacity(0.4)),
                      ),
                      child: const Text('充值', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => setState(() => vip = null),
                    borderRadius: BorderRadius.circular(16),
                    child: const SizedBox(width: 32, height: 32, child: Icon(Icons.close, size: 20, color: PosTheme.textHint)),
                  ),
                ] else
                  const Icon(Icons.chevron_right, size: 22, color: PosTheme.textHint),
              ]),
            ),
          ),
          // 明细（行高加大）
          Expanded(
            child: cart.isEmpty
                ? const EmptyView('点击左侧商品加入购物车', icon: Icons.shopping_cart_outlined)
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: cart.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 18, endIndent: 18, color: PosTheme.line),
                    itemBuilder: (_, i) {
                      final l = cart[i];
                      final guige = '${l.goods['guige'] ?? ''}'.trim();
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        child: Row(children: [
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${l.goods['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 3),
                            Text(guige.isNotEmpty
                                ? '规格：$guige · ¥${Fmt.money(_price(l.goods))}'
                                : '¥${Fmt.money(_price(l.goods))}', style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
                          ])),
                          _stepper(l),
                          SizedBox(width: 72, child: Text('¥${Fmt.money(_price(l.goods) * l.num)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                        ]),
                      );
                    },
                  ),
          ),
          // 底部结算（大按钮）
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: PosTheme.line))),
            child: Column(children: [
              Row(children: [
                Text('共 $count 件', style: const TextStyle(fontSize: 14.5, color: PosTheme.textSub)),
                const Spacer(),
                Text('合计 ', style: const TextStyle(fontSize: 15, color: PosTheme.textSub)),
                Text('¥${Fmt.money(total)}', style: const TextStyle(fontSize: 30, color: PosTheme.accent, fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 62,
                    child: BigButton('清空', onTap: cart.isEmpty ? null : _clearCart, color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 62),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 2,
                  child: BigButton('收款 ¥${Fmt.money(total)}', onTap: cart.isEmpty ? null : _checkout, height: 62),
                ),
              ]),
            ]),
          ),
        ],
      ),
    );
  }

  // 步进器（44px 大触摸区）
  Widget _stepper(_CartLine l) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: PosTheme.line), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: () => _dec(l),
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(9)),
          child: Container(width: 46, height: 46, alignment: Alignment.center, child: const Icon(Icons.remove, size: 20, color: PosTheme.textSub)),
        ),
        Container(
          width: 44, height: 46, alignment: Alignment.center,
          decoration: const BoxDecoration(border: Border(left: BorderSide(color: PosTheme.line), right: BorderSide(color: PosTheme.line))),
          child: Text('${l.num}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        InkWell(
          onTap: () => setState(() => l.num++),
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(9)),
          child: Container(width: 46, height: 46, alignment: Alignment.center, child: const Icon(Icons.add, size: 20, color: PosTheme.accent)),
        ),
      ]),
    );
  }
}

// ==================== 收款弹窗（大屏触摸版：支付方式大块 + 数字键盘） ====================
class RetailPayDialog extends StatefulWidget {
  final double total;
  final Map? vip;
  final List<String> methods;
  const RetailPayDialog({required this.total, required this.methods, this.vip});
  @override
  State<RetailPayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<RetailPayDialog> {
  String? method;
  String received = ''; // 现金实收（数字键盘输入）
  final icons = {
    '现金': Icons.payments_outlined,
    '微信支付': Icons.chat,
    '支付宝': Icons.account_balance_wallet_outlined,
    '会员支付': Icons.badge_outlined,
  };
  final colors = {
    '现金': PosTheme.green,
    '微信支付': PosTheme.green,
    '支付宝': PosTheme.blue,
    '会员支付': PosTheme.accent,
  };

  // 映射缺失时给个兜底，避免再有 null 断言把整个收款弹窗打崩
  IconData _iconOf(String m) => icons[m] ?? Icons.payments_outlined;
  Color _colorOf(String m) => colors[m] ?? PosTheme.textSub;

  double get receivedVal => double.tryParse(received) ?? 0;
  double get change => (receivedVal - widget.total).clamp(0, double.maxFinite);

  void _key(String k) {
    setState(() {
      if (k == 'C') {
        received = '';
      } else if (k == '<') {
        if (received.isNotEmpty) received = received.substring(0, received.length - 1);
      } else if (k == '.') {
        if (!received.contains('.')) received += '.';
      } else {
        // 整数最多 6 位、小数最多 2 位
        final dot = received.indexOf('.');
        if (dot == -1) {
          if (received.length < 6) received += k;
        } else if (received.length - dot - 1 < 2) {
          received += k;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 660,
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 标题行
          Row(children: [
            const Text('收款', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const Spacer(),
            const Text('应收 ', style: TextStyle(fontSize: 16, color: PosTheme.textSub)),
            Text('¥${Fmt.money(widget.total)}', style: const TextStyle(fontSize: 34, color: PosTheme.accent, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 20),
          // 支付方式（2x2 大块）
          Row(children: [
            for (int i = 0; i < widget.methods.length; i++) ...[
              if (i > 0) const SizedBox(width: 14),
              Expanded(child: _methodTile(widget.methods[i])),
            ]
          ]),
          const SizedBox(height: 18),
          if (method == '现金') ...[
            // 实收 + 找零
            Row(children: [
              Expanded(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('顾客实收', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
                  const SizedBox(height: 4),
                  Text(received.isEmpty ? '¥ 0.00' : '¥ $received',
                      style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: PosTheme.textMain)),
                ]),
              )),
              const SizedBox(width: 14),
              Expanded(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(color: const Color(0xFFF0FFF6), borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('找零', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
                  const SizedBox(height: 4),
                  Text('¥${Fmt.money(change)}', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: PosTheme.green)),
                ]),
              )),
            ]),
            const SizedBox(height: 14),
            // 快捷金额
            Row(children: [
              for (final v in [50.0, 100.0, 200.0, widget.total]) ...[
                Expanded(child: InkWell(
                  onTap: () => setState(() => received = Fmt.money(v)),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    height: 52, alignment: Alignment.center,
                    decoration: BoxDecoration(border: Border.all(color: PosTheme.line), borderRadius: BorderRadius.circular(10)),
                    child: Text(v == widget.total ? '刚好' : '¥${v.toInt()}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.textMain)),
                  ),
                )),
                const SizedBox(width: 10),
              ]
            ]),
            const SizedBox(height: 14),
            // 数字键盘
            _keypad(),
          ] else if (method != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 30),
              alignment: Alignment.center,
              child: Column(children: [
                Icon(_iconOf(method!), size: 56, color: _colorOf(method!)),
                const SizedBox(height: 12),
                Text(method == '会员支付'
                        ? '将从「${widget.vip?['name'] ?? widget.vip?['phone'] ?? ''}」余额扣除 ¥${Fmt.money(widget.total)}'
                        : '请顾客使用$method扫码支付',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: PosTheme.textSub)),
                const SizedBox(height: 6),
                Text(
                    method == '会员支付'
                        ? '当前余额 ¥${Fmt.money((double.tryParse('${widget.vip?['amount'] ?? 0}') ?? 0) + (double.tryParse('${widget.vip?['gift_balance'] ?? 0}') ?? 0))}'
                        : '确认到账后点击下方「确认收款」',
                    style: const TextStyle(fontSize: 13, color: PosTheme.textHint)),
              ]),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 30),
              alignment: Alignment.center,
              child: const Text('请先选择收款方式', style: TextStyle(fontSize: 15, color: PosTheme.textHint)),
            ),
          ],
          const SizedBox(height: 20),
          // 大按钮
          Row(children: [
            Expanded(child: SizedBox(
              height: 64,
              child: BigButton('取消', onTap: () => Navigator.pop(context), color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 64),
            )),
            const SizedBox(width: 14),
            Expanded(flex: 2, child: BigButton('确认收款 ¥${Fmt.money(widget.total)}',
                onTap: method == null ? null : () => Navigator.pop(context, method), height: 64)),
          ]),
        ]),
      ),
    );
  }

  Widget _methodTile(String m) {
    final on = method == m;
    final disabled = m == '会员支付' && widget.vip == null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: disabled ? null : () => setState(() => method = m),
      child: Container(
        height: 84,
        decoration: BoxDecoration(
          color: on ? _colorOf(m).withOpacity(0.1) : const Color(0xFFF7F8FA),
          border: Border.all(color: on ? _colorOf(m) : Colors.transparent, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(_iconOf(m), size: 30, color: disabled ? PosTheme.textHint : _colorOf(m)),
          const SizedBox(height: 6),
          Text(m + (disabled ? '（未选会员）' : ''),
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: disabled ? PosTheme.textHint : PosTheme.textMain)),
        ]),
      ),
    );
  }

  Widget _keypad() {
    const keys = [
      ['1', '2', '3', '<'],
      ['4', '5', '6', 'C'],
      ['7', '8', '9', '.'],
    ];
    return Column(children: [
      for (int r = 0; r < 3; r++)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            for (int c = 0; c < 4; c++) ...[
              Expanded(child: _keyBtn(keys[r][c])),
              if (c < 3) const SizedBox(width: 10),
            ]
          ]),
        ),
      Row(children: [
        Expanded(flex: 2, child: _keyBtn('0')),
        const SizedBox(width: 10),
        Expanded(child: _keyBtn('.')),
        const SizedBox(width: 10),
        Expanded(child: _keyBtn('<')),
      ]),
    ]);
  }

  Widget _keyBtn(String k) {
    final isClear = k == 'C';
    return InkWell(
      onTap: () => _key(k),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: isClear ? const Color(0xFFFFF0EF) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: k == '<'
              ? const Icon(Icons.backspace_outlined, size: 22, color: PosTheme.textSub)
              : k == 'C'
                  ? const Text('清空', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.red))
                  : Text(k, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: PosTheme.textMain)),
        ),
      ),
    );
  }
}

// ==================== 选会员弹窗（大屏触摸版） ====================
class RetailVipPickerDialog extends StatefulWidget {
  const RetailVipPickerDialog();
  @override
  State<RetailVipPickerDialog> createState() => _VipPickerDialogState();
}

class _VipPickerDialogState extends State<RetailVipPickerDialog> {
  List list = [];
  bool loading = true;
  String kw = '';

  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String kw) async {
    setState(() => loading = true);
    try {
      final r = kw.isEmpty
          ? await Api.vipList(Session.wenxunId)
          : await Api.vipSearch(Session.wenxunId, kw);
      if (!mounted) return;
      setState(() { list = r; loading = false; });
    } on ApiError {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 560, height: 600,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
            child: Row(children: [
              const Text('选择会员', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const Spacer(),
              InkWell(
                onTap: () => Navigator.pop(context),
                borderRadius: BorderRadius.circular(18),
                child: const SizedBox(width: 36, height: 36, child: Icon(Icons.close, size: 24, color: PosTheme.textHint)),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
            child: TextField(
              autofocus: true,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                hintText: '手机号 / 姓名 搜索后回车',
                prefixIcon: const Icon(Icons.search, size: 22),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onSubmitted: (v) => _load(v.trim()),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator(color: PosTheme.accent))
                : list.isEmpty
                    ? const EmptyView('未找到会员')
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final v = list[i];
                          final nm = '${v['name'] ?? ''}'.trim();
                          final ph = '${v['phone'] ?? ''}'.trim();
                          return ListTile(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            leading: CircleAvatar(radius: 22, backgroundColor: PosTheme.accent.withOpacity(0.12), child: const Icon(Icons.person, color: PosTheme.accent)),
                            title: Text(nm.isEmpty ? (ph.isEmpty ? '未命名会员' : ph) : '$nm  $ph', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                            subtitle: Text('余额 ¥${Fmt.money(v['amount'])}  积分 ${v['score'] ?? 0}', style: const TextStyle(fontSize: 13)),
                            onTap: () => Navigator.pop(context, v),
                          );
                        },
                      ),
          ),
        ]),
      ),
    );
  }
}

// ==================== 多规格 SKU 选择弹窗（大屏触摸版 · 规格自由组合） ====================
/// 有规格分组（spec_groups）时：每个维度选一项，自动匹配 SKU，底部显示价格并加购；
/// 分组缺失时退化为 SKU 列表平铺模式。
class RetailSkuPickerDialog extends StatefulWidget {
  final Map goods;
  final List<String> imgs;
  const RetailSkuPickerDialog({required this.goods, required this.imgs});
  @override
  State<RetailSkuPickerDialog> createState() => _SkuPickerDialogState();
}

class _SkuPickerDialogState extends State<RetailSkuPickerDialog> {
  final Map<int, int> selected = {}; // 维度id -> 规格值id

  List get _specs => (widget.goods['specs'] as List?) ?? [];
  List get _groups => (widget.goods['spec_groups'] as List?) ?? [];
  bool get _groupMode => _groups.isNotEmpty;

  /// "3+67" / "19,67,22" → [3,67]
  static List<int> _parseIds(dynamic raw) {
    final out = <int>[];
    for (final p in '${raw ?? ''}'.split(RegExp(r'[+,.，]'))) {
      final v = int.tryParse(p.trim());
      if (v != null && v > 0) out.add(v);
    }
    return out;
  }

  List<int> get _selIds => selected.values.toList()..sort();

  /// 当前组合匹配到的 SKU（值集合完全一致才算命中）
  Map? get _matched {
    if (_groupMode && selected.length != _groups.length) return null;
    for (final s in _specs) {
      final ids = _parseIds(s['value_ids']);
      if (ids.length == _selIds.length && ids.toSet().containsAll(_selIds)) return s as Map;
    }
    return null;
  }

  // ---------- 平铺模式（无分组时的兜底） ----------
  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 780,
        constraints: const BoxConstraints(maxHeight: 720),
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(),
          const SizedBox(height: 20),
          Flexible(
            child: _groupMode ? _groupBody() : _flatBody(),
          ),
        ]),
      ),
    );
  }

  Widget _header() {
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 88, height: 88,
          child: RetailGoodsImage(urls: widget.imgs, iconSize: 36),
        ),
      ),
      const SizedBox(width: 18),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${widget.goods['title']}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(_groupMode ? '请选择各维度规格，自由组合' : '请选择规格', style: const TextStyle(fontSize: 14.5, color: PosTheme.textSub)),
      ])),
      InkWell(
        onTap: () => Navigator.pop(context),
        borderRadius: BorderRadius.circular(20),
        child: const SizedBox(width: 40, height: 40, child: Icon(Icons.close, size: 26, color: PosTheme.textHint)),
      ),
    ]);
  }

  // ---------- 组合模式 ----------
  Widget _groupBody() {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Flexible(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _groups.length,
          itemBuilder: (_, i) {
            final g = _groups[i] as Map;
            final did = int.tryParse('${g['id']}') ?? 0;
            final vals = (g['values'] as List?) ?? [];
            return Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${g['title'] ?? '规格'}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final v in vals) _valueChip(did, v as Map)],
                ),
              ]),
            );
          },
        ),
      ),
      _bottomBar(),
    ]);
  }

  Widget _valueChip(int did, Map v) {
    final vid = int.tryParse('${v['id']}') ?? 0;
    final on = selected[did] == vid;
    return InkWell(
      onTap: () => setState(() {
        if (on) {
          selected.remove(did);
        } else {
          selected[did] = vid;
        }
      }),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minWidth: 96, minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        decoration: BoxDecoration(
          color: on ? PosTheme.accent : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? PosTheme.accent : PosTheme.line, width: 1.5),
        ),
        child: Text('${v['name'] ?? ''}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: on ? Colors.white : PosTheme.textMain)),
      ),
    );
  }

  Widget _bottomBar() {
    final m = _matched;
    final out = m != null && (int.tryParse('${m['stock'] ?? 0}') ?? 0) <= 0;
    return Container(
      padding: const EdgeInsets.only(top: 16),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: PosTheme.line))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              m == null
                  ? (selected.isEmpty ? '已选 ${selected.length}/${_groups.length} 项规格' : '该组合暂无此规格，请重新选择')
                  : '${m['name']}  ·  ${out ? '已售罄' : '库存 ${m['stock']}'}',
              style: TextStyle(fontSize: 14.5, color: m == null ? PosTheme.textHint : PosTheme.textSub),
            ),
            const SizedBox(height: 4),
            Text('¥${Fmt.money(m == null ? (widget.goods['amount'] ?? 0) : m['amount'])}',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: m == null || out ? PosTheme.textHint : PosTheme.accent)),
          ]),
        ),
        const SizedBox(width: 18),
        SizedBox(
          width: 240, height: 66,
          child: BigButton(
            '加入购物车',
            onTap: (m == null || out) ? null : () => Navigator.pop(context, m),
            height: 66,
          ),
        ),
      ]),
    );
  }

  // ---------- 平铺模式（兜底） ----------
  Widget _flatBody() {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Flexible(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: _specs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, i) {
            final s = _specs[i] as Map;
            final stock = int.tryParse('${s['stock'] ?? 0}') ?? 0;
            final out = stock <= 0;
            return InkWell(
              onTap: out ? null : () => Navigator.pop(context, s),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  color: out ? const Color(0xFFF7F8FA) : const Color(0xFFFFF7F4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: out ? PosTheme.line : PosTheme.accent.withOpacity(0.35)),
                ),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${s['name'] ?? '默认规格'}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: out ? PosTheme.textHint : PosTheme.textMain)),
                    const SizedBox(height: 3),
                    Text(out ? '已售罄' : '库存 $stock', style: const TextStyle(fontSize: 13, color: PosTheme.textHint)),
                  ])),
                  Text('¥${Fmt.money(s['amount'])}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: out ? PosTheme.textHint : PosTheme.accent)),
                  const SizedBox(width: 16),
                  Container(
                    width: 52, height: 52,
                    decoration: BoxDecoration(
                      color: out ? PosTheme.line : PosTheme.accent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.add, color: Colors.white, size: 26),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ==================== 商品图片（多地址依次尝试，全失败显示占位） ====================
class RetailGoodsImage extends StatefulWidget {
  final List<String> urls;
  final double iconSize;
  const RetailGoodsImage({required this.urls, this.iconSize = 32});
  @override
  State<RetailGoodsImage> createState() => _GoodsImageState();
}

class _GoodsImageState extends State<RetailGoodsImage> {
  int idx = 0;

  Widget _placeholder() => Container(
      color: const Color(0xFFF5F6F8),
      child: Icon(Icons.fastfood, color: PosTheme.textHint, size: widget.iconSize));

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty || idx >= widget.urls.length) return _placeholder();
    return Image.network(
      widget.urls[idx],
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) {
        // 当前地址加载失败 → 下一帧切换到候选列表里的下一个地址
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => idx++);
        });
        return _placeholder();
      },
    );
  }
}

// ==================== 收款成功弹窗（大屏触摸版） ====================
class _SuccessDialog extends StatefulWidget {
  final String orderNo;
  final double total;
  final String method;
  const _SuccessDialog({required this.orderNo, required this.total, required this.method});
  @override
  State<_SuccessDialog> createState() => _SuccessDialogState();
}

class _SuccessDialogState extends State<_SuccessDialog> {
  @override
  void initState() {
    super.initState();
    // 语音播报收款成功（设置页可关闭）
    VoiceService.instance.pay(widget.method, widget.total);
  }

  @override
  Widget build(BuildContext context) {
    final orderNo = widget.orderNo;
    final total = widget.total;
    final method = widget.method;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 92, height: 92,
            decoration: BoxDecoration(color: PosTheme.green.withOpacity(0.12), shape: BoxShape.circle),
            child: const Icon(Icons.check, size: 52, color: PosTheme.green),
          ),
          const SizedBox(height: 22),
          const Text('收款成功', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text('¥${Fmt.money(total)} · $method', style: const TextStyle(fontSize: 20, color: PosTheme.textSub)),
          if (orderNo.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('单号 $orderNo', style: const TextStyle(fontSize: 13.5, color: PosTheme.textHint)),
          ],
          const SizedBox(height: 8),
          const Text('小票已发送至云打印机', style: TextStyle(fontSize: 13.5, color: PosTheme.textHint)),
          const SizedBox(height: 26),
          SizedBox(
            width: 280,
            child: BigButton('继续收银', onTap: () => Navigator.pop(context), height: 56),
          ),
        ]),
      ),
    );
  }
}
