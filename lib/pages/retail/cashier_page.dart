import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/api.dart';
import '../../core/cart_prefs.dart';
import '../../core/cash_drawer.dart';
import '../../core/customer_display.dart';
import '../../core/clear_pin.dart';
import '../../core/cloud_printer.dart';
import '../../core/display_prefs.dart';
import '../../core/layout_prefs.dart';
import '../../core/pay_methods.dart';
import '../../core/print_prefs.dart';
import '../../core/scale.dart';
import '../../core/search_focus.dart';
import '../../core/session.dart';
import '../../core/store_activity.dart';
import '../../core/theme.dart';
import '../../core/theme_prefs.dart';
import '../../core/voice.dart';
import '../../ui/brand_logos.dart';
import '../../ui/cart_line_dialog.dart';
import '../../ui/no_code_goods.dart';
import '../../ui/touch_keyboard.dart';
import '../../ui/vip_recharge.dart';
import '../../ui/weigh_dialog.dart';
import '../../ui/widgets.dart';
import '../../ui/xyf_scan_pay.dart';

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
  double num; // 按件为整数；称重商品为重量（3 位小数，单位见商品 danwei）
  double? price; // 单行改价（null = 按商品原价）v3.3.205
  double giftQty; // 赠送数量（0=无；称重商品单位同商品，随小票打 0 元行）v3.3.231
  _CartLine(this.goods, this.num, {this.price, this.giftQty = 0});
  bool get byWeight => '${goods['sell_type'] ?? 0}' == '1';
  String get unit => byWeight ? _unitOf(goods) : '';

  /// 商品原价（资料价，未改价时即成交价）
  double get listPrice => double.tryParse('${goods['amount'] ?? goods['price'] ?? 0}') ?? 0;

  /// 成交单价：有改价用改价，否则用资料价
  double get unitPrice => price ?? listPrice;

  /// 应付数量（v3.3.235 按赠送计价模式）：
  /// - 含赠送模式（默认）：数量 − 赠送（数量=顾客拿走总量，收钱扣掉赠送）
  /// - 不含赠送模式：数量即付钱部分，赠送额外拿走，收钱按全量
  double get payNum {
    if (!GiftMode.isDeduct) return num;
    final v = num - giftQty;
    return v > 0 ? v : 0;
  }

  /// 赠送数量展示：按件 x1 / 称重 0.25kg（v3.3.231）
  String get giftText {
    if (giftQty <= 0) return '';
    if (!byWeight) return 'x${giftQty.round()}';
    var s = giftQty.toStringAsFixed(3);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return '${s.isEmpty ? '0' : s}$unit';
  }

  static String _unitOf(Map g) {
    final u = '${g['danwei'] ?? ''}'.trim();
    return u.isEmpty ? 'kg' : u;
  }
}

class _RetailCashierPageState extends State<RetailCashierPage> {
  List cats = [];
  List goods = [];
  int selectedCat = -1; // -1 全部
  String keyword = '';
  bool loading = true;
  String? error;

  // 搜索框始终聚焦（v3.3.187，扫码枪适配）
  final searchKeeper = SearchFocusKeeper();
  final searchCtrl = TextEditingController();

  // 自带触屏键盘（v3.3.221）：触摸屏收银机上顾客自助输简拼/条码，
  // 不依赖已被关闭的 Windows 系统触摸键盘。状态本机记忆。
  bool kbOpen = false;
  static const _kbPrefKey = 'retail_touch_kb';

  // 购物车面板位置（v3.3.189，设置 → 功能设置可切换左/右）
  String cartSide = 'right';

  // 挂单（v3.3.191）：暂存购物车（含会员），本机持久化，最多 20 单
  final List<Map<String, dynamic>> holds = [];
  static const _holdsKey = 'retail_holds';

  final List<_CartLine> cart = [];
  Map? vip; // 选中的会员
  bool couponOn = false; // 5元优惠券（v3.3.219）：收银页点标签启用，落单/小票生效

  @override
  void initState() {
    super.initState();
    searchKeeper.init();
    // 上次用过触屏键盘的机器，进来就展开（顾客点单场景）
    SharedPreferences.getInstance().then((p) {
      final on = p.getBool(_kbPrefKey) ?? false;
      if (mounted && on != kbOpen) setState(() => kbOpen = on);
    });
    CartSide.side().then((v) {
      if (mounted && v != cartSide) setState(() => cartSide = v);
    });
    // 显示自定义设置（v3.3.193）：商品字体/每行个数改动即时刷新收银页
    DisplayPrefs.goodsFont.addListener(_onDisplayChanged);
    DisplayPrefs.goodsCols.addListener(_onDisplayChanged);
    DisplayPrefs.goodsImage.addListener(_onDisplayChanged); // 显示/不显示商品图片
    ThemePrefs.skinId.addListener(_onDisplayChanged); // 主体风格换色即时刷新
    _initScaleBar(); // 常驻称重条（v3.3.207，仅 Windows/安卓；mac 保持原样）
    // 副屏（客显）：把当前购物车实时推到第二块屏，600ms 一次，未开副屏时为无操作
    _cdTimer = Timer.periodic(const Duration(milliseconds: 600), (_) => _publishCd());
    _loadHolds();
    _load();
    // 店铺活动（v3.3.222）：加载 + 监听，设置里改完回来自动生效
    ActivityStore.list.addListener(_onActivityChanged);
    ActivityStore.ensure();
    // 赠送计价模式（v3.3.235）：设置里切换后收银页即时生效
    GiftMode.load();
    GiftMode.value.addListener(_onGiftModeChanged);
  }

  void _onGiftModeChanged() {
    if (mounted) setState(() {});
  }

  /// 活动配置变化（设置页增删改）→ 重算应收与赠品
  void _onActivityChanged() {
    if (mounted) setState(() {});
  }

  /// 副屏快照（v3.3.209）：名称 / 数量 / 单位 / 单价 / 金额 + 件数合计
  void _publishCd() {
    if (!mounted || !CustomerDisplay.active) return;
    CustomerDisplay.ensureServer(); // 懒启动：端口被占/服务没跑时自动补（v3.3.210）
    CustomerDisplay.publish(
      shop: Session.shopName,
      vipId: Session.wenxunId,
      total: double.parse(payable.toStringAsFixed(2)), // 券后应收（v3.3.219）
      items: cart.map((l) => <String, dynamic>{
            'n': '${l.goods['title'] ?? ''}',
            'q': l.byWeight ? l.payNum.toStringAsFixed(3) : '${l.payNum.round()}',
            'u': l.unit,
            'p': double.parse(l.unitPrice.toStringAsFixed(2)),
            'a': double.parse((l.unitPrice * l.payNum).toStringAsFixed(2)),
          }).toList(),
    );
  }

  void _onDisplayChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    DisplayPrefs.goodsFont.removeListener(_onDisplayChanged);
    DisplayPrefs.goodsCols.removeListener(_onDisplayChanged);
    DisplayPrefs.goodsImage.removeListener(_onDisplayChanged);
    ThemePrefs.skinId.removeListener(_onDisplayChanged);
    ActivityStore.list.removeListener(_onActivityChanged);
    GiftMode.value.removeListener(_onGiftModeChanged);
    scaleSub?.cancel();
    scanDebounce?.cancel();
    _cdTimer?.cancel();
    searchKeeper.dispose();
    searchCtrl.dispose();
    super.dispose();
  }

  // ==================== 常驻称重条（v3.3.207） ====================
  // 搜索框右侧实时显示秤上重量 + 连接状态；串口秤支持远程置零/去皮。
  // 连续称重流程：置零/去皮 → 放稳 → 等稳定 → 点称重商品自动拉秤上重量（称重弹窗）
  ScalePrefs? scalePrefs;
  ScaleFrame? scaleFrame;
  StreamSubscription<ScaleFrame>? scaleSub;
  Timer? scanDebounce;
  Timer? _cdTimer; // 副屏（客显）推送（v3.3.209） // 条码秤标签识别防抖

  Future<void> _initScaleBar() async {
    if (!ScaleSupport.canUseScale) return; // mac 保持原样，不接秤
    final p = await ScalePrefs.load();
    if (!mounted) return;
    setState(() => scalePrefs = p);
    if (!p.enabled || (p.mode != 'serial' && p.mode != 'builtin')) return;
    await ScaleService.I.ensure();
    scaleSub = ScaleService.I.stream.listen((f) {
      if (!mounted) return;
      setState(() => scaleFrame = f);
    });
  }

  /// 称重条可见性：启用且为串口/内置秤模式（键盘口秤以键盘事件工作，常驻条无意义）
  bool get _showScaleBar =>
      ScaleSupport.canUseScale && scalePrefs != null && scalePrefs!.enabled &&
      (scalePrefs!.mode == 'serial' || scalePrefs!.mode == 'builtin');

  /// 秤读数换算成显示单位（按配置：auto 时 kg 显示）
  String _scaleWeightText() {
    final f = scaleFrame;
    if (f == null) return '--';
    double v = f.kg;
    String u = 'kg';
    final pref = scalePrefs?.unit ?? 'auto';
    if (pref == 'g') {
      v = f.kg * 1000;
      u = 'g';
    } else if (pref == 'jin') {
      v = f.kg * 2;
      u = '斤';
    }
    var s = v.toStringAsFixed(u == 'g' ? 0 : 3);
    if (u != 'g') s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return '$s $u';
  }

  /// 点称重条 → 置零 / 去皮 / 连接状态
  Future<void> _scaleSheet() async {
    final canRemote = ScaleService.I.canRemoteCommand;
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.scale_outlined, size: 20, color: PosTheme.accentLive),
              const SizedBox(width: 8),
              Text(ScaleService.I.connected ? '电子秤已连接' : '电子秤未连接',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800,
                      color: ScaleService.I.connected ? const Color(0xFF1E9C58) : PosTheme.textSub)),
              const Spacer(),
              Text(_scaleWeightText(), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: PosTheme.accentLive)),
            ]),
            const SizedBox(height: 14),
            if (canRemote) ...[
              Row(children: [
                Expanded(child: BigButton('置零（空秤归0）', onTap: () {
                  Navigator.pop(ctx);
                  toast(context, ScaleService.I.zero() ? '已发送置零指令，无反应请按秤面【置零】键' : '指令未送达：秤未连接', error: true);
                }, height: 52)),
                const SizedBox(width: 12),
                Expanded(child: BigButton('去皮（扣皮重）', onTap: () {
                  Navigator.pop(ctx);
                  toast(context, ScaleService.I.tare() ? '已发送去皮指令，无反应请按秤面【去皮】键' : '指令未送达：秤未连接', error: true);
                }, height: 52, color: PosTheme.blue)),
              ]),
            ] else ...[
              const Text('当前秤类型不支持远程置零/去皮，请在秤面按键操作：\n置零=空秤归0 ｜ 去皮=扣掉碗碟盒子皮重',
                  style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
            ],
            const SizedBox(height: 10),
            Text(
              '连续称重：放稳 → 等数字停止闪烁 → 点称重商品自动带入重量；换碗/换品类建议重新去皮，称下一份前等秤回零',
              style: TextStyle(fontSize: 12, color: PosTheme.textHint),
            ),
          ]),
        ),
      ),
    );
  }

  /// 称重条 UI（搜索框右侧 48 高胶囊）
  Widget _scaleBar() {
    final f = scaleFrame;
    final on = ScaleService.I.connected;
    final stable = f?.stable ?? false;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _scaleSheet,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFEAF8F0) : const Color(0xFFF1F2F5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: on
                    ? const Color(0xFF2FBF71).withValues(alpha: 0.5)
                    : PosTheme.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(
              Icons.scale_outlined,
              size: 20,
              color: on ? const Color(0xFF1E9C58) : PosTheme.textHint,
            ),
            const SizedBox(width: 8),
            Text(
              on ? _scaleWeightText() : '未连接',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: on ? (stable ? const Color(0xFF1E9C58) : const Color(0xFFC57F00)) : PosTheme.textHint,
              ),
            ),
            if (on && !stable) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xFFFFF3D6), borderRadius: BorderRadius.circular(6)),
                child: const Text('不稳', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFC57F00))),
              ),
            ],
          ]),
        ),
      ),
    );
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
      // 名称 + 简拼（jianpin 首字母字段，忽略大小写）+ 商品编码/条码 三匹配（v3.3.65 / v3.3.221）
      // 编码匹配是为触屏键盘的数字键准备的：顾客能输条码找货，扫码枪扫普通条码也能过滤出结果
      final kw = keyword.toLowerCase();
      g = g.where((x) =>
          '${x['title']}'.contains(keyword) ||
          '${x['jianpin'] ?? ''}'.toLowerCase().contains(kw) ||
          '${x['code'] ?? x['bianma'] ?? ''}'.contains(keyword));
    }
    return g.toList();
  }

  double get total => cart.fold<double>(0, (s, l) => s + l.unitPrice * l.payNum);
  // 件数：按件商品累加数量，称重行按 1 笔计
  int get count => cart.fold(0, (s, l) => s + (l.byWeight ? 1 : l.num.round()));

  /// 5元优惠券面额（v3.3.219）
  static const double couponValue = 5.0;
  /// 券的门槛基数：活动优惠后的金额（v3.3.222）
  double get couponBase => total - actDiscount;
  /// 优惠券实际抵扣：启用且活动后仍 > 5 元时抵 5 元（不足不生效，避免 0 元单）
  double get couponApplied => couponOn && couponBase > couponValue ? couponValue : 0;
  /// 应收金额 = 合计 - 活动优惠 - 优惠券抵扣（v3.3.222 活动接入）
  /// 最低 0.01 元：满减配置过大时不产生 0 元单
  double get payable {
    final v = total - actDiscount - couponApplied;
    if (v >= 0.01) return v;
    return total > 0 ? 0.01 : 0;
  }

  // ==================== 店铺活动（v3.3.222） ====================
  // 满减/折扣/买赠/满赠，配置在 设置 → 营销活动，结算时自动计算。
  // 每次 build 现算：活动条数少、购物车行数少，开销可忽略。

  /// 商品 id → 商品资料（找指定赠品用）
  Map<int, Map> get _goodsIndex {
    final m = <int, Map>{};
    for (final g in goods) {
      final id = int.tryParse('${g['id']}') ?? 0;
      if (id > 0) m[id] = g as Map;
    }
    return m;
  }

  /// 当前购物车的活动计算结果（金额优惠 + 赠品）
  ActivityResult get activityResult {
    if (cart.isEmpty) return ActivityResult.empty;
    final lines = <ActivityCartLine>[];
    for (final l in cart) {
      lines.add(ActivityCartLine(
        goodsId: int.tryParse('${l.goods['id']}') ?? 0,
        catId: int.tryParse('${l.goods['cat_id']}') ?? 0,
        qty: l.payNum, // 应付数量参与活动（赠送部分不再触发买赠，避免双重赠送）
        unitPrice: l.unitPrice,
        byWeight: l.byWeight,
        goods: l.goods,
      ));
    }
    return ActivityEngine.compute(
      lines: lines,
      acts: ActivityStore.list.value,
      goodsById: _goodsIndex,
    );
  }

  /// 活动优惠金额（满减 / 折扣）
  double get actDiscount => activityResult.discount;

  /// 是否称重商品（商品资料 sell_type=1）
  bool _isWeighted(Map g) => '${g['sell_type'] ?? 0}' == '1';

  /// 称重商品单位（商品 danwei，缺省 kg）
  String _unitOf(Map g) {
    final u = '${g['danwei'] ?? ''}'.trim();
    return u.isEmpty ? 'kg' : u;
  }

  /// 数量展示：按件整数 / 称重 3 位小数去尾零
  String _qtyText(_CartLine l) {
    if (!l.byWeight) return '${l.num.round()}';
    var s = l.num.toStringAsFixed(3);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return s;
  }

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

  void _add(Map g, {double qty = 1}) {
    final key = _cartKey(g);
    final i = cart.indexWhere((l) => _cartKey(l.goods) == key);
    if (i > -1) {
      cart[i].num += qty;
    } else {
      cart.add(_CartLine(g, qty));
    }
    setState(() {});
  }

  /// 称重商品：弹称重面板。已存在该行时预填当前重量（改重量，不累加）
  Future<void> _weighAndAdd(Map g) async {
    final key = _cartKey(g);
    final i = cart.indexWhere((l) => _cartKey(l.goods) == key);
    final cur = i > -1 ? cart[i].num : 0.0;
    final w = await showDialog<double>(
      context: context,
      builder: (_) => WeighDialog(
        title: '${g['title']}',
        price: _price(g),
        unit: _unitOf(g),
        initial: cur,
      ),
    );
    if (w == null || w <= 0 || !mounted) return;
    setState(() {
      if (i > -1) {
        cart[i].num = w; // 已有行：改成新重量
      } else {
        cart.add(_CartLine(g, w));
      }
    });
  }

  /// 点击商品：称重商品走称重面板；多规格弹规格组合弹窗；单规格直接加购
  Future<void> _tapGoods(Map g) async {
    if (_isWeighted(g)) {
      await _weighAndAdd(g);
      _clearKeywordAfterAdd();
      return;
    }
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
      _clearKeywordAfterAdd();
      return;
    }
    _add(g);
    _clearKeywordAfterAdd();
  }

  void _dec(_CartLine l) {
    if (l.byWeight) {
      // 称重行：减号=删除该行（改重量请点重量数字）
      _removeLine(l);
      return;
    }
    l.num--;
    if (l.num <= 0) {
      _removeLine(l);
      return;
    }
    l.giftQty = GiftMode.clampGift(l.num, l.giftQty, l.byWeight); // 防赠送顶满 0 元购（v3.3.237）
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

  /// 点购物车某行 → 改数量 / 改价 / 赠送数量 / 删除
  Future<void> _lineEdit(_CartLine l) async {
    final guige = '${l.goods['guige'] ?? ''}'.trim();
    final r = await showCartLineDialog(
      context,
      title: '${l.goods['title']}',
      subtitle: guige.isEmpty ? '' : '规格 $guige',
      listPrice: l.listPrice,
      num: l.num,
      giftQty: l.giftQty,
      price: l.price,
      byWeight: l.byWeight,
      unit: l.unit,
      accent: PosTheme.accentLive,
      onNeedPriceAuth: _authPrice,
    );
    if (r == null || !mounted) return;
    if (r.deleted) {
      _removeLine(l);
      return;
    }
    setState(() {
      l.num = r.num;
      l.price = r.price;
      l.giftQty = GiftMode.clampGift(r.num, r.giftQty, l.byWeight);
    });
  }

  /// 删除单行商品（带 4 秒撤销）
  void _removeLine(_CartLine l) {
    final i = cart.indexOf(l);
    if (i < 0) return;
    setState(() => cart.removeAt(i));
    // 该行删掉后若购物车空了，会员也一并清掉
    if (cart.isEmpty && vip != null) setState(() => vip = null);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
      content: Text('已删除「${l.goods['title']}」'),
      duration: const Duration(seconds: 4),
      // v3.3.206：Flutter 新版默认 persist = (action != null)，带按钮的 SnackBar 会永久停留，
      // 必须显式关闭，否则撤销条一直挂在底部不消失
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

  /// 清空购物车：若设置里开启「清空需权限码」，先弹数字键盘校验（v3.3.192）
  Future<void> _clearCart() async {
    if (cart.isEmpty) return;
    if (await ClearPin.enabled()) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ClearPinDialog(count: count, total: total),
      );
      if (ok != true || !mounted) return;
    }
    setState(() { cart.clear(); vip = null; couponOn = false; }); // 优惠券随清空重置（v3.3.219）
  }

  // ==================== 挂单 / 取单（v3.3.191） ====================

  Future<void> _loadHolds() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_holdsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (mounted) setState(() => holds..clear()..addAll(list));
    } catch (_) {} // 数据损坏时忽略，不影响收银
  }

  Future<void> _saveHolds() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_holdsKey, jsonEncode(holds));
  }

  /// 挂单/取单入口：购物车有内容 → 挂单；为空且有挂单 → 取单列表
  Future<void> _holdTap() async {
    if (cart.isNotEmpty) return _holdOrder();
    if (holds.isNotEmpty) return _pickHold();
  }

  /// 挂单：把当前购物车（含选中会员）暂存到列表头部，清空购物车
  Future<void> _holdOrder() async {
    final n = DateTime.now();
    final t = '${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')} '
        '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
    setState(() {
      holds.insert(0, {
        'time': t,
        'vip': vip,
        'items': cart.map((l) => {'goods': l.goods, 'num': l.num, 'price': l.price, 'gift_qty': l.giftQty}).toList(),
      });
      if (holds.length > 20) holds.removeLast(); // 最多 20 单，超出丢最旧
      cart.clear();
      vip = null;
    });
    await _saveHolds();
    if (!mounted) return;
    toast(context, '已挂单（共 ${holds.length} 单，点「取单」找回）');
  }

  /// 取单列表：恢复到购物车（若当前购物车非空需确认替换）或删除
  Future<void> _pickHold() async {
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _HoldListDialog(
        holds: holds,
        onRestore: (h) => Navigator.pop(context, h),
        onDelete: (h) {
          setState(() => holds.remove(h));
          _saveHolds();
        },
      ),
    );
    if (picked == null || !mounted) return;
    await _restoreHold(picked);
  }

  /// 恢复挂单到购物车
  Future<void> _restoreHold(Map<String, dynamic> h) async {
    if (cart.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('取单', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          content: const Text('当前购物车还有商品，取单将替换为挂单内容。', style: TextStyle(fontSize: 14.5)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: PosTheme.accent),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('替换', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final items = ((h['items'] as List?) ?? [])
        .map((e) {
          final m = e as Map;
          return _CartLine(
            Map<String, dynamic>.from(m['goods'] as Map),
            (m['num'] as num?)?.toDouble() ?? 1,
            price: (m['price'] as num?)?.toDouble(),
            giftQty: (m['gift_qty'] as num?)?.toDouble() ?? 0,
          );
        })
        .toList();
    final v = h['vip'] == null ? null : Map<String, dynamic>.from(h['vip'] as Map);
    setState(() {
      cart
        ..clear()
        ..addAll(items);
      vip = v;
      holds.remove(h);
      couponOn = false; // 取单重置优惠券（v3.3.219）
    });
    await _saveHolds();
    if (!mounted) return;
    toast(context, items.isEmpty ? '挂单内容为空，已移除' : '已取单：${items.length} 个商品');
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
    }, qty: ((r['num'] as num?) ?? 1).toDouble());
  }

  // ==================== 结算收款 ====================
  Future<void> _checkout() async {
    if (cart.isEmpty) return;
    double t = payable; // 应收（含优惠券抵扣，v3.3.219；现金抹零后可减）
    final coupon = couponApplied; // 本次抵扣金额（小票打印用）
    final order = await PayMethods.load();

    // ===== 快捷通道（v3.3.177 复用餐饮 v3.3.164）：默认支付方式是微信/支付宝时，
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
        return _finishOrder(quick, t, coupon: coupon,
            xyfOrderNo: '${pay['orderNo'] ?? quickNo}',
            xyfChannel: int.tryParse('${pay['order']?['pay_channel'] ?? 0}') ?? 0);
      }
      // 取消扫码 或 点「其他方式」→ 继续走下面的完整弹窗
    }

    // 未选会员时不出现「会员支付」，避免误点；按商户「支付方式排序」展示（v3.3.176 全场景复用）
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
    double mollen = 0; // 现金抹零金额（v3.3.238）
    if (picked is Map) {
      pickedMethod = '${picked['method']}';
      xyfOrderNo = '${picked['xyf_order_no'] ?? ''}';
      xyfChannel = (picked['xyf_channel'] as int?) ?? 0;
      // 现金抹零（v3.3.238）：弹窗带回抹零金额，应收相应扣减
      final m = (picked['mollen'] as num?)?.toDouble() ?? 0;
      if (m > 0) {
        mollen = m;
        t = double.parse((t - m).toStringAsFixed(2));
      }
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
    await _finishOrder(pickedMethod, t, coupon: coupon, mollen: mollen,
        xyfOrderNo: xyfOrderNo, xyfChannel: xyfChannel);
  }

  /// 落单执行（v3.3.177 从 _checkout 拆出）：会员扣款 / 扫码 / 现金统一收口
  /// [coupon] 优惠券抵扣金额（v3.3.219），[mollen] 现金抹零（v3.3.238），t 为抵扣后的应收
  Future<void> _finishOrder(String picked, double t,
      {double coupon = 0, double mollen = 0, String xyfOrderNo = '', int xyfChannel = 0}) async {
    final act = activityResult; // 活动快照：清空购物车前取，小票与赠品行共用
    final cartPayload = <Map<String, dynamic>>[
      ...cart.map((l) => {
            'id': l.goods['id'],
            'name': l.goods['title'],
            'price': l.unitPrice, // 单行改价后的成交价（v3.3.205）
            'quantity': l.payNum, // 应付数量（赠送部分已扣减，v3.3.232）
            'unit': l.byWeight ? l.unit : '',
            'guige': '${l.goods['guige'] ?? ''}',
            'image': _img(l.goods),
            'gift_qty': l.giftQty, // 单行赠送数量（小票打 0 元行，不计价）v3.3.231
          }),
      // 赠品以 0 元行随单提交（v3.3.222）：订单明细能看出是赠品，退款仍按实付金额
      for (final g in act.gifts)
        {
          'id': g.goods['id'],
          'name': '${g.title}（赠品）',
          'price': 0,
          'quantity': g.qty,
          'unit': g.byWeight ? g.unit : '',
          'guige': '${g.goods['guige'] ?? ''}',
          'image': _img(g.goods),
          'gift_qty': 0,
        },
    ];

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
          originalTotal: total, // 商品原价合计（t 为券后应收，v3.3.219）
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
        if (await PrintPrefs.on('retail')) {
          CloudPrinter.printRetail(
            CloudPrinter.retailReceipt(
              orderNo: orderNo, payMethod: picked, total: t, coupon: coupon,
              activityDiscount: act.discount, activityLines: act.labels, mollen: mollen,
              gifts: [
                for (final g in act.gifts)
                  {'name': g.title, 'quantity': g.qty, 'unit': g.byWeight ? g.unit : '', 'byWeight': g.byWeight},
              ],
              cart: cart.map((l) => {'name': l.goods['title'], 'price': l.unitPrice, 'quantity': l.payNum, 'unit': l.byWeight ? l.unit : '', 'gift_qty': l.giftQty}).toList(),
            ),
            alsoCloud: cart.any((l) => l.byWeight), // 称重订单云打印机同步一份（v3.3.214）
          ).catchError((_) => <String, dynamic>{});
        }
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
        originalTotal: total, // 活动/券前原价合计（v3.3.222，补打小票显示优惠）
        paymentMethod: picked,
        vipId: vip == null ? 0 : int.tryParse('${vip!['id']}') ?? 0,
        cart: cartPayload,
        payOrderNo: xyfOrderNo,
        payChannel: xyfChannel,
        mollen: mollen, // 现金抹零落库（v3.3.239，交班统计/补打小票共用）
      );
      if (!mounted) return;
      Navigator.pop(context);
      final orderNo = '${r['orderNumber'] ?? r['order_number'] ?? ''}';

      // 现金结算自动弹钱箱（v3.3.202，异步不阻塞收银）
      CashDrawer.autoOpen(picked);

      // 云打印（异步，不阻塞收银；小票开关 v3.3.77）
      if (await PrintPrefs.on('retail')) {
        CloudPrinter.printRetail(
          CloudPrinter.retailReceipt(
            orderNo: orderNo, payMethod: picked, total: t, coupon: coupon,
            activityDiscount: act.discount, activityLines: act.labels, mollen: mollen,
            gifts: [
              for (final g in act.gifts)
                {'name': g.title, 'quantity': g.qty, 'unit': g.byWeight ? g.unit : '', 'byWeight': g.byWeight},
            ],
            cart: cart.map((l) => {'name': l.goods['title'], 'price': l.unitPrice, 'quantity': l.payNum, 'unit': l.byWeight ? l.unit : '', 'gift_qty': l.giftQty}).toList(),
          ),
          alsoCloud: cart.any((l) => l.byWeight), // 称重订单云打印机同步一份（v3.3.214）
        ).catchError((_) => <String, dynamic>{});
      }

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
              ? Center(child: CircularProgressIndicator(color: PosTheme.accentLive))
              : error != null
                  ? _errorView()
                  : Row(
                      children: cartSide == 'left'
                          ? [
                              _cartPanel(), // 购物车在左（v3.3.189 可配置）
                              Expanded(child: _goodsGrid()),
                              _catRail(indicatorRight: true), // 分类栏在最右，选中线显示在右侧
                            ]
                          : [
                              _catRail(),
                              Expanded(child: _goodsGrid()),
                              _cartPanel(), // 购物车在右（默认）
                            ],
                    ),
        ),
        // 自带触屏键盘（v3.3.221）：展开时挤压上方内容，不遮挡商品/底栏
        if (kbOpen)
          TouchKeyboard(
            // 小窗口（<680 高）用紧凑键高，保证商品区和底栏仍有空间
            keyHeight: MediaQuery.of(context).size.height < 680 ? 34 : 40,
            hintText: keyword.isEmpty
                ? ''
                : '已输入「$keyword」· 匹配 ${filtered.length} 个商品',
            onInput: _kbInput,
            onBackspace: _kbBackspace,
            onClear: _kbClear,
            onClose: _kbToggle,
          ),
      ],
    );
  }

  // v3.3.225：无码商品与左侧分类栏同宽对齐（124）、去图标只留文字；
  // 触屏键盘按钮移到无码商品后面（原在搜索框右侧）。
  // 搜索框占用其余全部宽度。
  Widget _topBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 20, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _noCodeBtn(),
          const SizedBox(width: 10),
          _kbBtn(),
          const SizedBox(width: 14),
          Expanded(child: _searchBox()),
          if (_showScaleBar) ...[
            const SizedBox(width: 10),
            _scaleBar(),
          ],
        ],
      ),
    );
  }

  /// 无码商品入口（扫码枪扫不到的商品手动录入）
  /// v3.3.227：顶栏左缘留 14 间距，按钮宽 110 = 分类栏 124 - 14，
  /// 右边缘与分类栏对齐、不超出
  Widget _noCodeBtn() {
    return SizedBox(
      width: 110,
      height: 48,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _noCodeGoods,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: PosTheme.tint,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: PosTheme.accentLive.withValues(alpha: 0.35)),
            ),
            child: Text('无码商品',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: PosTheme.accentLive)),
          ),
        ),
      ),
    );
  }

  /// 触屏键盘开关按钮（搜索框右侧，v3.3.221）
  Widget _kbBtn() {
    return SizedBox(
      width: 48,
      height: 48,
      child: Material(
        color: kbOpen ? PosTheme.accentLive : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: kbOpen ? Colors.transparent : PosTheme.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _kbToggle,
          child: Icon(Icons.keyboard_alt_outlined,
              size: 24, color: kbOpen ? Colors.white : PosTheme.textSub),
        ),
      ),
    );
  }

  /// 开合触屏键盘。状态存本机，换班/重启后保持（顾客点单机器常开）。
  void _kbToggle() {
    setState(() => kbOpen = !kbOpen);
    SharedPreferences.getInstance().then((p) => p.setBool(_kbPrefKey, kbOpen));
    if (!kbOpen) searchKeeper.node.requestFocus(); // 收起后扫码枪继续可用
  }

  /// 键盘写入：直接改 controller 并复用搜索逻辑（不走模拟按键，避免焦点问题）
  void _kbWrite(String text) {
    searchCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onSearchChanged(text);
  }

  void _kbInput(String ch) => _kbWrite(searchCtrl.text + ch);

  void _kbBackspace() {
    final t = searchCtrl.text;
    if (t.isEmpty) return;
    _kbWrite(t.substring(0, t.length - 1));
  }

  void _kbClear() => _kbWrite('');

  /// 键盘展开状态下加购成功 → 清空搜索词，顾客接着输下一个（连续点单）
  void _clearKeywordAfterAdd() {
    if (!kbOpen || keyword.isEmpty) return;
    searchCtrl.clear();
    setState(() => keyword = '');
  }

  /// 商品搜索框：与大按钮同高 48，圆角白底 + 柔和阴影，字号放大
  Widget _searchBox() {
    return SizedBox(
      height: 48,
      child: TextField(
        controller: searchCtrl,
        focusNode: searchKeeper.node,
        textAlignVertical: TextAlignVertical.center,
        cursorColor: PosTheme.accentLive,
        style: const TextStyle(
            fontSize: 17, fontWeight: FontWeight.w500, color: PosTheme.textMain),
        onChanged: _onSearchChanged,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          hintText: '搜索商品名称 / 简拼 / 条码',
          hintStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w400,
              color: PosTheme.textHint),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          prefixIcon: const Icon(Icons.search_rounded,
              size: 24, color: PosTheme.textSub),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 50, minHeight: 48),
          suffixIcon: keyword.isEmpty ? null : _clearBtn(),
          suffixIconConstraints:
              const BoxConstraints(minWidth: 46, minHeight: 48),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: PosTheme.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: PosTheme.accentLive, width: 1.6),
          ),
        ),
      ),
    );
  }

  /// 搜索/扫码输入：普通关键词直接过滤；扫到条码秤标签（2 前缀 13 位）自动解析入购物车
  void _onSearchChanged(String v) {
    setState(() => keyword = v.trim());
    scanDebounce?.cancel();
    final t = v.trim();
    if (!RegExp(r'^2\d{12}$').hasMatch(t)) return; // 不是条码秤标签格式，走普通搜索
    scanDebounce = Timer(const Duration(milliseconds: 180), () => _tryScaleBarcode(t));
  }

  /// 条码秤标签：扫标签 → 按编码匹配商品 → 标签重量直接入购物车
  ///
  /// 匹配规则：商品资料「条码」字段 = 条码秤里配置的商品编码（PLU，忽略前导零）
  Future<void> _tryScaleBarcode(String code) async {
    final tag = ScaleBarcode.tryParse(code);
    if (tag == null) return;
    final pluNum = int.tryParse(tag.plu);
    Map? hit;
    for (final g in goods) {
      final c = '${g['code'] ?? g['bianma'] ?? g['barcode'] ?? ''}'.trim();
      if (c.isEmpty) continue;
      if (c == tag.plu || c == tag.plu.replaceFirst(RegExp(r'^0+'), '') || (pluNum != null && int.tryParse(c) == pluNum)) {
        hit = g;
        break;
      }
    }
    if (hit == null) {
      toast(context, '秤标签编码 ${tag.plu} 未匹配到商品（商品资料条码需与秤内编码一致）', error: true);
      return;
    }
    if (_hasSpecs(hit)) {
      toast(context, '「${hit['title']}」是多规格商品，请在列表里手动点选', error: true);
      return;
    }
    searchCtrl.clear();
    setState(() => keyword = '');
    searchKeeper.node.requestFocus();
    final h = hit; // setState 闭包内类型提升失效，先取局部
    if (_isWeighted(h)) {
      final key = _cartKey(h);
      final i = cart.indexWhere((l) => _cartKey(l.goods) == key);
      setState(() {
        if (i > -1) {
          cart[i].num = double.parse((cart[i].num + tag.kg).toStringAsFixed(3)); // 同商品连续扫：累加
        } else {
          cart.add(_CartLine(h, tag.kg));
        }
      });
      toast(context, '已按秤标签加入：${h['title']} ${_qtyTextOf(tag.kg)}${_unitOf(h)}');
    } else {
      _add(h);
      toast(context, '已加入：${h['title']}');
    }
  }

  /// 重量展示（3 位小数去尾零）
  String _qtyTextOf(double n) {
    var s = n.toStringAsFixed(3);
    return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  /// 清空按钮：真正清空输入框内容 + 过滤条件，并把焦点还给搜索框（扫码枪继续可用）
  Widget _clearBtn() {
    return Padding(
      padding: const EdgeInsets.only(right: 8, left: 4),
      child: Material(
        color: const Color(0xFFF1F2F5),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            searchCtrl.clear();
            setState(() => keyword = '');
            searchKeeper.node.requestFocus();
          },
          child: const SizedBox(
            width: 26,
            height: 26,
            child: Icon(Icons.close_rounded, size: 17, color: PosTheme.textSub),
          ),
        ),
      ),
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
  /// [indicatorRight]：分类栏贴在屏幕右缘（购物车在左布局）时，选中线画在右侧
  Widget _catRail({bool indicatorRight = false}) {
    final all = [{'id': -1, 'title': '全部'}, ...cats];
    return Container(
      width: 124,
      color: Colors.white,
      child: ListView.builder(
        itemCount: all.length,
        itemBuilder: (_, i) {
          final c = all[i];
          final on = selectedCat == c['id'];
          final line = BorderSide(color: on ? PosTheme.accentLive : Colors.transparent, width: 4);
          return InkWell(
            onTap: () => setState(() => selectedCat = c['id']),
            child: Container(
              height: 58,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? PosTheme.tint : Colors.transparent,
                border: indicatorRight ? Border(right: line) : Border(left: line),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('${c['title']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, color: on ? PosTheme.accentLive : PosTheme.textMain, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
              ),
            ),
          );
        },
      ),
    );
  }

  // 商品网格（卡片加大，触摸友好）
  // 每行显示个数（v3.3.193 设置 → 显示设置）：0=自动按屏宽自适应；3~8=固定每行个数
  // 卡片高度按「商品字体 × 整体字体缩放」动态计算，保证名称+价格永远放得下（不会撑破卡片）
  // v3.3.196：支持「不显示商品图片」，纯文字卡片高度更矮、每行可以放更多
  Widget _goodsGrid() {
    final list = filtered;
    if (list.isEmpty) return const EmptyView('该分类暂无在售商品', icon: Icons.storefront);
    final colsSetting = DisplayPrefs.goodsCols.value;
    final f = DisplayPrefs.goodsFontFactor;
    final withImg = DisplayPrefs.goodsImage.value;
    return LayoutBuilder(builder: (ctx, cons) {
      const pad = 16.0, gap = 14.0;
      final avail = (cons.hasBoundedWidth ? cons.maxWidth : 720.0) - pad * 2;
      // 纯文字卡不需要图片宽度，自动模式可以放得更密
      final unitW = withImg ? 180.0 : 148.0;
      final cols = colsSetting >= 3
          ? colsSetting
          : (avail / unitW).ceil().clamp(1, 12).toInt();
      final rawW = (avail - gap * (cols - 1)) / cols;
      final cardW = rawW < 40 ? 40.0 : rawW; // 窗口极窄时兜底，避免算出负宽
      final tScale = MediaQuery.textScalerOf(ctx).scale(100) / 100;
      double itemH;
      if (withImg) {
        // 图片区高度：随卡片宽度温和增长但封顶 130（v3.3.204），
        // 之前按 cardW/0.8 等比膨胀，宽屏上卡片被拉得又高又空
        final imgH = (cardW * 0.62).clamp(90.0, 130.0);
        final textH = 14.5 * f * tScale * 1.35 + 3 + 17 * f * tScale * 1.35;
        itemH = imgH + 8 + textH + 34; // 34 = 卡片上下内边距20 + 间隙8 + 余量6
      } else {
        // 纯文字卡：名称最多 2 行 + 价格 1 行 + 上下内边距
        final nameH = 15.5 * f * tScale * 1.28 * 2;
        final priceH = 19 * f * tScale * 1.15;
        final need = nameH + 8 + priceH + 26;
        itemH = need < 96 ? 96 : need;
      }
      return GridView.builder(
        padding: const EdgeInsets.all(pad),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols, mainAxisSpacing: gap, crossAxisSpacing: gap, mainAxisExtent: itemH,
        ),
        itemCount: list.length,
        itemBuilder: (_, i) => _goodsCard(list[i]),
      );
    });
  }

  // 商品卡片字体（v3.3.193 设置 → 显示设置）：小 0.85 / 标准 1.0 / 大 1.2 / 特大 1.4
  // 图片开关（v3.3.196）：显示图片 = 上图下文；不显示 = 纯文字卡片（左侧主色竖条 + 大字名称 + 价格 + 规格角标）
  Widget _goodsCard(Map g) {
    final f = DisplayPrefs.goodsFontFactor;
    final withImg = DisplayPrefs.goodsImage.value;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _tapGoods(g),
        child: Container(
          padding: withImg ? const EdgeInsets.all(10) : EdgeInsets.zero,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: PosTheme.line)),
          child: withImg ? _goodsCardImage(g, f) : _goodsCardText(g, f),
        ),
      ),
    );
  }

  /// 上图下文卡（默认样式）
  Widget _goodsCardImage(Map g, double f) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                  decoration: BoxDecoration(color: PosTheme.accentLive, borderRadius: BorderRadius.circular(6)),
                  child: const Text('多规格', style: TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ),
            if (_isWeighted(g))
              Positioned(
                top: 6, left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(color: const Color(0xFF1677FF), borderRadius: BorderRadius.circular(6)),
                  child: const Text('称重', style: TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text('${g['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5 * f, fontWeight: FontWeight.w500)),
      const SizedBox(height: 3),
      Text(_isWeighted(g) ? '¥${Fmt.money(_price(g))}/${_unitOf(g)}' : '¥${Fmt.money(_price(g))}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 17 * f, color: PosTheme.accentLive, fontWeight: FontWeight.w800)),
    ]);
  }

  /// 纯文字卡（不显示图片）：左侧主色竖条 + 商品名最多 2 行 + 大号价格 + 称重/多规格角标
  Widget _goodsCardText(Map g, double f) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(13),
      child: Stack(children: [
        // 左侧主色竖条（顶部实色到底部渐隐），让纯文字卡不显得空
        Positioned(
          left: 0, top: 0, bottom: 0,
          child: Container(
            width: 4,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [PosTheme.accentLive, PosTheme.accentLive.withValues(alpha: 0.18)],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text('${g['title']}',
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15.5 * f,
                      height: 1.28,
                      fontWeight: FontWeight.w600,
                      color: PosTheme.textMain)),
            ),
            const SizedBox(height: 6),
            // 价格 + 规格角标：卡片很窄时只留价格，角标按可用宽度等比缩小，避免溢出
            LayoutBuilder(builder: (ctx, c) {
              final showTags = c.maxWidth >= 110 && (_isWeighted(g) || _hasSpecs(g));
              return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Text(_isWeighted(g) ? '¥${Fmt.money(_price(g))}/${_unitOf(g)}' : '¥${Fmt.money(_price(g))}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 19 * f,
                          height: 1.1,
                          color: PosTheme.accentLive,
                          fontWeight: FontWeight.w800)),
                ),
                if (showTags)
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (_isWeighted(g)) _goodsTag('称重', const Color(0xFF1677FF)),
                        if (_isWeighted(g) && _hasSpecs(g)) const SizedBox(width: 5),
                        if (_hasSpecs(g)) _goodsTag('多规格', PosTheme.accentLive),
                      ]),
                    ),
                  ),
              ]);
            }),
          ]),
        ),
      ]),
    );
  }

  /// 纯文字卡上的小角标
  Widget _goodsTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700, height: 1.2)),
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
                  decoration: BoxDecoration(color: PosTheme.tint, borderRadius: BorderRadius.circular(20)),
                  child: Icon(vip == null ? Icons.person_add_alt : Icons.person, size: 22, color: PosTheme.accentLive),
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
                        color: PosTheme.tint,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: PosTheme.accentLive.withValues(alpha: 0.4)),
                      ),
                      child: Text('充值', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: PosTheme.accentLive)),
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
                                _lineTag('改价', PosTheme.accentLive),
                              ],
                              const SizedBox(width: 6),
                              Text('¥${Fmt.money(l.unitPrice * l.payNum)}', textAlign: TextAlign.right,
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
                                          : (l.byWeight
                                              ? '¥${Fmt.money(l.unitPrice)}/${l.unit}'
                                              : '¥${Fmt.money(l.unitPrice)}${l.price != null ? '（原 ¥${Fmt.money(l.listPrice)}）' : ''}'),
                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
                                  if (l.giftQty > 0)
                                    Text('赠送：${l.giftText}',
                                        maxLines: 1, overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w600)),
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
          // 底部结算（大按钮）
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: PosTheme.line))),
            child: Column(children: [
              _activityBar(), // 命中的活动与赠品（v3.3.222）
              Row(children: [
                Text('共 $count 件', style: const TextStyle(fontSize: 14.5, color: PosTheme.textSub)),
                const SizedBox(width: 10),
                _couponChip(), // 5元优惠券（v3.3.219）
                const Spacer(),
                Text('合计 ', style: const TextStyle(fontSize: 15, color: PosTheme.textSub)),
                if (couponApplied > 0 || actDiscount > 0) ...[
                  Text('¥${Fmt.money(total)}',
                      style: const TextStyle(fontSize: 16, color: PosTheme.textHint, decoration: TextDecoration.lineThrough)),
                  const SizedBox(width: 8),
                ],
                Text('¥${Fmt.money(payable)}', style: TextStyle(fontSize: 30, color: PosTheme.accentLive, fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 62,
                    child: BigButton(
                      holds.isEmpty
                          ? '挂单'
                          : (cart.isEmpty ? '取单 ${holds.length}' : '挂单 ${holds.length}'),
                      onTap: (cart.isEmpty && holds.isEmpty) ? null : _holdTap,
                      color: PosTheme.tint,
                      textColor: PosTheme.accentLive,
                      height: 62),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 62,
                    child: BigButton('清空', onTap: cart.isEmpty ? null : _clearCart, color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 62),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: BigButton('收款 ¥${Fmt.money(payable)}', onTap: cart.isEmpty ? null : _checkout, height: 62),
                ),
              ]),
            ]),
          ),
        ],
      ),
    );
  }

  // 命中的店铺活动 / 赠品提示条（v3.3.222）：无可享活动时不占位
  Widget _activityBar() {
    final a = activityResult;
    if (a.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in a.labels)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFE5484D).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.local_offer, size: 13, color: Color(0xFFE5484D)),
                  const SizedBox(width: 4),
                  Text(t,
                      style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFE5484D))),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  // 5元优惠券标签（v3.3.219）：点按启用/停用，合计不足5元不生效
  Widget _couponChip() {
    final applied = couponApplied > 0;
    final on = couponOn;
    final c = applied ? const Color(0xFFE5484D) : (on ? PosTheme.textHint : PosTheme.accentLive);
    return InkWell(
      onTap: cart.isEmpty ? null : () => setState(() => couponOn = !couponOn),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: applied ? c.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: applied ? c : (on ? PosTheme.line : PosTheme.accentLive.withValues(alpha: 0.5))),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(applied ? Icons.check_circle : Icons.local_offer_outlined, size: 16, color: c),
          const SizedBox(width: 5),
          Text(applied ? '优惠券已减¥5' : '5元优惠券',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c)),
        ]),
      ),
    );
  }

  // 行内小标签（改价/备注等）
  Widget _lineTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: TextStyle(fontSize: 10.5, color: color, fontWeight: FontWeight.w700)),
    );
  }

  // 步进器（44px 大触摸区）
  Widget _stepper(_CartLine l) {
    if (l.byWeight) {
      // 称重行：显示重量，点数字改重量，右侧 × 删除
      return Row(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: () => _weighAndAdd(l.goods),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: PosTheme.tintSoft,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: PosTheme.accentLive.withValues(alpha: 0.5)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${_qtyText(l)} ${l.unit}',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: PosTheme.accentLive)),
              const SizedBox(width: 6),
              Icon(Icons.edit_outlined, size: 15, color: PosTheme.accentLive),
            ]),
          ),
        ),
        const SizedBox(width: 6),
        InkWell(
          onTap: () => _dec(l),
          borderRadius: BorderRadius.circular(23),
          child: const SizedBox(width: 40, height: 46, child: Icon(Icons.close, size: 20, color: PosTheme.textHint)),
        ),
      ]);
    }
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
          child: Container(width: 46, height: 46, alignment: Alignment.center, child: Icon(Icons.add, size: 20, color: PosTheme.accentLive)),
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
  int mollenType = 0; // 抹零模式（v3.3.238）：0 不抹 / 1 抹分 / 2 抹角（仅现金）
  final icons = {
    '现金': Icons.payments_outlined,
    '扫码收款': Icons.qr_code_scanner,
    '微信支付': Icons.chat,
    '支付宝': Icons.account_balance_wallet_outlined,
    '会员支付': Icons.badge_outlined,
  };
  final colors = {
    '现金': PosTheme.green,
    '扫码收款': PosTheme.blue,
    '微信支付': const Color(0xFF07C160),
    '支付宝': const Color(0xFF1677FF),
    '会员支付': PosTheme.accentLive,
  };

  // 映射缺失时给个兜底，避免再有 null 断言把整个收款弹窗打崩
  IconData _iconOf(String m) => icons[m] ?? Icons.payments_outlined;
  Color _colorOf(String m) => colors[m] ?? PosTheme.textSub;

  /// 支付方式图标：微信支付/支付宝用官方品牌 logo，其余用 Material 图标
  Widget _methodIcon(String m, {double size = 30, Color? color}) {
    final c = color ?? _colorOf(m);
    if (m == '微信支付') {
      return WechatPayLogo(size: size, color: c);
    }
    if (m == '支付宝') {
      return AlipayLogo(size: size, color: c);
    }
    return Icon(_iconOf(m), size: size, color: c);
  }

  double get receivedVal => double.tryParse(received) ?? 0;

  /// 抹零金额（v3.3.238，仅现金）：抹分=去分留角（49.53→49.50），抹角=去角留元（49.50→49.00）
  double get mollen {
    if (method != '现金' || mollenType == 0) return 0;
    if (mollenType == 1) {
      final v = (widget.total * 10).floorToDouble() / 10;
      return double.parse((widget.total - v).toStringAsFixed(2));
    }
    return double.parse((widget.total - widget.total.floorToDouble()).toStringAsFixed(2));
  }

  /// 抹零后应收（最低 0.01，避免 0 元单）
  double get payable {
    final v = widget.total - mollen;
    return v >= 0.01 ? double.parse(v.toStringAsFixed(2)) : widget.total;
  }

  double get change => (receivedVal - payable).clamp(0, double.maxFinite);

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

  // ===== v3.3.210 小屏/竖屏自适应 =====
  // 竖屏收银机（如 600×1024）和矮宽屏（1024×768）上，固定 660 宽 + 全内容
  // 约 800 高会溢出切掉「确认收款」。这里按屏幕算尺寸档位，再套滚动兜底。
  bool get _compact {
    final s = MediaQuery.of(context).size;
    return s.height < 900 || s.width < 1100;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final compact = _compact;
    final dialogW = (size.width - 32).clamp(320.0, 660.0);
    final pad = compact ? 16.0 : 28.0;
    final gap = compact ? 10.0 : 14.0;
    final tileH = compact ? 62.0 : 84.0;
    final keyH = compact ? 44.0 : 56.0;
    final quickH = compact ? 42.0 : 52.0;
    final btnH = compact ? 52.0 : 64.0;
    final bigFont = compact ? 24.0 : 30.0;

    Widget body = Container(
      width: dialogW,
      padding: EdgeInsets.all(pad),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // 标题行
        Row(children: [
          Text('收款', style: TextStyle(fontSize: compact ? 20 : 24, fontWeight: FontWeight.w800)),
          const Spacer(),
          const Text('应收 ', style: TextStyle(fontSize: 15, color: PosTheme.textSub)),
          Text('¥${Fmt.money(widget.total)}',
              style: TextStyle(fontSize: compact ? 24 : 34, color: PosTheme.accentLive, fontWeight: FontWeight.w800)),
        ]),
        SizedBox(height: gap),
        // 支付方式：按弹窗宽度自动算列数（2/3/4 列），竖屏也不挤
        LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          final cols = w >= 600 ? 4 : (w >= 440 ? 3 : 2);
          final tileW = (w - 12 * (cols - 1)) / cols;
          return Wrap(
            spacing: 12,
            runSpacing: gap,
            children: [
              for (final m in widget.methods) SizedBox(width: tileW, height: tileH, child: _methodTile(m)),
            ],
          );
        }),
        SizedBox(height: gap),
        if (method == '现金') ...[
          // 实收 + 找零
          Row(children: [
            Expanded(child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: compact ? 8 : 14),
              decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('顾客实收', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
                const SizedBox(height: 3),
                Text(received.isEmpty ? '¥ 0.00' : '¥ $received',
                    style: TextStyle(fontSize: bigFont, fontWeight: FontWeight.w800, color: PosTheme.textMain)),
              ]),
            )),
            SizedBox(width: compact ? 8 : 14),
            Expanded(child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: compact ? 8 : 14),
              decoration: BoxDecoration(color: const Color(0xFFF0FFF6), borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('找零', style: TextStyle(fontSize: 13, color: PosTheme.textSub)),
                const SizedBox(height: 3),
                Text('¥${Fmt.money(change)}', style: TextStyle(fontSize: bigFont, fontWeight: FontWeight.w800, color: PosTheme.green)),
              ]),
            )),
          ]),
          SizedBox(height: gap),
          if (mollen > 0) ...[
            // 抹零已生效提示（v3.3.239 切换按钮移入数字键盘 0 后）
            Row(children: [
              const Spacer(),
              Text('已优惠 ¥${Fmt.money(mollen)}，应收 ¥${Fmt.money(payable)}',
                  style: const TextStyle(fontSize: 12.5, color: Colors.green, fontWeight: FontWeight.w700)),
            ]),
            SizedBox(height: gap),
          ],
          // 快捷金额
          Row(children: [
            for (final v in [50.0, 100.0, 200.0, payable]) ...[
              Expanded(child: InkWell(
                onTap: () => setState(() => received = Fmt.money(v)),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  height: quickH, alignment: Alignment.center,
                  decoration: BoxDecoration(border: Border.all(color: PosTheme.line), borderRadius: BorderRadius.circular(10)),
                  child: Text(v == payable ? '刚好' : '¥${v.toInt()}',
                      style: TextStyle(fontSize: compact ? 15 : 17, fontWeight: FontWeight.w700, color: PosTheme.textMain)),
                ),
              )),
              SizedBox(width: compact ? 6 : 10),
            ]
          ]),
          SizedBox(height: gap),
          // 数字键盘
          _keypad(keyH),
        ] else if (method != null) ...[
          Container(
            padding: EdgeInsets.symmetric(vertical: compact ? 14 : 30),
            alignment: Alignment.center,
            child: Column(children: [
              _methodIcon(method!, size: compact ? 42 : 56),
              SizedBox(height: compact ? 8 : 12),
              Text(method == '会员支付'
                      ? '将从「${widget.vip?['name'] ?? widget.vip?['phone'] ?? ''}」余额扣除 ¥${Fmt.money(widget.total)}'
                      : method == '扫码收款' || method == '微信支付' || method == '支付宝'
                          ? '点「确认收款」后用扫码枪扫顾客付款码（微信/支付宝自动识别）'
                          : '确认到账后点击下方「确认收款」',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, color: PosTheme.textSub)),
              SizedBox(height: compact ? 4 : 6),
              Text(
                  method == '会员支付'
                      ? '当前余额 ¥${Fmt.money((double.tryParse('${widget.vip?['amount'] ?? 0}') ?? 0) + (double.tryParse('${widget.vip?['gift_balance'] ?? 0}') ?? 0))}'
                      : method == '扫码收款' || method == '微信支付' || method == '支付宝'
                          ? '扫码成功自动完成收款'
                          : '确认到账后点击下方「确认收款」',
                  style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
            ]),
          ),
        ] else ...[
          Container(
            padding: EdgeInsets.symmetric(vertical: compact ? 14 : 30),
            alignment: Alignment.center,
            child: const Text('请先选择收款方式', style: TextStyle(fontSize: 15, color: PosTheme.textHint)),
          ),
        ],
        SizedBox(height: compact ? 12 : 20),
        // 大按钮
        Row(children: [
          Expanded(child: SizedBox(
            height: btnH,
            child: BigButton('取消', onTap: () => Navigator.pop(context),
                color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: btnH),
          )),
          SizedBox(width: compact ? 8 : 14),
          Expanded(flex: 2, child: BigButton('确认收款 ¥${Fmt.money(payable)}',
              onTap: method == null
                  ? null
                  : () => Navigator.pop(context, method == '现金' && mollen > 0
                      ? {'method': '现金', 'mollen': mollen}
                      : method),
              height: btnH)),
        ]),
      ]),
    );

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: EdgeInsets.symmetric(horizontal: 16, vertical: size.height * 0.04),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * 0.92),
        child: SingleChildScrollView(child: body),
      ),
    );
  }

  /// 选择支付方式（v3.3.177 复用餐饮免确认直通）：
  /// 微信/支付宝点卡片直接弹付款码，扫码成功带支付流水关单，跳过「确认收款」按钮；
  /// 其余方式照旧选中后手动确认
  Future<void> _pick(String m) async {
    if (m != '微信支付' && m != '支付宝') {
      setState(() => method = m);
      return;
    }
    final orderNo = 'XYFR${DateTime.now().millisecondsSinceEpoch}'
        '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
    final pay = await showXyfScanPayDialog(context,
        amount: widget.total, title: '扫码收款 · $m', bizType: 'retail', orderNo: orderNo);
    if (!mounted) return;
    if (pay == null) {
      // 扫码取消：不记账，收回选中状态，防止误点「确认收款」造成记账式收款
      setState(() => method = null);
      return;
    }
    Navigator.pop(context, {
      'method': m,
      'xyf_order_no': '${pay['orderNo'] ?? orderNo}',
      'xyf_channel': int.tryParse('${pay['order']?['pay_channel'] ?? 0}') ?? 0,
    });
  }

  Widget _methodTile(String m) {
    final on = method == m;
    final disabled = m == '会员支付' && widget.vip == null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: disabled ? null : () => _pick(m),
      child: Container(
        decoration: BoxDecoration(
          color: on ? _colorOf(m).withOpacity(0.1) : const Color(0xFFF7F8FA),
          border: Border.all(color: on ? _colorOf(m) : Colors.transparent, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          _methodIcon(m, size: 30, color: disabled ? PosTheme.textHint : _colorOf(m)),
          const SizedBox(height: 6),
          Text(m + (disabled ? '（未选会员）' : ''),
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: disabled ? PosTheme.textHint : PosTheme.textMain)),
        ]),
      ),
    );
  }

  Widget _keypad(double keyH) {
    const keys = [
      ['1', '2', '3', '<'],
      ['4', '5', '6', 'C'],
      ['7', '8', '9', '.'],
    ];
    return Column(children: [
      for (int r = 0; r < 3; r++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            for (int c = 0; c < 4; c++) ...[
              Expanded(child: _keyBtn(keys[r][c], keyH)),
              if (c < 3) const SizedBox(width: 8),
            ]
          ]),
        ),
      // 底行：0 占两格，后面是抹零键（v3.3.239 移入；小数点在第三行、退格在第一行保留）
      Row(children: [
        Expanded(flex: 2, child: _keyBtn('0', keyH)),
        const SizedBox(width: 8),
        Expanded(child: _mollenKey(1, '抹分', mollenType == 1, keyH)),
        const SizedBox(width: 8),
        Expanded(child: _mollenKey(2, '抹角', mollenType == 2, keyH)),
      ]),
    ]);
  }

  /// 抹零键位（v3.3.239）：样式对齐数字键，选中态绿色高亮
  Widget _mollenKey(int type, String label, bool on, double keyH) {
    return InkWell(
      onTap: () => setState(() => mollenType = mollenType == type ? 0 : type),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: keyH,
        decoration: BoxDecoration(
          color: on ? Colors.green.withOpacity(0.14) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? Colors.green : Colors.transparent, width: 1.5),
        ),
        child: Center(child: Text(label, style: TextStyle(
            fontSize: 17, fontWeight: FontWeight.w700,
            color: on ? Colors.green : PosTheme.textSub))),
      ),
    );
  }

  Widget _keyBtn(String k, double keyH) {
    final isClear = k == 'C';
    return InkWell(
      onTap: () => _key(k),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: keyH,
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
                ? Center(child: CircularProgressIndicator(color: PosTheme.accentLive))
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

  /// 无图占位（v3.3.204）：不再整块灰底拉满，改为浅色底 + 居中圆角小块，
  /// 商品大多无图时卡片不再显得空旷
  Widget _placeholder() => LayoutBuilder(builder: (ctx, c) {
        final side = c.maxHeight < c.maxWidth ? c.maxHeight : c.maxWidth;
        final box = (side * 0.6).clamp(46.0, 96.0).toDouble();
        return Container(
          color: const Color(0xFFFAFBFC),
          alignment: Alignment.center,
          child: Container(
            width: box, height: box,
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F7),
              borderRadius: BorderRadius.circular(box * 0.26),
            ),
            child: Icon(Icons.fastfood, color: PosTheme.textHint, size: box * 0.42),
          ),
        );
      });

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

/// 清空购物车权限密码弹窗（v3.3.192）：数字键盘 + 输满 6 位自动云端校验
/// 密码 = 云端员工权限密码（与退款 / 现金充值同一套），本机不保存
class _ClearPinDialog extends StatefulWidget {
  final int count;
  final double total;
  const _ClearPinDialog({required this.count, required this.total});
  @override
  State<_ClearPinDialog> createState() => _ClearPinDialogState();
}

class _ClearPinDialogState extends State<_ClearPinDialog> {
  static const int codeLen = 6; // 6 位数字，与退款弹窗一致
  String input = '';
  String? err;
  bool verifying = false;

  Future<void> _press(String d) async {
    if (verifying || input.length >= codeLen) return;
    setState(() {
      input += d;
      err = null;
    });
    if (input.length < codeLen) return;
    setState(() => verifying = true);
    final r = await ClearPin.verify(input);
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        err = r.msg.isEmpty ? '权限密码错误，请重试' : r.msg;
        input = '';
        verifying = false;
      });
    }
  }

  void _back() {
    if (input.isEmpty) return;
    setState(() => input = input.substring(0, input.length - 1));
  }

  Widget _dot(bool filled) => Container(
        width: 15,
        height: 15,
        margin: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? PosTheme.accent : const Color(0xFFF0F1F5),
          border: Border.all(color: filled ? PosTheme.accent : const Color(0xFFD8DBE2)),
        ),
      );

  Widget _key({String label = '', VoidCallback? onTap, Widget? child, Color? fg}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Material(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(
              height: 54,
              alignment: Alignment.center,
              child: child ??
                  Text(label,
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600, color: fg ?? PosTheme.textMain)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 360,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Icon(Icons.lock_outline, size: 20, color: PosTheme.accent),
            const SizedBox(width: 8),
            const Text('输入权限密码', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const Spacer(),
            InkWell(
              onTap: () => Navigator.pop(context, false),
              borderRadius: BorderRadius.circular(16),
              child: const SizedBox(width: 32, height: 32, child: Icon(Icons.close, size: 20, color: PosTheme.textHint)),
            ),
          ]),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('清空将移除 ${widget.count} 件商品（¥${Fmt.money(widget.total)}），请输入 6 位权限密码确认。',
                style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
          ),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < codeLen; i++) _dot(i < input.length),
          ]),
          SizedBox(
            height: 34,
            child: Center(
              child: Text(err ?? (verifying ? '校验中…' : ''),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: TextStyle(fontSize: 12.5, color: verifying ? PosTheme.textHint : PosTheme.red)),
            ),
          ),
          Row(children: [
            _key(label: '1', onTap: () => _press('1')),
            _key(label: '2', onTap: () => _press('2')),
            _key(label: '3', onTap: () => _press('3')),
          ]),
          Row(children: [
            _key(label: '4', onTap: () => _press('4')),
            _key(label: '5', onTap: () => _press('5')),
            _key(label: '6', onTap: () => _press('6')),
          ]),
          Row(children: [
            _key(label: '7', onTap: () => _press('7')),
            _key(label: '8', onTap: () => _press('8')),
            _key(label: '9', onTap: () => _press('9')),
          ]),
          Row(children: [
            _key(
              label: '取消',
              fg: PosTheme.textSub,
              onTap: () => Navigator.pop(context, false),
            ),
            _key(label: '0', onTap: () => _press('0')),
            _key(
              child: const Icon(Icons.backspace_outlined, size: 21, color: PosTheme.textSub),
              onTap: _back,
            ),
          ]),
        ]),
      ),
    );
  }
}

/// 挂单列表弹窗（v3.3.191）：恢复 / 删除
class _HoldListDialog extends StatefulWidget {
  final List<Map<String, dynamic>> holds;
  final void Function(Map<String, dynamic>) onRestore;
  final void Function(Map<String, dynamic>) onDelete;
  const _HoldListDialog({required this.holds, required this.onRestore, required this.onDelete});

  @override
  State<_HoldListDialog> createState() => _HoldListDialogState();
}

class _HoldListDialogState extends State<_HoldListDialog> {
  String _holdTitle(Map h) {
    final items = (h['items'] as List?) ?? const [];
    final total = items.fold<double>(0, (s, e) {
      final g = (e as Map)['goods'] as Map? ?? {};
      final price = double.tryParse('${g['amount'] ?? 0}') ?? 0;
      final qty = (e['num'] as num?)?.toDouble() ?? 0;
      return s + price * qty;
    });
    final cnt = items.fold<int>(0, (s, e) => s + (((e as Map)['num'] as num?)?.round() ?? 0));
    final vip = h['vip'] as Map?;
    return '共 $cnt 件 · ¥${Fmt.money(total)}${vip == null ? '' : ' · 会员 ${vip['name'] ?? vip['phone']}'}';
  }

  @override
  Widget build(BuildContext context) {
    final holds = widget.holds;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 520,
        constraints: const BoxConstraints(maxHeight: 620),
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Icon(Icons.bookmark_border_rounded, size: 22, color: PosTheme.accent),
            const SizedBox(width: 8),
            const Text('挂单列表', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            Text('${holds.length} 单', style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
            const Spacer(),
            InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(16),
              child: const SizedBox(width: 32, height: 32, child: Icon(Icons.close, size: 20, color: PosTheme.textHint)),
            ),
          ]),
          const SizedBox(height: 6),
          const Text('点「取单」把挂单恢复到购物车继续收银，按时间从新到旧排列（最多保留 20 单）。',
              style: TextStyle(fontSize: 12, color: PosTheme.textHint)),
          const SizedBox(height: 10),
          Flexible(
            child: holds.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: Text('暂无挂单', style: TextStyle(fontSize: 14.5, color: PosTheme.textHint))),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: holds.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final h = holds[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF7F8FA),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: PosTheme.line),
                        ),
                        child: Row(children: [
                          Container(
                            width: 34, height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: PosTheme.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(17)),
                            child: Text('${i + 1}', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: PosTheme.accent)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(_holdTitle(h), maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text('挂单时间 ${h['time'] ?? ''}', style: const TextStyle(fontSize: 12, color: PosTheme.textSub)),
                          ])),
                          InkWell(
                            onTap: () => widget.onRestore(h),
                            borderRadius: BorderRadius.circular(9),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                              decoration: BoxDecoration(color: PosTheme.accent, borderRadius: BorderRadius.circular(9)),
                              child: const Text('取单', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
                            ),
                          ),
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: () {
                              widget.onDelete(h);
                              setState(() {}); // 本弹窗自刷新（列表引用与父级共享）
                            },
                            borderRadius: BorderRadius.circular(9),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(color: PosTheme.line),
                              ),
                              child: const Icon(Icons.delete_outline, size: 18, color: PosTheme.textSub),
                            ),
                          ),
                        ]),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
