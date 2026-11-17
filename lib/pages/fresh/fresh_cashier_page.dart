import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/customer_display.dart';
import '../../core/api.dart';
import '../../core/cart_prefs.dart';
import '../../core/cash_drawer.dart';
import '../../core/cloud_printer.dart';
import '../../core/pay_methods.dart';
import '../../core/print_prefs.dart';
import '../../core/search_focus.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../ui/vip_recharge.dart';
import '../../ui/cart_line_dialog.dart';
import '../../ui/widgets.dart';
import '../../ui/xyf_scan_pay.dart';
import '../retail/cashier_page.dart'
    show RetailPayDialog, RetailVipPickerDialog, RetailSkuPickerDialog, RetailGoodsImage;

/// 生鲜版 · 生鲜收银页（hangye=3 专用界面）
/// 后端与零售共用：商品分类 wx_goodscat / 商品 wx_goods / 会员等级 wx_viplv / 会员 wx_vip
/// 界面按生鲜场景美化：绿色主题、渐变顶栏、大图商品卡、按「斤/份」展示
class FreshCashierPage extends StatefulWidget {
  const FreshCashierPage({super.key});
  @override
  State<FreshCashierPage> createState() => _FreshCashierPageState();
}

/// 生鲜版主题色（生鲜绿）
class FreshColors {
  static const accent = Color(0xFF16A34A); // 主绿
  static const accentDeep = Color(0xFF0E7A38); // 深绿
  static const light = Color(0xFFEAF9F0); // 选中浅绿底
  static const banner = [Color(0xFF2BB673), Color(0xFF16984F)]; // 顶栏渐变
}

class _CartLine {
  final Map goods;
  int num;
  double? price; // 单行改价（null = 按商品原价）v3.3.205
  String note = ''; // 单行备注（随小票打印）v3.3.205
  _CartLine(this.goods, this.num);
  double get listPrice => double.tryParse('${goods['amount'] ?? goods['price'] ?? 0}') ?? 0;

  /// 成交单价：有改价用改价，否则用资料价
  double get unitPrice => price ?? listPrice;

  /// 称重商品（v3.3.214：落单 payload 必须带 unit，否则后端拒绝称重单）
  bool get byWeight => '${goods['sell_type'] ?? 0}' == '1';
  String get unit {
    if (!byWeight) return '';
    final u = '${goods['danwei'] ?? ''}'.trim();
    return u.isEmpty ? 'kg' : u;
  }
}

class _FreshCashierPageState extends State<FreshCashierPage> {
  List cats = [];
  List goods = [];
  int selectedCat = -1; // -1 全部
  String keyword = '';
  bool loading = true;
  String? error;

  // 搜索框始终聚焦（v3.3.187，扫码枪适配）
  final searchKeeper = SearchFocusKeeper();

  final List<_CartLine> cart = [];
  Map? vip;

  Timer? _cdTimer; // 副屏（客显）推送（v3.3.209）

  @override
  void initState() {
    super.initState();
    searchKeeper.init();
    _cdTimer = Timer.periodic(const Duration(milliseconds: 600), (_) => _publishCd());
    _load();
  }

  /// 副屏快照：名称 / 数量 / 单位 / 单价 / 金额 + 合计
  void _publishCd() {
    if (!mounted || !CustomerDisplay.active) return;
    CustomerDisplay.ensureServer(); // 懒启动：端口被占/服务没跑时自动补（v3.3.210）
    CustomerDisplay.publish(
      shop: Session.shopName,
      vipId: Session.wenxunId,
      total: double.parse(total.toStringAsFixed(2)),
      items: cart.map((l) {
        final byWeight = '${l.goods['sell_type'] ?? 0}' == '1';
        final u = '${l.goods['danwei'] ?? ''}'.trim();
        return <String, dynamic>{
          'n': '${l.goods['title'] ?? ''}',
          'q': byWeight ? l.num.toStringAsFixed(3) : '${l.num}',
          'u': byWeight ? (u.isEmpty ? 'kg' : u) : '',
          'p': double.parse(l.unitPrice.toStringAsFixed(2)),
          'a': double.parse((l.unitPrice * l.num).toStringAsFixed(2)),
        };
      }).toList(),
    );
  }

  @override
  void dispose() {
    _cdTimer?.cancel();
    searchKeeper.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final r = await Api.goodsAll(Session.wenxunId); // 与零售共用商品接口
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

  double get total => cart.fold<double>(0, (s, l) => s + l.unitPrice * l.num);
  int get count => cart.fold(0, (s, l) => s + l.num);

  double _price(Map g) => double.tryParse('${g['amount'] ?? g['price'] ?? 0}') ?? 0;

  /// 商品图片候选地址（与零售一致的兜底规则）
  List<String> _imgUrls(Map g) {
    final raw = '${g['goods_image'] ?? ''}'.trim();
    final out = <String>[];
    void add(String? u) {
      final s = (u ?? '').trim();
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    add('${g['goods_image_url']}');
    add('${g['goods_image_url_alt']}');
    if (raw.isNotEmpty && !raw.startsWith('http')) {
      final p = raw.startsWith('/') ? raw : '/$raw';
      add('https://shop.wx-zf.com/goods$p');
      add('https://shop.wx-zf.com$p');
    } else if (raw.startsWith('http')) {
      add(raw);
    }
    return out;
  }

  String _img(Map g) {
    final l = _imgUrls(g);
    return l.isEmpty ? '' : l.first;
  }

  bool _hasSpecs(Map g) => g['specs'] is List && (g['specs'] as List).isNotEmpty;

  String _cartKey(Map g) => '${g['id']}_${g['sku_id'] ?? ''}';

  void _add(Map g) {
    final key = _cartKey(g);
    final i = cart.indexWhere((l) => _cartKey(l.goods) == key);
    if (i > -1) {
      cart[i].num++;
    } else {
      cart.add(_CartLine(g, 1));
    }
    setState(() {});
  }

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
    if (l.num <= 0) {
      _removeLine(l);
      return;
    }
    setState(() {});
  }

  // ==================== 单个商品操作（v3.3.205） ====================

  /// 改价前校验权限（设置里开启「改价需权限密码」才弹）
  Future<bool> _authPrice() async {
    if (!await CartPrefs.priceNeedPin()) return true;
    if (!mounted) return false;
    return showPinVerifyDialog(context,
        title: '改价需要权限密码', sub: '输入当前收银员的权限密码（与退款密码相同）');
  }

  /// 点购物车某行 → 改数量 / 改价 / 备注 / 删除
  Future<void> _lineEdit(_CartLine l) async {
    final guige = '${l.goods['guige'] ?? ''}'.trim();
    final r = await showCartLineDialog(
      context,
      title: '${l.goods['title']}',
      subtitle: guige.isEmpty ? '' : '规格 $guige',
      listPrice: l.listPrice,
      num: l.num.toDouble(),
      note: l.note,
      price: l.price,
      unit: _unit(l.goods),
      accent: FreshColors.accent,
      onNeedPriceAuth: _authPrice,
    );
    if (r == null || !mounted) return;
    if (r.deleted) {
      _removeLine(l);
      return;
    }
    setState(() {
      l.num = r.num.round() < 1 ? 1 : r.num.round();
      l.price = r.price;
      l.note = r.note;
    });
  }

  /// 删除单行商品（带 4 秒撤销）
  void _removeLine(_CartLine l) {
    final i = cart.indexOf(l);
    if (i < 0) return;
    setState(() => cart.removeAt(i));
    if (cart.isEmpty && vip != null) setState(() => vip = null);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
      content: Text('已删除「${l.goods['title']}」'),
      duration: const Duration(seconds: 4),
      // v3.3.206：同零售页，带 action 的 SnackBar 新版默认永久驻留，显式关闭
      persist: false,
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(
        label: '撤销',
        onPressed: () {
          if (!mounted) return;
          setState(() => cart.insert(i.clamp(0, cart.length), l));
        },
      ),
    ));
  }

  void _clearCart() {
    if (cart.isEmpty) return;
    setState(() { cart.clear(); vip = null; });
  }

  // ==================== 结算收款 ====================
  Future<void> _checkout() async {
    if (cart.isEmpty) return;
    final t = total;
    final order = await PayMethods.load();

    // ===== 快捷通道（v3.3.177 复用餐饮）：默认支付方式是微信/支付宝时，
    // 点「收款」直接弹付款码，扫码成功自动落单，全程零确认 =====
    final quick = order.isNotEmpty ? order.first : '';
    if (quick == '微信支付' || quick == '支付宝') {
      final quickNo = 'XYFR${DateTime.now().millisecondsSinceEpoch}'
          '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
      final pay = await showXyfScanPayDialog(context,
          amount: t, title: '扫码收款 · $quick', bizType: 'retail',
          orderNo: quickNo, moreLabel: '其他方式 → 完整收款');
      if (!mounted) return;
      if (pay != null && pay['more'] != true) {
        return _createPaidOrder(quick, t,
            xyfOrderNo: '${pay['orderNo'] ?? quickNo}',
            xyfChannel: int.tryParse('${pay['order']?['pay_channel'] ?? 0}') ?? 0);
      }
      // 取消扫码 或 点「其他方式」→ 继续走下面的完整弹窗
    }

    // 按商户「支付方式排序」展示（v3.3.176 全场景复用）
    final methods = ['现金', '扫码收款', '微信支付', '支付宝', if (vip != null) '会员支付']
      ..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    final picked = await showDialog<dynamic>(
      context: context,
      builder: (_) => RetailPayDialog(total: t, vip: vip, methods: methods),
    );
    if (picked == null || !mounted) return;
    // 微信/支付宝免确认直通（弹窗内点卡片直接扫码成功）会带回 Map（含支付流水），直接落单
    String pickedMethod;
    String xyfOrderNo = '';
    int xyfChannel = 0;
    if (picked is Map) {
      pickedMethod = '${picked['method']}';
      xyfOrderNo = '${picked['xyf_order_no'] ?? ''}';
      xyfChannel = (picked['xyf_channel'] as int?) ?? 0;
    } else {
      pickedMethod = picked;
    }
    // 扫码类支付：未带支付流水时弹付款码（扫码枪扫顾客付款码，微信/支付宝自动识别）
    // 预生成我方单号：支付流水与订单 pay_order_no 关联，退款按此原路退
    if (xyfOrderNo.isEmpty &&
        (pickedMethod == '扫码收款' || pickedMethod == '微信支付' || pickedMethod == '支付宝')) {
      final preNo = 'XYFR${DateTime.now().millisecondsSinceEpoch}'
          '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
      final pay = await showXyfScanPayDialog(context,
          amount: t,
          title: pickedMethod == '扫码收款' ? '扫码收款' : '扫码收款 · $pickedMethod',
          bizType: 'retail', orderNo: preNo);
      if (pay == null || !mounted) return;
      xyfOrderNo = '${pay['orderNo'] ?? preNo}';
      xyfChannel = int.tryParse('${pay['order']?['pay_channel'] ?? 0}') ?? 0;
    }
    await _createPaidOrder(pickedMethod, t,
        xyfOrderNo: xyfOrderNo, xyfChannel: xyfChannel);
  }

  /// 落单执行（v3.3.177 从 _checkout 拆出）：会员扣款 / 扫码 / 现金统一收口
  Future<void> _createPaidOrder(String picked, double t,
      {String xyfOrderNo = '', int xyfChannel = 0}) async {
    final cartPayload = cart.map((l) => {
      'id': l.goods['id'],
      'name': l.goods['title'],
      'price': l.unitPrice, // 单行改价后的成交价（v3.3.205）
      'quantity': l.num, // 按件为整数，称重为重量（3 位小数）
      'unit': l.byWeight ? l.unit : '', // 称重必带单位，后端强校验（v3.3.214）
      'guige': '${l.goods['guige'] ?? ''}',
      'image': _img(l.goods),
      'note': l.note, // 单行备注（小票打印用）
    }).toList();

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
        Navigator.pop(context);
        if ('${r['code']}' != '200') {
          toast(context, '${r['msg'] ?? '会员扣款失败'}', error: true);
          return;
        }
        final orderNo = '${r['order_number'] ?? r['order_id'] ?? ''}';
        _afterPaid(orderNo, picked, t);
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
        payOrderNo: xyfOrderNo,
        payChannel: xyfChannel,
      );
      if (!mounted) return;
      Navigator.pop(context);
      final orderNo = '${r['orderNumber'] ?? r['order_number'] ?? ''}';
      _afterPaid(orderNo, picked, t);
    } on ApiError catch (e) {
      if (mounted) Navigator.pop(context);
      toast(context, e.message, error: true);
    }
  }

  Future<void> _afterPaid(String orderNo, String method, double t) async {
    // 现金结算自动弹钱箱（v3.3.202，异步不阻塞收银）
    CashDrawer.autoOpen(method);
    if (await PrintPrefs.on('retail')) {
      final hasWeigh = cart.any((l) => l.byWeight);
      CloudPrinter.printRetail(
        CloudPrinter.retailReceipt(
          orderNo: orderNo, payMethod: method, total: t,
          cart: cart.map((l) => {'name': l.goods['title'], 'price': l.unitPrice, 'quantity': l.num, 'unit': l.byWeight ? l.unit : '', 'note': l.note}).toList(),
        ),
        alsoCloud: hasWeigh, // 称重订单本地出票后云打印机同步一份（v3.3.214）
      ).catchError((_) => <String, dynamic>{});
    }
    _clearCart();
    showDialog(context: context, builder: (_) => _FreshSuccessDialog(orderNo: orderNo, total: t, method: method));
  }

  double _vipBalance() {
    if (vip == null) return 0;
    final a = double.tryParse('${vip!['amount'] ?? 0}') ?? 0;
    final g = double.tryParse('${vip!['gift_balance'] ?? 0}') ?? 0;
    return a + g;
  }

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

  Future<void> _rechargeVip() async {
    if (vip == null) return;
    final r = await showVipRechargeDialog(context, vip: vip!);
    if (r == null || !mounted) return;
    toast(context, '充值成功 ¥${Fmt.money(r['amount'])}（送 ¥${Fmt.money(r['gift'])}）');
    await _refreshVip();
  }

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
              ? const Center(child: CircularProgressIndicator(color: FreshColors.accent))
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

  // ===== 生鲜绿渐变顶栏 =====
  Widget _topBar() {
    final n = DateTime.now();
    final t = '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}  ${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: FreshColors.banner,
        ),
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.18), borderRadius: BorderRadius.circular(11)),
          child: const Icon(Icons.eco, color: Colors.white, size: 24),
        ),
        const SizedBox(width: 12),
        const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('生鲜收银', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
          Text('称重 · 按份 · 按斤，扫码即收', style: TextStyle(fontSize: 11.5, color: Colors.white70)),
        ]),
        const SizedBox(width: 24),
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: TextField(
              focusNode: searchKeeper.node,
              onChanged: (v) => setState(() => keyword = v.trim()),
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                hintText: '搜索生鲜商品名称',
                hintStyle: const TextStyle(fontSize: 14, color: PosTheme.textHint),
                prefixIcon: const Icon(Icons.search, size: 22, color: FreshColors.accent),
                suffixIcon: keyword.isEmpty ? null : GestureDetector(
                  onTap: () => setState(() => keyword = ''),
                  child: const Icon(Icons.close, size: 20),
                ),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: Colors.white70, width: 2)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.16), borderRadius: BorderRadius.circular(20)),
          child: Text(t, style: const TextStyle(fontSize: 13.5, color: Colors.white)),
        ),
      ]),
    );
  }

  Widget _errorView() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(error!, style: const TextStyle(color: PosTheme.red)),
      const SizedBox(height: 12),
      BigButton('重新加载', onTap: _load, width: 160, height: 52),
    ]));
  }

  // ===== 分类栏（绿色选中态） =====
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
                color: on ? FreshColors.light : Colors.transparent,
                border: Border(left: BorderSide(color: on ? FreshColors.accent : Colors.transparent, width: 4)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('${c['title']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, color: on ? FreshColors.accentDeep : PosTheme.textMain, fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
              ),
            ),
          );
        },
      ),
    );
  }

  // ===== 商品网格（大图卡） =====
  Widget _goodsGrid() {
    final list = filtered;
    if (list.isEmpty) return const EmptyView('该分类暂无在售生鲜商品', icon: Icons.eco);
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190, mainAxisSpacing: 14, crossAxisSpacing: 14, childAspectRatio: 0.78,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) => _goodsCard(list[i]),
    );
  }

  Widget _goodsCard(Map g) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _tapGoods(g),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: PosTheme.line),
            boxShadow: [BoxShadow(color: FreshColors.accent.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: RetailGoodsImage(urls: _imgUrls(g)),
                  ),
                  if (_hasSpecs(g))
                    Positioned(
                      top: 6, right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(color: FreshColors.accent, borderRadius: BorderRadius.circular(6)),
                        child: const Text('多规格', style: TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text('${g['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Row(children: [
              Text('¥${Fmt.money(_price(g))}', style: const TextStyle(fontSize: 17, color: FreshColors.accent, fontWeight: FontWeight.w800)),
              const SizedBox(width: 3),
              Text('/${_unit(g)}', style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
              const Spacer(),
              Container(
                width: 30, height: 30,
                decoration: BoxDecoration(color: FreshColors.accent, borderRadius: BorderRadius.circular(9)),
                child: const Icon(Icons.add, color: Colors.white, size: 20),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  /// 单位：商品有 guige 备注时展示，否则默认「份」
  String _unit(Map g) {
    final u = '${g['unit'] ?? g['danwei'] ?? ''}'.trim();
    return u.isEmpty ? '份' : u;
  }

  // ===== 购物车 =====
  Widget _cartPanel() {
    return Container(
      width: 420,
      color: Colors.white,
      child: Column(
        children: [
          // 会员条
          InkWell(
            onTap: _pickVip,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: PosTheme.line))),
              child: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(color: FreshColors.light, borderRadius: BorderRadius.circular(20)),
                  child: Icon(vip == null ? Icons.person_add_alt : Icons.person, size: 22, color: FreshColors.accent),
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
                        color: FreshColors.light,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: FreshColors.accent.withOpacity(0.4)),
                      ),
                      child: const Text('充值', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: FreshColors.accentDeep)),
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
          // 操作提示（v3.3.205：购物车支持单行改数量/改价/备注/删除）
          if (cart.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
              color: const Color(0xFFFBFCFD),
              child: const Text('点商品行可改数量 / 改价 / 备注，点 × 删除单个商品',
                  style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            ),
          // 明细
          Expanded(
            child: cart.isEmpty
                ? const EmptyView('点击左侧生鲜商品加入购物车', icon: Icons.shopping_basket_outlined)
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: cart.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 18, endIndent: 18, color: PosTheme.line),
                    itemBuilder: (_, i) {
                      final l = cart[i];
                      final guige = '${l.goods['guige'] ?? ''}'.trim();
                      return InkWell(
                        onTap: () => _lineEdit(l), // 点行 = 改数量/改价/备注/删除（v3.3.205）
                        onLongPress: () => _lineEdit(l),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(
                                child: Text('${l.goods['title']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                              ),
                              if (l.price != null) ...[
                                const SizedBox(width: 5),
                                _lineTag('改价', FreshColors.accent),
                              ],
                              const SizedBox(width: 6),
                              Text('¥${Fmt.money(l.unitPrice * l.num)}', textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                              const SizedBox(width: 4),
                              InkWell(
                                onTap: () => _removeLine(l),
                                borderRadius: BorderRadius.circular(18),
                                child: const SizedBox(width: 30, height: 30, child: Icon(Icons.close, size: 17, color: PosTheme.textHint)),
                              ),
                            ]),
                            const SizedBox(height: 2),
                            Row(children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(
                                      guige.isNotEmpty
                                          ? '规格：$guige · ¥${Fmt.money(l.unitPrice)}'
                                          : '¥${Fmt.money(l.unitPrice)}/${_unit(l.goods)}${l.price != null ? '（原 ¥${Fmt.money(l.listPrice)}）' : ''}',
                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
                                  if (l.note.isNotEmpty)
                                    Text('备注：${l.note}', maxLines: 1, overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12, color: PosTheme.amber, fontWeight: FontWeight.w600)),
                                ]),
                              ),
                              _stepper(l),
                            ]),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
          // 底部结算
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: PosTheme.line))),
            child: Column(children: [
              Row(children: [
                Text('共 $count 件', style: const TextStyle(fontSize: 14.5, color: PosTheme.textSub)),
                const Spacer(),
                Text('合计 ', style: const TextStyle(fontSize: 15, color: PosTheme.textSub)),
                Text('¥${Fmt.money(total)}', style: const TextStyle(fontSize: 30, color: FreshColors.accent, fontWeight: FontWeight.w800)),
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
                  child: SizedBox(
                    height: 62,
                    child: BigButton('收款 ¥${Fmt.money(total)}', onTap: cart.isEmpty ? null : _checkout, height: 62,
                      color: FreshColors.accent),
                  ),
                ),
              ]),
            ]),
          ),
        ],
      ),
    );
  }

  // 行内小标签（改价等）
  Widget _lineTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: TextStyle(fontSize: 10.5, color: color, fontWeight: FontWeight.w700)),
    );
  }

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
          child: Container(width: 46, height: 46, alignment: Alignment.center, child: const Icon(Icons.add, size: 20, color: FreshColors.accent)),
        ),
      ]),
    );
  }
}

// ==================== 生鲜收款成功弹窗（绿色版） ====================
class _FreshSuccessDialog extends StatelessWidget {
  final String orderNo;
  final double total;
  final String method;
  const _FreshSuccessDialog({required this.orderNo, required this.total, required this.method});
  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 92, height: 92,
            decoration: BoxDecoration(color: FreshColors.light, shape: BoxShape.circle),
            child: const Icon(Icons.check, size: 52, color: FreshColors.accent),
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
            child: BigButton('继续收银', onTap: () => Navigator.pop(context), height: 56, color: FreshColors.accent),
          ),
        ]),
      ),
    );
  }
}
