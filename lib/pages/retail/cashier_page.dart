import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/api.dart';
import '../../core/cart_prefs.dart';
import '../../core/cart_store.dart';
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
import '../../ui/num_keypad.dart';
import '../../ui/touch_keyboard.dart';
import '../../ui/vip_avatar.dart';
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
    return Fmt.unit(g['danwei']); // 空/'null'/'undefined' 一律兜底 kg
  }
}

class _RetailCashierPageState extends State<RetailCashierPage> {
  List cats = [];
  List goods = [];
  int selectedCat = -1; // -1 全部
  String keyword = '';
  bool loading = true;
  String? error;
  bool refreshing = false; // 手动刷新商品中（v3.3.277，改价后强拉全量）

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
  // 购物车本地持久化（v3.3.255）：切页面/重启不丢，删除或清空才消失
  static const _cartPersistKey = 'retail_cart';
  Map? vip; // 选中的会员
  int couponSel = 0; // 优惠券档位（v3.3.242）：0未选 1=5元券 2=8.4元券(满16.8)，互斥单选
  bool get couponOn => couponSel > 0; // 兼容旧引用（v3.3.219 语义：有券在用）
  double wholeRate = 0; // 整单折扣（v3.3.246）：8.5 = 8.5折，0 无；与整单改价互斥
  double wholePrice = 0; // 整单改价（v3.3.246）：>0 时直接按此价收款（禁止 0 元购）

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
    DisplayPrefs.goodsSort.addListener(_onDisplayChanged); // 商品排序改动即时刷新（v3.3.266）
    ThemePrefs.skinId.addListener(_onDisplayChanged); // 主体风格换色即时刷新
    _initScaleBar(); // 常驻称重条（v3.3.207，仅 Windows/安卓；mac 保持原样）
    // 副屏（客显）：把当前购物车实时推到第二块屏，600ms 一次，未开副屏时为无操作
    _cdTimer = Timer.periodic(const Duration(milliseconds: 600), (_) => _publishCd());
    _loadHolds();
    _loadCartLocal(); // 恢复上次未结算的购物车（v3.3.255）
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
    DisplayPrefs.goodsSort.removeListener(_onDisplayChanged);
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
      // 方案 C（v3.3.276b）：有缓存先秒显（loading 提前结束），后台带指纹校验；
      // 数据没变零流量保持缓存，变了返回全量刷新
      final r = await Api.goodsAllCached(Session.wenxunId, onCache: (c) {
        if (!mounted) return;
        setState(() { cats = c['cat']; goods = c['goods']; loading = false; });
      });
      if (!mounted) return;
      if (r == null) return;
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

  /// 手动刷新商品（v3.3.277）：改价/改库存后强拉全量，跳过缓存直取最新并回写
  Future<void> _refreshGoods() async {
    if (refreshing) return;
    setState(() => refreshing = true);
    try {
      final r = await Api.goodsAllCached(Session.wenxunId, force: true);
      if (!mounted) return;
      if (r != null) {
        setState(() {
          cats = r['cat'] ?? [];
          goods = r['goods'] ?? [];
        });
      }
      toast(context, '商品已刷新');
    } on ApiError catch (e) {
      if (!mounted) return;
      toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  /// 刷新按钮（v3.3.277，搜索框右侧与触屏键盘按钮同款 48×48）
  Widget _refreshBtn() {
    return SizedBox(
      width: 48,
      height: 48,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: PosTheme.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _refreshGoods,
          child: refreshing
              ? Padding(
                  padding: const EdgeInsets.all(13),
                  child: CircularProgressIndicator(strokeWidth: 2.4, color: PosTheme.accentLive),
                )
              : Tooltip(
                  message: '刷新商品（改价后点此同步最新价格）',
                  child: Icon(Icons.refresh, size: 24, color: PosTheme.textSub),
                ),
        ),
      ),
    );
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
    // 商品排序（v3.3.266）：设置页可选销量/添加时间/价格/名称，本机保存即时生效
    return DisplayPrefs.sortGoods(g.toList(), DisplayPrefs.goodsSort.value);
  }

  double get total => cart.fold<double>(0, (s, l) => s + l.unitPrice * l.payNum);
  // 件数：按件商品累加数量，称重行按 1 笔计
  int get count => cart.fold(0, (s, l) => s + (l.byWeight ? 1 : l.num.round()));

  /// 优惠券档位（v3.3.247 三档）：5元券（合计>5可用）/ 8.4元券（必须满16.8）/ 40元券（无门槛直接扣，可0元购）
  static const double couponValue = 5.0;
  static const double coupon2Value = 8.4;
  static const double coupon2Threshold = 16.8;
  static const double coupon3Value = 40.0;
  /// 整单优惠基数（v3.3.246）：活动优惠后的金额
  double get wholeBase => total - actDiscount;
  /// 折扣文本：8.5 → '8.5'，8 → '8'
  String _rateText(double r) {
    var s = r.toStringAsFixed(1);
    if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
    return s;
  }
  /// 整单折扣优惠金额（v3.3.246）：基数 × (10-折扣)/10
  double get wholeCut {
    if (wholeRate <= 0 || wholeRate >= 10) return 0;
    final c = wholeBase * (10 - wholeRate) / 10;
    return c > 0 ? double.parse(c.toStringAsFixed(2)) : 0;
  }
  /// 整单改价优惠金额（v3.3.246）：活动后合计 - 改价
  double get wholeRepriceCut {
    if (wholePrice <= 0) return 0;
    final c = wholeBase - wholePrice;
    return c > 0 ? double.parse(c.toStringAsFixed(2)) : 0;
  }
  /// 券的门槛基数：活动/整单折扣后的金额（v3.3.222）
  double get couponBase => wholeBase - wholeCut;
  /// 优惠券实际抵扣：按所选档位核算；不达门槛/不足面额不生效（避免 0 元单）
  /// 40元券（v3.3.247）：无门槛、直接扣除 40，允许 0 元购
  double get couponApplied {
    if (couponSel == 1) return couponBase > couponValue ? couponValue : 0;
    if (couponSel == 2) return couponBase >= coupon2Threshold ? coupon2Value : 0;
    if (couponSel == 3) return coupon3Value;
    return 0;
  }
  /// 应收金额 = 合计 - 活动优惠 - 整单折扣 - 优惠券抵扣（v3.3.246 整单折扣/改价接入）
  /// 整单改价时直接按改价收款；最低 0.01 元，不产生 0 元单
  /// 例外：40元券（v3.3.247）直接扣除、允许 0 元购，扣完为负按 0 收
  double get payable {
    final v = wholePrice > 0
        ? wholePrice
        : total - actDiscount - wholeCut - couponApplied;
    if (couponSel == 3) {
      final r = double.parse(v.toStringAsFixed(2));
      return r > 0 ? r : 0;
    }
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
    return Fmt.unit(g['danwei']); // 空/'null'/'undefined' 一律兜底 kg
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
    _saveCartLocal();
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
    _saveCartLocal();
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
    _saveCartLocal();
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
    _saveCartLocal();
  }

  /// 删除单行商品（带 4 秒撤销）
  void _removeLine(_CartLine l) {
    final i = cart.indexOf(l);
    if (i < 0) return;
    setState(() => cart.removeAt(i));
    _saveCartLocal();
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
          _saveCartLocal();
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
    setState(() {
      cart.clear();
      vip = null;
      couponSel = 0; // 优惠券随清空重置（v3.3.219）
      wholeRate = 0; // 整单折扣随清空重置（v3.3.246）
      wholePrice = 0; // 整单改价随清空重置（v3.3.246）
    });
    _saveCartLocal();
  }

  // ==================== 整单折扣 / 整单改价（v3.3.246） ====================

  /// 整单折扣：数字键盘输入折扣数，最低 5 折，5 折以上自定义（8.5 = 8.5折）
  /// 输 0 清除已设折扣；与整单改价互斥
  Future<void> _editWholeRate() async {
    if (cart.isEmpty) return;
    final v = await showNumberPad(
      context,
      title: '整单折扣',
      hint: '输入折扣数（最低 5 折），如 8.5 = 8.5折；输 0 清除折扣',
      initial: wholeRate > 0 ? _rateText(wholeRate) : '',
      decimal: true,
      allowZero: true,
    );
    if (v == null || !mounted) return;
    if (v <= 0) {
      setState(() => wholeRate = 0);
      return;
    }
    if (v < 5 || v > 9.9) {
      toast(context, '折扣只能在 5折 ~ 9.9折 之间', error: true);
      return;
    }
    setState(() {
      wholeRate = v;
      wholePrice = 0; // 折扣与改价互斥
    });
  }

  /// 整单改价：直接输入整单应收价（需权限密码，与单行改价一致）
  /// 禁止 0 元购（最低 0.01）、不能高于活动后合计；输 0 清除改价
  Future<void> _editWholePrice() async {
    if (cart.isEmpty) return;
    if (!await _authPrice()) return; // 改价需权限密码（设置里开启时）
    final maxP = wholeBase; // 活动优惠后的合计（改价上限，防乱改多收）
    final v = await showNumberPad(
      context,
      title: '整单改价',
      hint: '直接输入整单应收价（¥0.01 ~ ¥${Fmt.money(maxP)}），输 0 清除改价',
      initial: wholePrice > 0 ? Fmt.money(wholePrice) : '',
      decimal: true,
      prefix: '¥',
      allowZero: true,
    );
    if (v == null || !mounted) return;
    if (v <= 0) {
      setState(() => wholePrice = 0);
      return;
    }
    if (v > maxP + 0.001) {
      toast(context, '改价不能高于活动后合计 ¥${Fmt.money(maxP)}', error: true);
      return;
    }
    setState(() {
      wholePrice = double.parse(v.toStringAsFixed(2));
      wholeRate = 0; // 折扣与改价互斥
      couponSel = 0; // 改价即最终价，优惠券一并清除
    });
  }

  // ==================== 挂单 / 取单（v3.3.191） ====================

  // ---- 购物车本地持久化（v3.3.255）：切页面/重启不丢，删除或清空才消失 ----
  void _loadCartLocal() {
    CartStore.load(_cartPersistKey).then((list) {
      if (!mounted || cart.isNotEmpty || list.isEmpty) return;
      setState(() {
        for (final m in list) {
          cart.add(_CartLine(
            Map<String, dynamic>.from(m['goods'] as Map),
            (m['num'] as num?)?.toDouble() ?? 1,
            price: (m['price'] as num?)?.toDouble(),
            giftQty: (m['gift_qty'] as num?)?.toDouble() ?? 0,
          ));
        }
      });
    });
  }

  void _saveCartLocal() {
    CartStore.save(_cartPersistKey, [
      for (final l in cart)
        {'goods': l.goods, 'num': l.num, 'price': l.price, 'gift_qty': l.giftQty},
    ]);
  }

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
      wholeRate = 0; // 挂单不携带整单折扣（v3.3.246）
      wholePrice = 0;
    });
    await _saveHolds();
    _saveCartLocal(); // 挂单后购物车已清空，同步本地（v3.3.255）
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
      couponSel = 0; // 取单重置优惠券（v3.3.219）
      wholeRate = 0; // 取单重置整单折扣/改价（v3.3.246）
      wholePrice = 0;
    });
    await _saveHolds();
    _saveCartLocal(); // 取单替换了购物车，同步本地（v3.3.255）
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
    double t = payable; // 应收（含优惠券/整单折扣抵扣，v3.3.246；现金抹零后可减）
    final coupon = couponApplied; // 本次抵扣金额（小票打印用）
    final wRate = wholeRate; // 整单折扣快照（v3.3.246，清空购物车前取）
    final wCut = wholePrice > 0 ? wholeRepriceCut : wholeCut; // 整单优惠总额
    final wReprice = wholePrice > 0; // 是否整单改价
    final order = await PayMethods.load();

    // v3.3.251：去掉旧「快捷通道」第二次弹窗（先弹扫码再换方式的流程），
    // 点「收款」直接进统一收款弹窗，弹窗内自动选中默认支付方式并聚焦付款码，扫码即收

    // 未选会员时不出现「会员支付」，避免误点；按商户「支付方式排序」展示（v3.3.176 全场景复用）
    // v3.3.251：去掉「微信支付」「支付宝」独立选项——走星驿付付款码自动识别渠道，
    // 扫码收款一项即可（弹窗内用四个品牌图标标识）
    final methods = ['现金', '扫码收款', if (vip != null) '会员支付']
      ..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    // 0元购（v3.3.247 40元券直接扣完）：免支付方式选择，按现金落单（0 元单不弹钱箱）
    if (t <= 0) {
      return _finishOrder('现金', t, coupon: coupon,
          wholeRate: wRate, wholeCutAmt: wCut, wholeReprice: wReprice);
    }
    // 默认选中方式：商户排序第一在可用列表里就选它；商户原配的是微信/支付宝
    // （现已合并进扫码收款）则落到扫码收款，保证扫码枪商户进弹窗即可扫
    final defMethod = (order.isNotEmpty && methods.contains(order.first))
        ? order.first
        : (methods.contains('扫码收款') ? '扫码收款' : methods.first);
    final picked = await showDialog<dynamic>(
      context: context,
      barrierDismissible: false, // 防误触：点遮罩不关弹窗，避免支付中弹窗被意外关闭
      builder: (_) => RetailPayDialog(total: t, vip: vip, methods: methods, defaultMethod: defMethod),
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
    // 组合支付（v3.3.258）：弹窗带回 2-3 笔支付明细，走 combo_pay 落单，
    // 会员部分由后端在落单时扣余额，扫码部分各自带星驿流水
    final comboRaw = (picked is Map) ? picked['combo'] : null;
    if (comboRaw is List && comboRaw.length >= 2) {
      final lines = <Map<String, dynamic>>[];
      for (final l in comboRaw) {
        if (l is! Map) continue;
        String m = '${l['method']}';
        final ch = int.tryParse('${l['xyf_channel'] ?? 0}') ?? 0;
        if (m == '扫码收款' && ch > 0) {
          m = ch == 1 ? '支付宝'
              : (ch == 2 ? '微信支付'
              : (ch == 9 ? '云闪付' : '其他支付'));
        }
        lines.add({
          'method': m,
          'amount': double.tryParse('${l['amount'] ?? 0}') ?? 0,
          'pay_order_no': '${l['xyf_order_no'] ?? ''}',
          'pay_channel': ch,
        });
      }
      if (lines.length >= 2) {
        await _finishOrder(lines.first['method'] as String, t,
            coupon: coupon,
            wholeRate: wRate, wholeCutAmt: wCut, wholeReprice: wReprice,
            comboLines: lines);
        return;
      }
    }
    // 扫码收款按星驿渠道落具体支付方式（v3.3.251 修复：之前落库成「其他支付」）：
    // 桌面端直接映射，与后端 Order.php 口径一致（1支付宝 2微信 9云闪付，其余其他支付），
    // 不再依赖服务端映射是否生效
    if (pickedMethod == '扫码收款' && xyfChannel > 0) {
      pickedMethod = xyfChannel == 1 ? '支付宝'
          : (xyfChannel == 2 ? '微信支付'
          : (xyfChannel == 9 ? '云闪付' : '其他支付'));
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
      xyfChannel = (pay['channel'] as int?) ?? int.tryParse('${pay['order']?['pay_channel'] ?? 0}') ?? 0;
    }
    await _finishOrder(pickedMethod, t, coupon: coupon, mollen: mollen,
        wholeRate: wRate, wholeCutAmt: wCut, wholeReprice: wReprice,
        xyfOrderNo: xyfOrderNo, xyfChannel: xyfChannel);
  }

  /// 落单执行（v3.3.177 从 _checkout 拆出）：会员扣款 / 扫码 / 现金统一收口
  /// [coupon] 优惠券抵扣金额（v3.3.219），[mollen] 现金抹零（v3.3.238），t 为抵扣后的应收
  /// [wholeRate] 整单折扣（8.5 = 8.5折，v3.3.246），[wholeCutAmt] 整单优惠总额，
  /// [wholeReprice] 是否整单改价（true 时 wholeCutAmt = 改价差额）
  Future<void> _finishOrder(String picked, double t,
      {double coupon = 0, double mollen = 0,
       double wholeRate = 0, double wholeCutAmt = 0, bool wholeReprice = false,
       String xyfOrderNo = '', int xyfChannel = 0,
       List<Map<String, dynamic>> comboLines = const []}) async {
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
    // 组合支付（comboLines 非空）不走这里——会员部分由 order/add 后端扣（v3.3.258）
    if (picked == '会员支付' && comboLines.isEmpty) {
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
          renyuanId: Session.staffId, // 会员单归属收银员（v3.3.240，交班统计）
          cashierName: Session.staffName,
          wholeRate: wholeRate, // 整单折扣/改价落库（v3.3.246）
          wholeAmount: wholeCutAmt,
        );
        if (!mounted) return;
        Navigator.pop(context); // loading
        if ('${r['code']}' != '200') {
          toast(context, '${r['msg'] ?? '会员扣款失败'}', error: true);
          return;
        }
        final orderNo = '${r['order_number'] ?? r['order_id'] ?? ''}';
        // 会员支付后剩余金额（v3.3.249）：优先后端返回的 balance，未返回时按本机余额扣减兜底
        final balAfter = double.tryParse('${r['balance'] ?? ''}') ??
            double.parse((_vipBalance() - t).toStringAsFixed(2));
        if (await PrintPrefs.on('retail')) {
          CloudPrinter.printRetail(
            CloudPrinter.retailReceipt(
              orderNo: orderNo, payMethod: picked, total: t, coupon: coupon,
              activityDiscount: act.discount, activityLines: act.labels, mollen: mollen,
              wholeDiscount: wholeCutAmt, // 整单折扣/改价小票行（v3.3.246）
              wholeLabel: wholeReprice ? '整单改价' : (wholeRate > 0 ? '整单折扣 ${_rateText(wholeRate)}折' : ''),
              gifts: [
                for (final g in act.gifts)
                  {'name': g.title, 'quantity': g.qty, 'unit': g.byWeight ? g.unit : '', 'byWeight': g.byWeight},
              ],
              cart: cart.map((l) => {'name': l.goods['title'], 'price': l.unitPrice, 'quantity': l.payNum, 'unit': l.byWeight ? l.unit : '', 'gift_qty': l.giftQty}).toList(),
              vipName: '${vip!['name'] ?? vip!['xm'] ?? ''}', // 会员昵称/手机号（v3.3.249）
              vipPhone: '${vip!['phone'] ?? ''}',
              vipBalance: balAfter, // 卡内余额（会员支付专用）
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
        wholeRate: wholeRate, // 整单折扣/改价落库（v3.3.246）
        wholeAmount: wholeCutAmt,
        comboPay: comboLines, // 组合支付明细（v3.3.258，≥2 笔才传）
      );
      if (!mounted) return;
      Navigator.pop(context);
      final orderNo = '${r['orderNumber'] ?? r['order_number'] ?? ''}';

      // 现金结算自动弹钱箱（v3.3.202，异步不阻塞收银；0 元单不弹，v3.3.247）
      if (t > 0) CashDrawer.autoOpen(picked);

      // 云打印（异步，不阻塞收银；小票开关 v3.3.77）
      // 组合支付小票支付方式行：逐笔列出「微信支付¥60.00+现金¥20.00+…」（v3.3.258）
      final payMethodText = comboLines.length >= 2
          ? comboLines.map((l) => '${l['method']}¥${Fmt.money((l['amount'] as num?)?.toDouble() ?? 0)}').join('+')
          : picked;
      if (await PrintPrefs.on('retail')) {
        CloudPrinter.printRetail(
          CloudPrinter.retailReceipt(
            orderNo: orderNo, payMethod: payMethodText, total: t, coupon: coupon,
            activityDiscount: act.discount, activityLines: act.labels, mollen: mollen,
            wholeDiscount: wholeCutAmt, // 整单折扣/改价小票行（v3.3.246）
            wholeLabel: wholeReprice ? '整单改价' : (wholeRate > 0 ? '整单折扣 ${_rateText(wholeRate)}折' : ''),
            gifts: [
              for (final g in act.gifts)
                {'name': g.title, 'quantity': g.qty, 'unit': g.byWeight ? g.unit : '', 'byWeight': g.byWeight},
            ],
            cart: cart.map((l) => {'name': l.goods['title'], 'price': l.unitPrice, 'quantity': l.payNum, 'unit': l.byWeight ? l.unit : '', 'gift_qty': l.giftQty}).toList(),
            // 选中会员时打「会员」行（v3.3.249）；余额只在会员支付分支打
            vipName: vip == null ? '' : '${vip!['name'] ?? vip!['xm'] ?? ''}',
            vipPhone: vip == null ? '' : '${vip!['phone'] ?? ''}',
          ),
          alsoCloud: cart.any((l) => l.byWeight), // 称重订单云打印机同步一份（v3.3.214）
        ).catchError((_) => <String, dynamic>{});
      }

      _clearCart();
      showDialog(context: context, builder: (_) => _SuccessDialog(orderNo: orderNo, total: t, method: comboLines.length >= 2 ? '组合支付' : picked));
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
                  : isMarket
                  ? _marketBody() // 商超版（v3.3.282）：大型超市扫码收银布局，无商品列表/分类栏
                  : Row(
                      children: cartSide == 'left'
                          ? [
                              _cartPanel(), // 购物车在左（v3.3.189 可配置）
                              Expanded(child: isCloth ? _goodsList() : _goodsGrid()), // 服装版=列表逛选布局
                              _catRail(indicatorRight: true), // 分类栏在最右，选中线显示在右侧
                            ]
                          : [
                              _catRail(),
                              Expanded(child: isCloth ? _goodsList() : _goodsGrid()), // 服装版=列表逛选布局
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
          if (isMarket) ...[
            const SizedBox(width: 10),
            _marketVipBtn(), // 商超版：会员入口放顶栏（无码商品后面，v3.3.282）
          ],
          const SizedBox(width: 10),
          _kbBtn(),
          const SizedBox(width: 10),
          _refreshBtn(),
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
      child: PosField(
        controller: searchCtrl,
        focusNode: searchKeeper.node,
        compact: true,
        hint: '搜索商品名称 / 简拼 / 条码',
        icon: Icons.search_rounded,
        iconColor: PosTheme.textSub,
        onChanged: _onSearchChanged,
        // 商超版（v3.3.282）：手输条码回车立即加购；16-32 位付款码直接收款
        onSubmitted: (v) {
          final t = v.trim();
          if (!isMarket || !RegExp(r'^\d+$').hasMatch(t)) return;
          scanDebounce?.cancel();
          if (DisplayPrefs.marketDirectPay.value && RegExp(r'^\d{16,32}$').hasMatch(t)) {
            _marketDirectPay(t);
          } else if (t.length >= 6) {
            _tryScanAdd(t);
          }
        },
        suffix: keyword.isEmpty ? null : _clearBtn(),
      ),
    );
  }

  /// 搜索/扫码输入：普通关键词直接过滤；扫到条码秤标签（2 前缀 13 位）自动解析入购物车
  /// 超市便利店视图（v3.3.282）：纯数字 ≥6 位防抖精确匹配条码，直接加购
  void _onSearchChanged(String v) {
    setState(() => keyword = v.trim());
    scanDebounce?.cancel();
    final t = v.trim();
    if (!RegExp(r'^2\d{12}$').hasMatch(t)) {
      if (isMarket && RegExp(r'^\d+$').hasMatch(t)) {
        // 商超版：16-32 位 = 顾客付款码 → 直接按当前购物车应收发起扫码收款（开关控制，v3.3.282）
        if (DisplayPrefs.marketDirectPay.value && RegExp(r'^\d{16,32}$').hasMatch(t)) {
          scanDebounce = Timer(const Duration(milliseconds: 180), () => _marketDirectPay(t));
          return;
        }
        // 6-15 位 = 商品条码 → 精确匹配直接加购
        if (t.length >= 6) {
          scanDebounce = Timer(const Duration(milliseconds: 180), () => _tryScanAdd(t));
        }
      }
      return; // 走普通搜索
    }
    scanDebounce = Timer(const Duration(milliseconds: 180), () => _tryScaleBarcode(t));
  }

  /// 商超版（v3.3.282）：扫条码精确匹配商品 → 直接加入购物车
  /// 秤标签已在 _onSearchChanged 单独走秤解析；这里兜普通商品条码。
  /// 称重商品（非秤标签扫码）弹称重面板；多规格商品提示回列表点选。
  Future<void> _tryScanAdd(String code) async {
    if (!isMarket || !mounted) return;
    Map? hit;
    for (final g in goods) {
      final c = '${g['code'] ?? g['bianma'] ?? g['barcode'] ?? ''}'.trim();
      if (c.isNotEmpty && c == code) {
        hit = g;
        break;
      }
    }
    if (hit == null) {
      toast(context, '条码 $code 未匹配到商品', error: true);
      searchKeeper.node.requestFocus();
      return;
    }
    if (_hasSpecs(hit)) {
      toast(context, '「${hit['title']}」是多规格商品，请切换回商品列表手动点选', error: true);
      return;
    }
    searchCtrl.clear();
    setState(() => keyword = '');
    searchKeeper.node.requestFocus();
    if (_isWeighted(hit)) {
      await _weighAndAdd(hit);
      _clearKeywordAfterAdd();
    } else {
      _add(hit);
      toast(context, '已加入：${hit['title']}');
    }
  }

  /// 商超版判定
  /// 商超版判定：行业=4 商户固定商超布局
  bool get isMarket => Session.hangye == 4;

  /// 服装版判定：行业=5，专用列表逛选布局
  bool get isCloth => Session.hangye == 5;

  /// 商超版会员按钮（顶栏，无码商品后面，文字+图标，v3.3.282）
  Widget _marketVipBtn() {
    final hasVip = vip != null;
    final label = hasVip
        ? ('${vip!['name'] ?? ''}'.trim().isNotEmpty ? '${vip!['name']}'.trim() : '${vip!['phone'] ?? ''}')
        : '选择会员';
    return SizedBox(
      height: 48,
      child: Material(
        color: hasVip ? PosTheme.tint : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: hasVip ? Colors.transparent : PosTheme.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _pickVip,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(hasVip ? Icons.person : Icons.person_add_alt,
                  size: 20, color: hasVip ? PosTheme.accentLive : PosTheme.textSub),
              const SizedBox(width: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: hasVip ? PosTheme.accentLive : PosTheme.textSub)),
              ),
              if (hasVip) ...[
                const SizedBox(width: 6),
                InkWell(
                  onTap: () => setState(() => vip = null),
                  borderRadius: BorderRadius.circular(14),
                  child: const SizedBox(width: 28, height: 28,
                      child: Icon(Icons.close, size: 16, color: PosTheme.textHint)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  // ==================== 商超版收银布局（v3.3.282，大型超市模式） ====================
  // 主体 = 全宽条码明细表（POS 表格风，支持行内加减数量） + 底部汇总条
  // 无分类栏、无商品网格、无图片；加货 = 扫码枪扫条码 / 手输条码回车 / 无码商品
  // 收款 = 扫顾客付款码直接收（v3.3.282，开关可关），或点底部「收款」进完整结算

  /// 商超版主布局：全宽明细表 + 底部汇总条（v3.3.282 无右侧结算栏）
  Widget _marketBody() {
    return Container(
      color: Colors.white,
      child: Column(children: [
        Expanded(child: _marketTable()),
        _marketBottomBar(),
      ]),
    );
  }

  /// 商超版明细表：表头 + 购物车行
  Widget _marketTable() {
    return Column(children: [
      // 表头（固定）
      Container(
        height: 46,
        color: const Color(0xFFF7F8FA),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(children: const [
          Expanded(flex: 5, child: Text('商品名称', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: PosTheme.textSub))),
          Expanded(flex: 2, child: Text('单价', textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: PosTheme.textSub))),
          Expanded(flex: 3, child: Text('数量', textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: PosTheme.textSub))),
          Expanded(flex: 2, child: Text('金额', textAlign: TextAlign.right, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: PosTheme.textSub))),
          SizedBox(width: 40),
        ]),
      ),
      // 明细行
      Expanded(
        child: cart.isEmpty
            ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.qr_code_scanner_rounded, size: 76, color: PosTheme.accentLive.withOpacity(0.35)),
                const SizedBox(height: 18),
                const Text('扫商品条码加入购物车',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: PosTheme.textMain)),
                const SizedBox(height: 10),
                Text('扫码枪对准条码直接扫；也可在上方搜索框手输条码按回车',
                    style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
                const SizedBox(height: 6),
                Text('无条码商品点左上角「无码商品」；秤标签自动称重',
                    style: TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
              ])
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: cart.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 18, endIndent: 18, color: PosTheme.line),
                itemBuilder: (_, i) => _marketRow(cart[i]),
              ),
      ),
    ]);
  }

  /// 商超版明细行：名称 | 单价 | 数量(步进) | 金额 | 删除
  Widget _marketRow(_CartLine l) {
    final guige = '${l.goods['guige'] ?? ''}'.trim();
    return InkWell(
      onTap: () => _lineEdit(l), // 点行 = 改数量/改价/赠送（v3.3.205 能力全保留）
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 14, 10),
        child: Row(children: [
          // 名称 + 规格角标
          Expanded(
            flex: 5,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text('${l.goods['title']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
                ),
                if (l.price != null) ...[
                  const SizedBox(width: 5),
                  _lineTag('改价', PosTheme.accentLive),
                ],
                if (l.giftQty > 0) ...[
                  const SizedBox(width: 5),
                  _lineTag('赠 ${l.giftText}', Colors.green),
                ],
              ]),
              if (guige.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('规格：$guige', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                ),
            ]),
          ),
          // 单价
          Expanded(
            flex: 2,
            child: Text('¥${Fmt.money(l.unitPrice)}',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, color: PosTheme.textSub)),
          ),
          // 数量步进（称重行点数量弹称重面板）
          Expanded(flex: 3, child: Center(child: _stepper(l))),
          // 金额
          Expanded(
            flex: 2,
            child: Text('¥${Fmt.money(l.unitPrice * l.payNum)}',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
          ),
          // 删除
          InkWell(
            onTap: () => _removeLine(l),
            borderRadius: BorderRadius.circular(18),
            child: const SizedBox(width: 40, height: 40, child: Icon(Icons.close, size: 19, color: PosTheme.textHint)),
          ),
        ]),
      ),
    );
  }

  /// 商超版底部汇总条：清空/挂单 + 合计大字 + 收款（v3.3.282 替代原右侧结算栏）
  Widget _marketBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: PosTheme.line)),
        color: Colors.white,
      ),
      child: Row(children: [
        // 清空 / 挂单（紧凑）
        SizedBox(
          width: 92, height: 48,
          child: BigButton('清空', onTap: cart.isEmpty ? null : _clearCart,
              color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 48),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 92, height: 48,
          child: BigButton(
            holds.isEmpty ? '挂单' : (cart.isEmpty ? '取单 ${holds.length}' : '挂单 ${holds.length}'),
            onTap: (cart.isEmpty && holds.isEmpty) ? null : _holdTap,
            color: PosTheme.tint, textColor: PosTheme.accentLive, height: 48),
        ),
        const SizedBox(width: 16),
        // 合计（活动条 + 金额，主视觉在底栏中央）
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _activityBar(),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('共 $count 件   ', style: const TextStyle(fontSize: 14, color: PosTheme.textSub)),
                Text('合计 ', style: const TextStyle(fontSize: 15, color: PosTheme.textSub)),
                if (couponApplied > 0 || actDiscount > 0 || wholeCut > 0 || wholeRepriceCut > 0) ...[
                  Text('¥${Fmt.money(total)}',
                      style: const TextStyle(fontSize: 16, color: PosTheme.textHint, decoration: TextDecoration.lineThrough)),
                  const SizedBox(width: 8),
                ],
                Text('¥${Fmt.money(payable)}',
                    style: TextStyle(fontSize: 34, color: PosTheme.accentLive, fontWeight: FontWeight.w800)),
                const SizedBox(width: 10),
                if (wholeRate > 0)
                  _wholeTag('整单 ${_rateText(wholeRate)}折 -¥${Fmt.money(wholeCut)}',
                      () => setState(() => wholeRate = 0)),
                if (wholePrice > 0)
                  _wholeTag('整单改价 ¥${Fmt.money(wholePrice)}',
                      () => setState(() => wholePrice = 0)),
              ]),
            ),
          ]),
        ),
        const SizedBox(width: 16),
        // 收款按钮：商超版主要走「扫顾客付款码直接收」，此按钮兜底现金/会员/优惠券结算
        SizedBox(
          width: 170, height: 56,
          child: BigButton('收款', onTap: cart.isEmpty ? null : _checkout, height: 56),
        ),
      ]),
    );
  }

  /// 商超版 · 扫顾客付款码直接收款（v3.3.282）：扫完商品后，收银员直接扫顾客
  /// 微信/支付宝/云闪付付款码（16-32 位），按购物车应收走星驿付付款码支付，
  /// 不弹结算页面。开关：设置 → 收银版本 · 扫码直接收款（商户自定义）。
  bool _marketPaying = false;

  Future<void> _marketDirectPay(String authCode) async {
    if (!isMarket || _marketPaying || !mounted) return;
    if (cart.isEmpty) return;
    final t = payable;
    if (t <= 0) {
      toast(context, '应收 0 元（优惠券扣完），请点「收款」完成 0 元单', error: true);
      return;
    }
    _marketPaying = true;
    loadingDialog(context, '扫码收款 ¥${Fmt.money(t)}…');
    // 预生成我方单号（与零售结算同口径）：支付流水与订单 pay_order_no 关联，退款按此原路退
    final preNo = 'XYFR${DateTime.now().millisecondsSinceEpoch}'
        '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
    try {
      final o = await Api.xyfScanPay(
        amount: t,
        authCode: authCode,
        orderNo: preNo,
        bizType: 'retail',
      );
      if (!mounted) return;
      Navigator.pop(context); // loading
      VoiceService.instance.pay('扫码', t);
      final ch = int.tryParse('${o['pay_channel'] ?? 0}') ?? 0;
      final method = ch == 1 ? '支付宝' : (ch == 2 ? '微信支付' : (ch == 9 ? '云闪付' : '扫码收款'));
      toast(context, '收款成功 ¥${Fmt.money(t)}');
      await _finishOrder(method, t,
          xyfOrderNo: '${o['three_order_no'] ?? o['order_no'] ?? preNo}',
          xyfChannel: ch);
    } on ApiError catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // loading
      toast(context, e.message, error: true);
      searchKeeper.node.requestFocus();
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // loading
      toast(context, '支付失败：$e', error: true);
      searchKeeper.node.requestFocus();
    }
    _marketPaying = false;
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
      _saveCartLocal();
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

  /// 服装版商品列表（v3.3.282，行业=5）：单列大行逛选布局——
  /// 左缩略图 + 名称/规格/价格 + 加购按钮，适合服装鞋帽慢慢翻
  Widget _goodsList() {
    final list = filtered;
    if (list.isEmpty) return const EmptyView('该分类暂无在售商品', icon: Icons.checkroom);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final g = list[i];
        final guige = '${g['guige'] ?? ''}'.trim();
        return InkWell(
          onTap: () => _tapGoods(g),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: PosTheme.line),
            ),
            child: Row(children: [
              // 缩略图（64×64，复用商品图多地址兜底组件）
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 64, height: 64,
                  child: RetailGoodsImage(urls: _imgUrls(g), iconSize: 26),
                ),
              ),
              const SizedBox(width: 12),
              // 名称 + 规格
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${g['title']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
                  if (guige.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text('规格：$guige', maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, color: PosTheme.textHint)),
                    ),
                  const SizedBox(height: 5),
                  Text(_isWeighted(g) ? '¥${Fmt.money(_price(g))}/${_unitOf(g)}' : '¥${Fmt.money(_price(g))}',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: PosTheme.accentLive)),
                ]),
              ),
              const SizedBox(width: 10),
              if (_hasSpecs(g))
                _goodsTag('多规格', PosTheme.accentLive)
              else
                // 加购按钮
                Material(
                  color: PosTheme.accentLive,
                  borderRadius: BorderRadius.circular(22),
                  child: InkWell(
                    onTap: () => _tapGoods(g),
                    borderRadius: BorderRadius.circular(22),
                    child: const SizedBox(
                      width: 46, height: 46,
                      child: Icon(Icons.add_rounded, size: 26, color: Colors.white),
                    ),
                  ),
                ),
            ]),
          ),
        );
      },
    );
  }

  // 购物车（加宽 440，触摸友好）
  /// 购物车排序切换（v3.3.243）：顺序（先点的在前）/ 倒序（最后点的在最上），本机记忆
  Widget _cartOrderToggle() {
    return ValueListenableBuilder<bool>(
      valueListenable: DisplayPrefs.cartNewestFirst,
      builder: (_, newest, __) => InkWell(
        onTap: () async {
          await DisplayPrefs.setCartNewestFirst(!newest);
          if (mounted) setState(() {});
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: newest ? PosTheme.accentLive.withValues(alpha: 0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: newest ? PosTheme.accentLive.withValues(alpha: 0.5) : PosTheme.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(newest ? Icons.south : Icons.north, size: 13, color: newest ? PosTheme.accentLive : PosTheme.textHint),
            const SizedBox(width: 3),
            Text(newest ? '倒序' : '顺序', style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w700,
                color: newest ? PosTheme.accentLive : PosTheme.textHint)),
          ]),
        ),
      ),
    );
  }

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
                  clipBehavior: Clip.antiAlias,
                  child: vip == null
                      ? Icon(Icons.person_add_alt, size: 22, color: PosTheme.accentLive)
                      // v3.3.251：有微信头像就显示微信头像（默认头像图兜底）
                      : VipAvatar(avatarUrl: vipAvatarUrl(vip), radius: 20, rounded: false, fallbackText: vipAvatarChar(vip)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: vip == null
                      ? const Text('点击选择会员（可选）', style: TextStyle(fontSize: 15, color: PosTheme.textSub))
                      : Builder(builder: (_) {
                          // v3.3.250：显示手机号，收银员能核对是不是本人（姓名为空时手机号已在标题，不重复）
                          final phone = '${vip!['phone'] ?? ''}';
                          final name = '${vip!['name'] ?? ''}';
                          final hasName = name.trim().isNotEmpty;
                          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(hasName ? name : phone, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                            Text('${hasName ? '$phone  ' : ''}余额 ¥${Fmt.money(vip!['amount'])}  积分 ${vip!['score'] ?? 0}', style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
                          ]);
                        }),
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
          // 操作提示（v3.3.205：购物车支持单行改数量/改价/赠送/删除）+ 排序切换（v3.3.243）
          if (cart.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 8, 10, 8),
              color: const Color(0xFFFBFCFD),
              child: Row(children: [
                const Expanded(
                  child: Text('点商品行可改数量 / 改价 / 赠送，点 × 删除单个商品',
                      style: TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
                ),
                _cartOrderToggle(),
              ]),
            ),
          // 明细（行高加大）；倒序开关只影响显示顺序，落单/小票/挂单保持原顺序（v3.3.243）
          Expanded(
            child: cart.isEmpty
                ? const EmptyView('点击左侧商品加入购物车', icon: Icons.shopping_cart_outlined)
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: cart.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 18, endIndent: 18, color: PosTheme.line),
                    itemBuilder: (_, i) {
                      final l = DisplayPrefs.cartNewestFirst.value ? cart[cart.length - 1 - i] : cart[i];
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
          // 底部结算（v3.3.246 重排：金额行 / 券标签行 / 清空+挂单行 / 整单折扣+改价行 / 收款行）
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: PosTheme.line))),
            child: Column(children: [
              _activityBar(), // 命中的活动与赠品（v3.3.222）
              // 金额行：共 N 件左、合计右；合计段 FittedBox 缩放，窄屏不再溢出/重叠（v3.3.246 修复全屏显示异常）
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('共 $count 件', style: const TextStyle(fontSize: 14.5, color: PosTheme.textSub)),
                const Spacer(),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text('合计 ', style: const TextStyle(fontSize: 15, color: PosTheme.textSub)),
                      if (couponApplied > 0 || actDiscount > 0 || wholeCut > 0 || wholeRepriceCut > 0) ...[
                        Text('¥${Fmt.money(total)}',
                            style: const TextStyle(fontSize: 16, color: PosTheme.textHint, decoration: TextDecoration.lineThrough)),
                        const SizedBox(width: 8),
                      ],
                      Text('¥${Fmt.money(payable)}', style: TextStyle(fontSize: 30, color: PosTheme.accentLive, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              ]),
              // 券标签 / 整单优惠标签行：自动换行，不再与合计挤在同一行
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _couponChip(1), // 5元优惠券（v3.3.219）
                    _couponChip(2), // 8.4元券·满16.8可用（v3.3.242）
                    _couponChip(3), // 40元优惠券·无门槛直接扣可0元购（v3.3.247）
                    if (wholeRate > 0)
                      _wholeTag('整单 ${_rateText(wholeRate)}折 -¥${Fmt.money(wholeCut)}',
                          () => setState(() => wholeRate = 0)),
                    if (wholePrice > 0)
                      _wholeTag('整单改价 ¥${Fmt.money(wholePrice)}',
                          () => setState(() => wholePrice = 0)),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // 清空 + 挂单（v3.3.246 换位：清空在左、挂单在右），单独一行
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 54,
                    child: BigButton('清空', onTap: cart.isEmpty ? null : _clearCart, color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: 54),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 54,
                    child: BigButton(
                      holds.isEmpty
                          ? '挂单'
                          : (cart.isEmpty ? '取单 ${holds.length}' : '挂单 ${holds.length}'),
                      onTap: (cart.isEmpty && holds.isEmpty) ? null : _holdTap,
                      color: PosTheme.tint,
                      textColor: PosTheme.accentLive,
                      height: 54),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              // 整单折扣 / 整单改价（v3.3.246 新增）
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: BigButton(
                      wholeRate > 0 ? '整单折扣 ${_rateText(wholeRate)}折' : '整单折扣',
                      onTap: _editWholeRate,
                      color: PosTheme.tint,
                      textColor: PosTheme.accentLive,
                      height: 50),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: BigButton(
                      wholePrice > 0 ? '整单改价 ¥${Fmt.money(wholePrice)}' : '整单改价',
                      onTap: _editWholePrice,
                      color: PosTheme.tint,
                      textColor: PosTheme.accentLive,
                      height: 50),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              // 收款按钮：单独一行，左右留间距、中间撑满（v3.3.246）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: double.infinity,
                  height: 62,
                  child: BigButton('收款 ¥${Fmt.money(payable)}', onTap: cart.isEmpty ? null : _checkout, height: 62),
                ),
              ),
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

  // 优惠券标签（v3.3.247 三档）：5元券（合计>5可用）/ 8.4元券（必须满16.8）/ 40元券（无门槛直接扣，可0元购）
  Widget _couponChip(int tier) {
    final value = tier == 1 ? couponValue : (tier == 2 ? coupon2Value : coupon3Value);
    final applied = couponSel == tier && couponApplied > 0;
    final selected = couponSel == tier;
    final notEnough = tier == 2 && couponBase < coupon2Threshold; // 8.4元券未达门槛
    final c = applied
        ? const Color(0xFFE5484D)
        : notEnough
            ? PosTheme.textHint
            : (selected ? PosTheme.textHint : PosTheme.accentLive);
    final label = applied
        ? '优惠券已减¥${Fmt.money(value)}'
        : tier == 1
            ? '5元优惠券'
            : tier == 2
                ? (notEnough ? '8.4元券·满¥16.8可用' : '8.4元优惠券')
                : '40元优惠券';
    return InkWell(
      onTap: cart.isEmpty ? null : () => setState(() => couponSel = couponSel == tier ? 0 : tier),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: applied ? c.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: applied ? c : (selected ? PosTheme.line : c.withValues(alpha: notEnough ? 0.35 : 0.5))),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(applied ? Icons.check_circle : Icons.local_offer_outlined, size: 16, color: c),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c)),
        ]),
      ),
    );
  }

  // 整单折扣/改价 生效标签（v3.3.246）：点 × 清除
  Widget _wholeTag(String label, VoidCallback onClear) {
    const c = Color(0xFFE5484D);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.percent, size: 16, color: c),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c)),
        const SizedBox(width: 6),
        InkWell(
          onTap: onClear,
          borderRadius: BorderRadius.circular(20),
          child: const Icon(Icons.close, size: 15, color: c),
        ),
      ]),
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
          onTap: () {
            setState(() => l.num++);
            _saveCartLocal();
          },
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
  final String? defaultMethod; // 进弹窗自动选中的方式（商户排序第一，v3.3.251）
  const RetailPayDialog({required this.total, required this.methods, this.vip, this.defaultMethod});
  @override
  State<RetailPayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<RetailPayDialog> {
  String? method;
  String received = ''; // 现金实收（数字键盘输入）
  int mollenType = 0; // 抹零模式（v3.3.238）：0 不抹 / 1 抹分 / 2 抹角（仅现金）

  // ===== v3.3.251 单弹窗收款：左侧方式卡 + 右侧操作面板 + 弹窗内直接支付 =====
  // 收银员点方式卡 → 扫码枪扫顾客付款码（扫完自动收款）→ 完成，不再跳第二个扫码弹窗
  final codeCtrl = TextEditingController();
  final codeFocus = FocusNode();
  String phase = 'input'; // input=待扫码/录现金 paying=支付中 success=成功 fail=失败
  String payStatus = 'scanned';
  int elapsedSec = 0;
  String errorMsg = '';
  String payNo = ''; // 本次扫码用的我方单号
  bool needNewNo = false; // 上一笔已确认失败，重试换新单号
  Map? payOrder; // 成功后的支付流水行

  // ===== v3.3.258 组合支付：最多 3 笔（现金/扫码收款/会员支付），合计=应收后确认 =====
  bool comboMode = false;
  int comboScanIdx = -1; // 当前待扫/支付中的组合行下标（-1=编辑阶段）
  int comboActive = 0; // 键盘正在编辑金额的行下标
  final comboLines = <Map<String, dynamic>>[]; // {method, amount(String), paid, xyfNo, xyfChan}

  final icons = {
    '现金': Icons.payments_outlined,
    '扫码收款': Icons.qr_code_scanner,
    '微信支付': Icons.chat,
    '支付宝': Icons.account_balance_wallet_outlined,
    '会员支付': Icons.badge_outlined,
    '组合支付': Icons.layers_outlined,
  };
  final colors = {
    '现金': PosTheme.green,
    '扫码收款': PosTheme.blue,
    '微信支付': const Color(0xFF07C160),
    '支付宝': const Color(0xFF1677FF),
    '会员支付': PosTheme.accentLive,
    '组合支付': const Color(0xFF8E6BF1),
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
      } else if (k == '<' || k == 'B') {
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
  void initState() {
    super.initState();
    // v3.3.251：进入弹窗自动选中传入的默认方式（商户排序第一），
    // 扫码类直接聚焦付款码输入框，收银员扫码即收，少点一步
    method = widget.defaultMethod ??
        (widget.methods.isNotEmpty ? widget.methods.first : null);
    if (method != null && method != '现金') mollenType = 0;
    if (_isScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) codeFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    codeCtrl.dispose();
    codeFocus.dispose();
    super.dispose();
  }

  // ==================== 组合支付（v3.3.258） ====================
  /// 渠道识别：优先星驿返回的 pay_channel；为 0（回调未及时更新）时按付款码
  /// 前缀兜底（v3.3.260 修复支付宝单落成「其他支付」）
  int _chanOf(Map o) {
    final c = int.tryParse('${o['pay_channel'] ?? 0}') ?? 0;
    if (c > 0) return c;
    return Api.xyfChannelFromCode(codeCtrl.text);
  }

  bool _isComboScan(Map l) =>
      '${l['method']}' == '扫码收款' || '${l['method']}' == '微信支付' || '${l['method']}' == '支付宝';

  double _lineAmt(int i) => double.tryParse('${comboLines[i]['amount'] ?? ''}') ?? 0;

  /// 各行合计（已付+未付）
  double get comboSum {
    var s = 0.0;
    for (final l in comboLines) {
      s += double.tryParse('${l['amount'] ?? ''}') ?? 0;
    }
    return double.parse(s.toStringAsFixed(2));
  }

  /// 待收差额（负数=超额）
  double get comboRemaining =>
      double.parse((payable - comboSum).toStringAsFixed(2));

  /// 组合行可确认：≥2 笔、每笔方式+金额有效、合计=应收、会员行余额够
  bool get comboValid {
    if (comboLines.length < 2) return false;
    for (final l in comboLines) {
      if ('${l['method']}' == 'null' || '${l['method']}'.isEmpty) return false;
      if ((double.tryParse('${l['amount'] ?? ''}') ?? 0) <= 0) return false;
      if ('${l['method']}' == '会员支付' &&
          (double.tryParse('${l['amount'] ?? ''}') ?? 0) > _dialogVipBalance) {
        return false;
      }
    }
    return (comboSum - payable).abs() < 0.005;
  }

  double get _dialogVipBalance {
    final v = widget.vip;
    if (v == null) return 0;
    return (double.tryParse('${v['amount'] ?? 0}') ?? 0) +
        (double.tryParse('${v['gift_balance'] ?? 0}') ?? 0);
  }

  /// 进入组合支付：预置两行，金额尽量预填——
  /// 有会员且余额小于应收时，第一笔默认「会员支付」直接扣完余额（v3.3.260），
  /// 第二笔现金预填差额；无会员时保持 扫码+现金
  void _enterCombo() {
    comboMode = true;
    comboScanIdx = -1;
    comboActive = 0;
    comboLines..clear();
    final bal = _dialogVipBalance;
    String amtStr(double v) => v.toStringAsFixed(2);
    if (widget.vip != null && bal > 0 && bal < payable) {
      comboLines
        ..addAll([
          {'method': '会员支付', 'amount': amtStr(bal), 'paid': false, 'xyfNo': '', 'xyfChan': 0},
          {'method': '现金', 'amount': amtStr(payable - bal), 'paid': false, 'xyfNo': '', 'xyfChan': 0},
        ]);
    } else {
      comboLines
        ..addAll([
          {'method': '扫码收款', 'amount': '', 'paid': false, 'xyfNo': '', 'xyfChan': 0},
          {'method': '现金', 'amount': '', 'paid': false, 'xyfNo': '', 'xyfChan': 0},
        ]);
    }
  }

  /// 组合行金额键盘输入
  void _keyCombo(String k) {
    if (comboLines.isEmpty) return;
    if (comboActive >= comboLines.length) comboActive = 0;
    final l = comboLines[comboActive];
    if (l['paid'] == true) return;
    String cur = '${l['amount'] ?? ''}';
    if (k == 'C') {
      cur = '';
    } else if (k == '<' || k == 'B') {
      if (cur.isNotEmpty) cur = cur.substring(0, cur.length - 1);
    } else if (k == '.') {
      if (!cur.contains('.')) cur += '.';
    } else {
      final dot = cur.indexOf('.');
      if (dot == -1) {
        if (cur.length < 6) cur += k;
      } else if (cur.length - dot - 1 < 2) {
        cur += k;
      }
    }
    setState(() => l['amount'] = cur);
  }

  /// 组合支付确认：有未扫的扫码行先进扫码阶段；纯现金/会员直接成功回传
  Future<void> _payCombo() async {
    if (!comboValid) return;
    final nextScan = comboLines.indexWhere((l) => _isComboScan(l) && l['paid'] != true);
    if (nextScan >= 0) {
      setState(() {
        comboScanIdx = nextScan;
        comboActive = nextScan;
        phase = 'input';
        errorMsg = '';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) codeFocus.requestFocus();
      });
      return;
    }
    _popComboResult();
  }

  /// 一笔扫码行成功后：还有未扫行→继续扫；全部完成→成功回传
  void _afterComboLinePaid() {
    final next = comboLines.indexWhere((l) => _isComboScan(l) && l['paid'] != true);
    if (next >= 0) {
      setState(() {
        comboScanIdx = next;
        comboActive = next;
        phase = 'input';
        payNo = '';
        needNewNo = false;
        errorMsg = '';
      });
      codeCtrl.clear();
      codeFocus.requestFocus();
    } else {
      setState(() {
        phase = 'success';
        comboScanIdx = -1;
      });
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        _popComboResult();
      });
    }
  }

  /// 组合支付完成，回传多笔明细（扫码行带星驿流水）
  void _popComboResult() {
    VoiceService.instance.pay('组合收款', payable);
    final lines = <Map<String, dynamic>>[];
    for (int i = 0; i < comboLines.length; i++) {
      final l = comboLines[i];
      lines.add({
        'method': '${l['method']}',
        'amount': _lineAmt(i),
        'xyf_order_no': '${l['xyfNo'] ?? ''}',
        'xyf_channel': (l['xyfChan'] as int?) ?? 0,
      });
    }
    Navigator.pop(context, {'combo': lines});
  }

  // ==================== 扫码支付（弹窗内直接执行） ====================
  bool get _isScan => method == '扫码收款' || method == '微信支付' || method == '支付宝';
  bool get _busy => phase == 'paying' || phase == 'success';

  /// 付款码前缀识别渠道换主题色（微信 10-15 / 支付宝 25-30 / 云闪付 62）
  Color get _channelColor {
    final code = codeCtrl.text.replaceAll(RegExp(r'[\r\n\t\s]'), '');
    if (code.length >= 2) {
      final p = int.tryParse(code.substring(0, 2)) ?? 0;
      if (p >= 10 && p <= 15) return const Color(0xFF07C160);
      if (p >= 25 && p <= 30) return const Color(0xFF1677FF);
      if (code.startsWith('62')) return const Color(0xFFE21836);
    }
    return method != null ? _colorOf(method!) : PosTheme.blue;
  }

  String _genNo({bool forceNew = false}) {
    if (!forceNew && payNo.isNotEmpty) return payNo;
    return 'XYFR${DateTime.now().millisecondsSinceEpoch}'
        '${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
  }

  /// 支付中每秒计时
  void _startElapsed() {
    elapsedSec = 0;
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || phase != 'paying') return false;
      setState(() => elapsedSec++);
      return true;
    });
  }

  String get _payStatusText {
    switch (payStatus) {
      case 'scanned':
        return '正在提交付款码…';
      case 'accepted':
        return '已受理，等待支付结果…';
      default:
        return '顾客正在输入密码…';
    }
  }

  /// 本次扫码金额：组合支付扫当前行金额，普通模式扫整单应收
  double get _scanAmt {
    if (comboMode && comboScanIdx >= 0 && comboScanIdx < comboLines.length) {
      return _lineAmt(comboScanIdx);
    }
    return widget.total;
  }

  /// 确认收款（扫码类）：弹窗内直接调星驿付付款码支付 + 轮询
  Future<void> _payScan() async {
    if (_busy) return;
    final code = codeCtrl.text.replaceAll(RegExp(r'[\r\n\t\s]'), '').trim();
    if (!RegExp(r'^\d{16,32}$').hasMatch(code)) {
      setState(() => errorMsg = '付款码无效（16-32位数字），请重新扫码或输入');
      codeFocus.requestFocus();
      return;
    }
    setState(() {
      phase = 'paying';
      payStatus = 'scanned';
      errorMsg = '';
    });
    payNo = _genNo(forceNew: needNewNo);
    needNewNo = false;
    _startElapsed();
    try {
      final o = await Api.xyfScanPay(
        amount: _scanAmt,
        authCode: code,
        orderNo: payNo,
        bizType: 'retail',
        onStatus: (s) {
          if (mounted) setState(() => payStatus = s);
        },
      );
      if (!mounted) return;
      VoiceService.instance.pay('扫码', _scanAmt);
      if (comboMode) {
        final idx = comboScanIdx.clamp(0, comboLines.length - 1);
        comboLines[idx]['paid'] = true;
        comboLines[idx]['xyfNo'] = '${o['three_order_no'] ?? o['order_no'] ?? payNo}';
        comboLines[idx]['xyfChan'] = _chanOf(o);
        setState(() {});
        _afterComboLinePaid();
        return;
      }
      setState(() {
        payOrder = o;
        phase = 'success';
      });
      // 成功停 1.2 秒自动回传落单
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        Navigator.pop(context, {
          'method': method,
          'xyf_order_no': '${o['three_order_no'] ?? o['order_no'] ?? payNo}',
          'xyf_channel': _chanOf(o),
        });
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        phase = 'fail';
        errorMsg = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        phase = 'fail';
        errorMsg = '支付失败：$e';
      });
    }
  }

  /// 失败重试：先回查上一笔，防止「其实已付款」还让顾客再付一次（同扫码弹窗逻辑）
  Future<void> _retry() async {
    if (payNo.isNotEmpty) {
      try {
        final q = await Api.xyfQueryOrder(payNo);
        final d = q['data'];
        if ('${q['code']}' == '0' && d is Map) {
          final m = Map<String, dynamic>.from(d);
          final st = int.tryParse('${m['status'] ?? 0}') ?? 0;
          if (st == 3) {
            if (!mounted) return;
            VoiceService.instance.pay('扫码', _scanAmt);
            if (comboMode) {
              final idx = comboScanIdx.clamp(0, comboLines.length - 1);
              comboLines[idx]['paid'] = true;
              comboLines[idx]['xyfNo'] = '${m['three_order_no'] ?? m['order_no'] ?? payNo}';
              comboLines[idx]['xyfChan'] = _chanOf(m);
              _afterComboLinePaid();
              return;
            }
            setState(() {
              payOrder = m;
              phase = 'success';
              errorMsg = '';
            });
            Future.delayed(const Duration(milliseconds: 1200), () {
              if (!mounted) return;
              Navigator.pop(context, {
                'method': method,
                'xyf_order_no': '${m['three_order_no'] ?? m['order_no'] ?? payNo}',
                'xyf_channel': _chanOf(m),
              });
            });
            return;
          }
          if (st == 1 || st == 2) {
            if (!mounted) return;
            setState(() => errorMsg = '上一笔仍在等待支付结果，请稍等再点「重新收款」，请勿重复向顾客收款');
            return;
          }
        }
      } catch (_) {}
    }
    needNewNo = true;
    setState(() {
      phase = 'input';
      codeCtrl.clear();
      errorMsg = '';
    });
    codeFocus.requestFocus();
  }

  /// 取消收款（v3.3.251 防重复扣款加固）：
  /// 本次弹窗内已向上发起过支付（payNo 非空）时，关闭前先回查星驿付订单状态——
  /// 已付款则按成功落单；仍在等待支付结果则阻止关闭并提示，防止旧单挂着顾客又扫新单造成双重收款；
  /// 确认未支付（关单/失败）才允许取消。纯输入阶段（payNo 为空）直接关闭，无资金风险。
  Future<void> _cancel() async {
    // 组合支付已有扫码成功款项时不能取消（钱已收，须完成剩余收款后落单）
    if (comboMode && comboLines.any((l) => l['paid'] == true)) {
      setState(() => errorMsg = '组合支付已有扫码成功的款项，不能取消；请继续完成剩余收款');
      return;
    }
    if (payNo.isNotEmpty) {
      try {
        final q = await Api.xyfQueryOrder(payNo);
        final d = q['data'];
        if ('${q['code']}' == '0' && d is Map) {
          final m = Map<String, dynamic>.from(d);
          final st = int.tryParse('${m['status'] ?? 0}') ?? 0;
          if (st == 3) {
            // 其实已付款：按成功处理，正常落单，不让顾客白付
            if (!mounted) return;
            VoiceService.instance.pay('扫码', widget.total);
            setState(() {
              payOrder = m;
              phase = 'success';
              errorMsg = '';
            });
            Future.delayed(const Duration(milliseconds: 1200), () {
              if (!mounted) return;
              Navigator.pop(context, {
                'method': method,
                'xyf_order_no': '${m['three_order_no'] ?? m['order_no'] ?? payNo}',
                'xyf_channel': _chanOf(m),
              });
            });
            return;
          }
          if (st == 1 || st == 2) {
            if (!mounted) return;
            setState(() => errorMsg = '上一笔仍在等待支付结果，已阻止取消，请勿重复向顾客收款；可点「重新收款」或稍后再试');
            return;
          }
        }
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context);
  }

  // ==================== 布局 ====================
  // v3.3.210 小屏/竖屏自适应；v3.3.251 宽屏改左右卡片布局
  bool get _compact {
    final s = MediaQuery.of(context).size;
    return s.height < 900 || s.width < 1100;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final compact = _compact;
    final wide = !compact; // 宽屏：左侧方式卡竖排 + 右侧操作面板
    final dialogW = wide ? 900.0 : (size.width - 32).clamp(320.0, 660.0);
    final pad = compact ? 16.0 : 24.0;
    final gap = compact ? 10.0 : 14.0;
    final tileH = compact ? 70.0 : 78.0; // 方式卡加高，触屏更好点（v3.3.251）
    final btnH = compact ? 52.0 : 62.0;
    final bigFont = compact ? 24.0 : 30.0;
    // 操作面板固定高度（按现金面板满配高度预留：实收行+快捷键+NumKeypad 56×4），
    // 各支付方式/各状态切换时弹窗宽高保持一致
    final panelH = compact ? 408.0 : 440.0;

    // 操作面板
    Widget panel() {
      Widget inner;
      if (phase == 'paying') {
        inner = _payingPanel(combo: comboMode && comboScanIdx >= 0);
      } else if (phase == 'success') {
        inner = _successPanel();
      } else if (phase == 'fail') {
        inner = _failPanel();
      } else if (comboMode) {
        // v3.3.258 组合支付：编辑阶段=行明细+键盘；扫码阶段=付款码输入
        inner = comboScanIdx >= 0
            ? _scanPanel(compact: compact,
                comboHint: '组合支付第 ${comboScanIdx + 1} 笔 · ${comboLines[comboScanIdx]['method']} ¥${Fmt.money(_lineAmt(comboScanIdx))}')
            : _comboPanel(compact: compact, gap: gap, panelH: panelH);
      } else if (method == '现金') {
        inner = _cashPanel(compact: compact, gap: gap, bigFont: bigFont);
      } else if (method == '会员支付') {
        inner = _memberPanel(compact: compact);
      } else if (method != null) {
        inner = _scanPanel(compact: compact);
      } else {
        inner = Container(
          padding: EdgeInsets.symmetric(vertical: compact ? 14 : 40),
          alignment: Alignment.center,
          child: const Text('请选择收款方式', style: TextStyle(fontSize: 15, color: PosTheme.textHint)),
        );
      }
      return SizedBox(height: panelH, child: Center(child: inner));
    }

    // 底部按钮（取消 + 确认收款）
    Widget bottomBar() {
      return Row(children: [
        Expanded(child: SizedBox(
          height: btnH,
          child: BigButton('取消', onTap: _busy ? null : _cancel,
              color: const Color(0xFFF2F3F7), textColor: PosTheme.textSub, height: btnH),
        )),
        SizedBox(width: compact ? 8 : 14),
        Expanded(flex: 2, child: _confirmButton(btnH)),
      ]);
    }

    // v3.3.251：统一布局（不再分宽屏左右两栏）——支付方式一行平均分配等宽，
    // 触屏更好点；下方操作面板固定高度
    final body = Container(
      width: dialogW,
      padding: EdgeInsets.all(pad),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _titleRow(),
        SizedBox(height: gap),
        // 支付方式：一行 Expanded 平均分配，几项都等宽
        Row(children: [
          for (int i = 0; i < widget.methods.length; i++) ...[
            if (i > 0) SizedBox(width: compact ? 8.0 : 12.0),
            Expanded(child: SizedBox(height: tileH, child: _methodTile(widget.methods[i]))),
          ],
          SizedBox(width: compact ? 8.0 : 12.0),
          Expanded(child: SizedBox(height: tileH, child: _methodTile('组合支付'))),
        ]),
        SizedBox(height: gap),
        panel(),
        SizedBox(height: gap),
        bottomBar(),
      ]),
    );

    return GestureDetector(
      // v3.3.251：点弹窗空白处不再丢焦点——扫码类自动把焦点还给付款码输入框，
      // 否则扫码枪失去焦点收不到码（点按钮/输入框等有自己手势的控件不受影响）
      onTap: () {
        // 组合支付扫码阶段同样保持付款码输入框焦点（扫码枪）
        if ((_isScan || (comboMode && comboScanIdx >= 0)) && phase == 'input') {
          codeFocus.requestFocus();
        }
      },
      child: Dialog(
      backgroundColor: Colors.white,
      insetPadding: EdgeInsets.symmetric(horizontal: 16, vertical: size.height * 0.04),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * 0.92),
        child: SingleChildScrollView(child: body),
      ),
      ),
    );
  }

  Widget _titleRow() {
    final compact = _compact;
    final cashMollen = method == '现金' && mollen > 0;
    return Row(children: [
      Text('收款', style: TextStyle(fontSize: compact ? 20 : 24, fontWeight: FontWeight.w800)),
      if (cashMollen) ...[
        const SizedBox(width: 10),
        Text('已优惠 ¥${Fmt.money(mollen)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: PosTheme.green)),
      ],
      const Spacer(),
      const Text('应收 ', style: TextStyle(fontSize: 15, color: PosTheme.textSub)),
      Text('¥${Fmt.money(cashMollen ? payable : widget.total)}',
          style: TextStyle(fontSize: compact ? 24 : 34, color: PosTheme.accentLive, fontWeight: FontWeight.w800)),
    ]);
  }

  /// 底部确认按钮：随 phase / method 切换形态
  Widget _confirmButton(double btnH) {
    if (phase == 'paying') {
      return BigButton('支付中…', onTap: null, color: const Color(0xFFE9EBF0), textColor: PosTheme.textSub, height: btnH);
    }
    if (phase == 'success') {
      return BigButton('✓ 收款成功', onTap: null, color: PosTheme.green, textColor: Colors.white, height: btnH);
    }
    if (phase == 'fail') {
      return BigButton('重新收款', onTap: _retry, height: btnH);
    }
    // v3.3.251：扫码类空码/无效码时禁用确认（防止误点抢焦点导致扫码枪失灵），扫完自动收款
    final codeClean = codeCtrl.text.replaceAll(RegExp(r'[\r\n\t\s]'), '').trim();
    final codeOk = (!_isScan && !(comboMode && comboScanIdx >= 0)) ||
        RegExp(r'^\d{16,32}$').hasMatch(codeClean);
    final enabled = method != null && phase == 'input' && codeOk &&
        (!comboMode || comboScanIdx >= 0 || comboValid);
    if (comboMode && phase == 'input') {
      final label = comboScanIdx >= 0
          ? '扫第 ${comboScanIdx + 1} 笔 ¥${Fmt.money(_scanAmt)}'
          : (comboValid
              ? (comboLines.any((l) => _isComboScan(l) && l['paid'] != true)
                  ? '开始扫码收款'
                  : '确认收款 ¥${Fmt.money(payable)}')
              : '确认收款（各行金额凑齐后可收）');
      return BigButton(label,
          onTap: !enabled
              ? null
              : (comboScanIdx >= 0 ? () => _payScan() : () => _payCombo()),
          height: btnH);
    }
    return BigButton(method == null ? '确认收款' : '确认收款 ¥${Fmt.money(payable)}',
        onTap: !enabled
            ? null
            : _isScan
                ? () => _payScan()
                : () => Navigator.pop(context, method == '现金' && mollen > 0
                    ? {'method': '现金', 'mollen': mollen}
                    : method),
        height: btnH);
  }

  // ---------- 右侧面板：扫码类 ----------
  Widget _scanPanel({required bool compact, String comboHint = ''}) {
    final c = _channelColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center, // 固定高度面板内垂直居中
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (comboHint.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: BoxDecoration(
                  color: const Color(0xFFF3F0FF), borderRadius: BorderRadius.circular(10)),
              child: Text(comboHint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF8E6BF1))),
            ),
            const SizedBox(height: 10),
          ],
          PosField(
          controller: codeCtrl,
          focusNode: codeFocus,
          autofocus: true,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          maxLength: 32,
          label: '顾客付款码',
          icon: Icons.qr_code,
          iconColor: c,
          cleanScan: true, // 扫码枪脏字符（换行/制表符）已内置清洗
          fontSize: 25,
          onSubmitted: (_) => _payScan(), // 扫码枪带回车：扫完直接收款，零点击
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Text('扫码枪对准顾客付款码，扫完自动收款（微信/支付宝/云闪付/抖音自动识别）',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: compact ? 14 : 15, color: PosTheme.textSub)),
        if (errorMsg.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.error_outline, size: 16, color: PosTheme.red),
            const SizedBox(width: 5),
            Expanded(child: Text(errorMsg, style: const TextStyle(fontSize: 14, color: PosTheme.red))),
          ]),
        ],
        ],
      ),
    );
  }

  // ---------- 右侧面板：现金 ----------
  Widget _cashPanel({required bool compact, required double gap, required double bigFont}) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
      // 快捷键：抹分 / 抹角 / 刚好，三键与键盘 3 列对齐（键高一致 56）
      Row(children: [
        Expanded(child: _cashKey('抹分',
            on: mollenType == 1, onTap: () => setState(() => mollenType = mollenType == 1 ? 0 : 1))),
        const SizedBox(width: 10),
        Expanded(child: _cashKey('抹角',
            on: mollenType == 2, onTap: () => setState(() => mollenType = mollenType == 2 ? 0 : 2))),
        const SizedBox(width: 10),
        Expanded(child: _cashKey('刚好', onTap: () => setState(() => received = Fmt.money(payable)))),
      ]),
      SizedBox(height: gap),
      // 数字键盘：复用无码商品弹窗 NumKeypad（键高 56 / 字号 22 / 间距 10）
      NumKeypad(
        onKey: _key,
        showDot: true,
        dotActive: !received.contains('.'),
        keyHeight: 56,
        gap: 10,
      ),
    ]);
  }

  /// 现金面板快捷键（抹零开关 / 刚好），与 NumKeypad 同高同风格，选中态绿色高亮
  Widget _cashKey(String label, {required VoidCallback onTap, bool on = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? PosTheme.green.withOpacity(0.12) : const Color(0xFFF7F8FA),
          border: Border.all(color: on ? PosTheme.green : Colors.transparent, width: 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label, style: TextStyle(
            fontSize: 18, fontWeight: FontWeight.w700,
            color: on ? PosTheme.green : PosTheme.textMain)),
      ),
    );
  }

  // ---------- 右侧面板：会员支付 ----------
  Widget _memberPanel({required bool compact}) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text('将从「${widget.vip?['name'] ?? widget.vip?['phone'] ?? ''}」余额扣除',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: compact ? 17 : 19, color: PosTheme.textSub)),
        SizedBox(height: compact ? 8 : 12),
        Text('¥${Fmt.money(widget.total)}',
            style: TextStyle(fontSize: compact ? 36 : 44, fontWeight: FontWeight.w800, color: PosTheme.accentLive)),
        SizedBox(height: compact ? 8 : 12),
        Text('当前余额 ¥${Fmt.money((double.tryParse('${widget.vip?['amount'] ?? 0}') ?? 0) + (double.tryParse('${widget.vip?['gift_balance'] ?? 0}') ?? 0))}',
            style: TextStyle(fontSize: compact ? 14 : 15, color: PosTheme.textHint)),
      ]),
    );
  }

  // ---------- 右侧面板：组合支付编辑（v3.3.258） ----------
  // 注意：操作面板固定高度（compact 408 / wide 440），本面板所有行高按紧凑档排布，
  // 3 行明细满配也不得超出（v3.3.258a 修复 Column overflow 22-34px）
  Widget _comboPanel({required bool compact, required double gap, required double panelH}) {
    final remaining = comboRemaining;
    final chips = ['现金', '扫码收款', if (widget.vip != null) '会员支付'];
    final activeLine = comboLines.isNotEmpty && comboActive < comboLines.length
        ? comboLines[comboActive]
        : null;
    const cgap = 8.0; // 组合面板专用小间距（gap 14 会超面板高度）
    return SizedBox(
      height: panelH,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // 待收余额 + 添加一行：整体居中在顶部中间（v3.3.263）
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
                color: remaining == 0 ? const Color(0xFFF0FFF6) : const Color(0xFFFFF7EC),
                borderRadius: BorderRadius.circular(10)),
            alignment: Alignment.center,
            child: Text(
              remaining == 0
                  ? '已凑齐 ¥${Fmt.money(comboSum)}'
                  : '待收 ¥${Fmt.money(remaining)}${remaining < 0 ? '（超出 ¥${Fmt.money(-remaining)}，请调减）' : ''}',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800,
                  color: remaining == 0 ? PosTheme.green : const Color(0xFFE8890C)),
            ),
          ),
          if (comboLines.length < 3) ...[
            const SizedBox(width: 10),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() {
                comboLines.add({'method': '', 'amount': '', 'paid': false, 'xyfNo': '', 'xyfChan': 0});
                comboActive = comboLines.length - 1;
              }),
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF8E6BF1), width: 1.2),
                    borderRadius: BorderRadius.circular(10)),
                alignment: Alignment.center,
                child: const Text('+ 加一笔',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF8E6BF1))),
              ),
            ),
          ],
        ]),
        const SizedBox(height: cgap),
        // 明细行（最多 3 笔）
        for (int i = 0; i < comboLines.length; i++) _comboRow(i),
        const SizedBox(height: cgap),
        // 当前行支付方式选择
        Row(children: [
          for (int i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: _comboChip(chips[i], activeLine)),
          ],
        ]),
        const SizedBox(height: cgap),
        // 数字键盘撑满剩余高度（触屏键随空间变大）
        Expanded(child: NumKeypad(
          onKey: _keyCombo,
          showDot: true,
          dotActive: activeLine != null && !('${activeLine['amount'] ?? ''}').contains('.'),
          gap: 6,
          expand: true,
        )),
      ]),
    );
  }

  Widget _comboRow(int i) {
    final l = comboLines[i];
    final paid = l['paid'] == true;
    final active = i == comboActive && !paid;
    final m = '${l['method']}';
    final amt = double.tryParse('${l['amount'] ?? ''}') ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: paid ? null : () => setState(() => comboActive = i),
      child: Container(
        height: 34,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
            color: paid ? const Color(0xFFF0FFF6) : (active ? const Color(0xFFF3F0FF) : const Color(0xFFF7F8FA)),
            border: Border.all(
                color: paid ? PosTheme.green : (active ? const Color(0xFF8E6BF1) : Colors.transparent),
                width: 1.4),
            borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Icon(paid ? Icons.check_circle : _iconOf(m),
              size: 18, color: paid ? PosTheme.green : (m.isEmpty ? PosTheme.textHint : _colorOf(m))),
          const SizedBox(width: 8),
          Expanded(child: Text(
            m.isEmpty ? '第 ${i + 1} 笔 · 点下方选方式' : '第 ${i + 1} 笔 · $m',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700,
                color: paid ? PosTheme.green : (m.isEmpty ? PosTheme.textHint : PosTheme.textMain)),
          )),
          Text('¥${Fmt.money(amt)}',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800,
                  color: paid ? PosTheme.green : PosTheme.textMain)),
          if (!paid && comboLines.length > 1)
            GestureDetector(
              onTap: () => setState(() {
                comboLines.removeAt(i);
                if (comboActive >= comboLines.length) comboActive = comboLines.length - 1;
              }),
              child: const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.close, size: 16, color: PosTheme.textHint),
              ),
            ),
        ]),
      ),
    );
  }

  /// 当前行支付方式 chip
  Widget _comboChip(String m, Map? activeLine) {
    final sel = activeLine != null && '${activeLine['method']}' == m;
    final locked = activeLine != null && activeLine['paid'] == true;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: locked
          ? null
          : () => setState(() {
                if (activeLine != null) {
                  activeLine['method'] = m;
                  // 选会员支付且金额未填时，默认预填 min(余额, 待收差额)（v3.3.260）
                  if (m == '会员支付' &&
                      (double.tryParse('${activeLine['amount'] ?? ''}') ?? 0) <= 0 &&
                      comboRemaining > 0) {
                    final v = _dialogVipBalance < comboRemaining
                        ? _dialogVipBalance
                        : comboRemaining;
                    if (v > 0) activeLine['amount'] = v.toStringAsFixed(2);
                  }
                }
              }),
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: sel ? const Color(0xFF8E6BF1).withOpacity(0.12) : const Color(0xFFF7F8FA),
            border: Border.all(color: sel ? const Color(0xFF8E6BF1) : Colors.transparent, width: 1.5),
            borderRadius: BorderRadius.circular(10)),
        child: Text(m, style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w700,
            color: sel ? const Color(0xFF8E6BF1) : PosTheme.textMain)),
      ),
    );
  }

  // ---------- 右侧面板：支付中 / 成功 / 失败 ----------
  Widget _payingPanel({bool combo = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 10),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 96, height: 96,
          decoration: const BoxDecoration(color: Color(0xFFEAF2FF), shape: BoxShape.circle),
          alignment: Alignment.center,
          child: const SizedBox(width: 60, height: 60, child: CircularProgressIndicator(strokeWidth: 5, color: PosTheme.blue)),
        ),
        const SizedBox(height: 16),
        Text(_payStatusText, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        if (combo) ...[
          const SizedBox(height: 4),
          Text('组合支付第 ${comboScanIdx + 1} 笔 · ¥${Fmt.money(_scanAmt)}',
              style: const TextStyle(fontSize: 14, color: Color(0xFF8E6BF1), fontWeight: FontWeight.w700)),
        ],
        const SizedBox(height: 4),
        Text('已等待 $elapsedSec 秒 · 最长 60 秒', style: const TextStyle(fontSize: 13, color: PosTheme.textHint)),
      ]),
    );
  }

  Widget _successPanel() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 78, height: 78,
            decoration: BoxDecoration(color: PosTheme.green.withOpacity(0.12), shape: BoxShape.circle),
            child: const Icon(Icons.check, size: 44, color: PosTheme.green)),
        const SizedBox(height: 14),
        const Text('收款成功', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
      ]),
    );
  }

  Widget _failPanel() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 78, height: 78,
            decoration: BoxDecoration(color: PosTheme.red.withOpacity(0.1), shape: BoxShape.circle),
            child: const Icon(Icons.close, size: 44, color: PosTheme.red)),
        const SizedBox(height: 14),
        const Text('收款失败', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: PosTheme.red)),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(errorMsg, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14.5, color: PosTheme.textSub)),
        ),
      ]),
    );
  }

  /// 选择支付方式（v3.3.251 改为只选中，扫码在弹窗内确认时执行）
  void _pick(String m) {
    if (m == '会员支付' && widget.vip == null) return;
    // 组合支付已有成功款项时禁止切换方式（钱已收，须完成落单）
    if (comboMode && comboLines.any((l) => l['paid'] == true)) return;
    setState(() {
      if (m == '组合支付') {
        _enterCombo();
      } else {
        comboMode = false;
        comboScanIdx = -1;
        comboLines.clear();
        codeCtrl.clear();
      }
      method = m;
      phase = 'input';
      errorMsg = '';
      if (m != '现金') mollenType = 0;
    });
    if (_isScan) codeFocus.requestFocus();
  }

  /// 扫码收款品牌图标（v3.3.251）：微信/支付宝/云闪付/抖音，星驿付付款码自动识别渠道
  static const _payBrandAssets = [
    'assets/brand/wxpay.png',
    'assets/brand/zhifubao.png',
    'assets/brand/yunshanfu.png',
    'assets/brand/douyin.png',
  ];

  Widget _brandIcon(String path, double size) {
    return Image.asset(path, width: size, height: size,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.qr_code, size: size, color: PosTheme.blue));
  }

  Widget _methodTile(String m) {
    final compact = _compact;
    final on = method == m;
    final disabled = m == '会员支付' && widget.vip == null;
    return Opacity(
      opacity: _busy && !on ? 0.45 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: (disabled || _busy) ? null : () => _pick(m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: on ? _colorOf(m).withOpacity(0.1) : const Color(0xFFF7F8FA),
            border: Border.all(color: on ? _colorOf(m) : Colors.transparent, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
          // 扫码收款：四个品牌图标排一起 + 文字（星驿付自动识别渠道）
          child: m == '扫码收款'
              ? LayoutBuilder(builder: (context, box) {
                  if (box.maxWidth < 200) {
                    // 紧凑格：图标一行 + 文字一行（图标按格宽自适应，最窄 14px 不溢出）
                    final isz = ((box.maxWidth - 36) / 4).clamp(14.0, 26.0);
                    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        for (final p in _payBrandAssets) ...[
                          _brandIcon(p, isz),
                          const SizedBox(width: 3),
                        ],
                      ]),
                      const SizedBox(height: 4),
                      Text('扫码收款', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: PosTheme.textMain)),
                    ]);
                  }
                  return Row(children: [
                    for (final p in _payBrandAssets) ...[
                      _brandIcon(p, 22),
                      const SizedBox(width: 2),
                    ],
                    const SizedBox(width: 5),
                    Expanded(child: Text('扫码收款', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.textMain))),
                    if (on) const Icon(Icons.check_circle, size: 18, color: PosTheme.green),
                  ]);
                })
              : Row(children: [
            _methodIcon(m, size: compact ? 28 : 32, color: disabled ? PosTheme.textHint : _colorOf(m)),
            const SizedBox(width: 8),
            Expanded(child: Text(m + (disabled ? '（未选会员）' : ''),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: compact ? 16 : 17, fontWeight: FontWeight.w700, color: disabled ? PosTheme.textHint : PosTheme.textMain))),
            if (on) const Icon(Icons.check_circle, size: 20, color: PosTheme.green),
          ]),
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
  Timer? _debounce; // 键盘连续输入防抖（v3.3.243）

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load(String k) async {
    setState(() => loading = true);
    try {
      final r = k.isEmpty
          ? await Api.vipList(Session.wenxunId)
          : await Api.vipSearch(Session.wenxunId, k);
      if (!mounted) return;
      setState(() { list = r; loading = false; });
    } on ApiError {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  /// 数字键盘输入（v3.3.243）：实时按手机号搜索，C 清空 / B 退格
  void _key(String k) {
    setState(() {
      if (k == 'C') {
        kw = '';
      } else if (k == 'B') {
        if (kw.isNotEmpty) kw = kw.substring(0, kw.length - 1);
      } else if (kw.length < 11) {
        kw += k;
      }
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _load(kw));
  }

  /// 数字键盘（v3.3.251）：复用无码商品弹窗的公用 NumKeypad（键高 56 触屏一致），退格代替小数点
  Widget _keypad(double keyH, {double gap = 8}) {
    return NumKeypad(onKey: _key, showDot: false, keyHeight: 56, gap: 10);
  }

  /// 会员行卡（v3.3.251）：触屏高度 + 墨水纹按压；一行平铺 微信昵称/手机号/余额/积分
  Widget _pickVipRow(Map v) {
    final nm = '${v['name'] ?? ''}'.trim();
    final ph = '${v['phone'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.pop(context, v),
          splashColor: PosTheme.accent.withOpacity(0.10),
          highlightColor: PosTheme.accent.withOpacity(0.06),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: PosTheme.line.withOpacity(0.55)),
            ),
            child: Row(children: [
              VipAvatar(avatarUrl: vipAvatarUrl(v), radius: 21, rounded: false, fallbackText: vipAvatarChar(v)),
              const SizedBox(width: 12),
              // 昵称 + 手机号
              Expanded(
                flex: 3,
                child: Column(mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(nm.isEmpty ? (ph.isEmpty ? '未命名会员' : ph) : nm,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                  if (nm.isNotEmpty && ph.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(ph, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
                    ),
                ]),
              ),
              const SizedBox(width: 10),
              // 余额
              Expanded(
                flex: 2,
                child: Column(mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('余额', style: TextStyle(fontSize: 11, color: PosTheme.textHint)),
                  Text('¥${Fmt.money(v['amount'])}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: PosTheme.accent)),
                ]),
              ),
              // 积分
              Expanded(
                flex: 2,
                child: Column(mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('积分', style: TextStyle(fontSize: 11, color: PosTheme.textHint)),
                  Text('${v['score'] ?? 0}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: PosTheme.blue)),
                ]),
              ),
              const Icon(Icons.chevron_right, size: 20, color: PosTheme.textHint),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 弹窗尺寸随屏幕收缩（v3.3.243）：小屏收银机不超出可用区
    final screen = MediaQuery.of(context).size;
    final dw = (screen.width * 0.92).clamp(360.0, 660.0);
    final dh = (screen.height * 0.88).clamp(480.0, 660.0);
    final kwView = kw.isEmpty ? '输入手机号实时搜索' : kw;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: dw, height: dh,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
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
          // 搜索框（只读展示，键盘输入实时搜索）
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: PosTheme.line),
              ),
              child: Row(children: [
                const Icon(Icons.search, size: 20, color: PosTheme.textHint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(kwView,
                      style: TextStyle(
                          fontSize: kw.isEmpty ? 14 : 18,
                          fontWeight: kw.isEmpty ? FontWeight.w400 : FontWeight.w700,
                          color: kw.isEmpty ? PosTheme.textHint : PosTheme.textMain)),
                ),
                if (kw.isNotEmpty)
                  InkWell(
                    onTap: () => _key('C'),
                    borderRadius: BorderRadius.circular(12),
                    child: const Icon(Icons.highlight_off, size: 20, color: PosTheme.textHint),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          // 宽屏（≥760）：列表在左、键盘在右；窄屏：键盘在列表下方（v3.3.243 屏幕自适应）
          Expanded(
            child: LayoutBuilder(builder: (ctx, box) {
              final wide = box.maxWidth >= 760;
              final keyH = wide ? 52.0 : 44.0;
              final listView = loading
                  ? Center(child: CircularProgressIndicator(color: PosTheme.accentLive))
                  : list.isEmpty
                      ? const EmptyView('未找到会员')
                      // v3.3.251：触屏行卡，行高 = 可用高度平分 4 等份（72~104 之间），超 4 个可滚动
                      : Builder(builder: (_) {
                          final slotH = (((box.maxHeight - 12) / 4)).clamp(72.0, 104.0);
                          return ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            itemCount: list.length,
                            itemExtent: slotH,
                            itemBuilder: (_, i) => _pickVipRow(list[i]),
                          );
                        });
              if (wide) {
                return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: Padding(padding: const EdgeInsets.only(left: 8), child: listView)),
                  Container(
                    width: 200,
                    padding: const EdgeInsets.fromLTRB(14, 4, 20, 18),
                    child: _keypad(keyH, gap: 10),
                  ),
                ]);
              }
              return Column(children: [
                Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: listView)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: _keypad(keyH),
                ),
              ]);
            }),
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
