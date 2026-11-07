import 'dart:async';

import 'package:flutter/material.dart';
import '../core/preorder_auto_print.dart';
import '../core/preorder_badge.dart';
import '../core/printer_route.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../ui/widgets.dart';
import 'retail/cashier_page.dart';
import 'retail/member_page.dart';
import 'retail/orders_page.dart';
import 'shared/shift_page.dart';
import 'shared/settings_page.dart';
import 'dining/dining_page.dart';
import 'dining/dining_orders_page.dart';
import 'dining/preorder_page.dart';
import 'delivery/delivery_page.dart';
import 'fresh/fresh_cashier_page.dart';
import 'login_page.dart';

/// 主框架：深色侧边栏 + 内容区
/// 按商户行业 hangye 路由：1零售 → 零售收银版；2餐饮 → 餐饮收银版；3生鲜 → 生鲜收银版
/// 生鲜版与零售共用后端（商品分类/商品/会员等级/会员），仅界面独立（生鲜绿主题）
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});
  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int _index = 0;
  Timer? _bookingTimer; // 预约单自动打印全局轮询（v3.3.152）
  bool get _isDining => Session.hangye == 2;
  bool get _isFresh => Session.hangye == 3;

  @override
  void initState() {
    super.initState();
    // v3.3.125：登录后（含自动登录）后台拉取云端打印机绑定配置，
    // 换电脑/换收银员账号登录不必重设；失败静默，继续用本机缓存
    if (_isDining) {
      PrinterRoute.syncFromCloud('${Session.wenxunId}');
      // v3.3.152：预约单自动打印改全局轮询（原来只在桌台页轮询，停在别的页面就不出票）
      PreorderAutoPrint.check(); // 登录后先查一次，补打关机期间新提交的预约
      _bookingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (mounted) PreorderAutoPrint.check();
      });
    }
  }

  @override
  void dispose() {
    _bookingTimer?.cancel();
    super.dispose();
  }

  String get _versionLabel {
    if (_isDining) return '餐饮版';
    if (_isFresh) return '生鲜版';
    return '零售版';
  }

  List<_NavItem> get _nav {
    if (_isDining) {
      return const [
        _NavItem(Icons.restaurant_menu, '点餐', _Retail.diningHome),
        _NavItem(Icons.event_available, '预约', _Retail.diningPreorder),
        _NavItem(Icons.badge_outlined, '会员', _Retail.member),
        _NavItem(Icons.receipt_long, '订单', _Retail.diningOrders),
        _NavItem(Icons.local_shipping, '配送', _Retail.delivery),
        _NavItem(Icons.swap_horiz, '交班', _Retail.shift),
        _NavItem(Icons.settings_outlined, '设置', _Retail.settings),
      ];
    }
    if (_isFresh) {
      return const [
        _NavItem(Icons.eco, '收银', _Retail.freshCashier),
        _NavItem(Icons.badge_outlined, '会员', _Retail.member),
        _NavItem(Icons.receipt_long, '订单', _Retail.orders),
        _NavItem(Icons.local_shipping, '配送', _Retail.delivery),
        _NavItem(Icons.swap_horiz, '交班', _Retail.shift),
        _NavItem(Icons.settings_outlined, '设置', _Retail.settings),
      ];
    }
    return const [
      _NavItem(Icons.point_of_sale, '收银', _Retail.cashier),
      _NavItem(Icons.badge_outlined, '会员', _Retail.member),
      _NavItem(Icons.receipt_long, '订单', _Retail.orders),
      _NavItem(Icons.local_shipping, '配送', _Retail.delivery),
      _NavItem(Icons.swap_horiz, '交班', _Retail.shift),
      _NavItem(Icons.settings_outlined, '设置', _Retail.settings),
    ];
  }

  Widget _page(int i) {
    if (_isDining) {
      switch (i) {
        case 0: return const DiningPage();
        case 1: return const PreorderPage(); // 预约点餐（v3.3.104 移到左侧菜单）
        case 2: return const MemberPage(); // 餐饮版会员：复用零售会员界面
        case 3: return const DiningOrdersPage();
        case 4: return const DeliveryPage();
        case 5: return const ShiftPage();
        default: return const SettingsPage();
      }
    }
    if (_isFresh) {
      switch (i) {
        case 0: return const FreshCashierPage(); // 生鲜专用收银界面
        case 1: return const MemberPage(); // 会员共用（会员等级表/会员表同零售）
        case 2: return const RetailOrdersPage(); // 订单共用
        case 3: return const DeliveryPage();
        case 4: return const ShiftPage();
        default: return const SettingsPage();
      }
    }
    switch (i) {
      case 0: return const RetailCashierPage();
      case 1: return const MemberPage();
      case 2: return const RetailOrdersPage();
      case 3: return const DeliveryPage();
      case 4: return const ShiftPage();
      default: return const SettingsPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // ===== 侧边栏 =====
          Container(
            width: 96,
            color: _isFresh ? const Color(0xFF123524) : PosTheme.sidebar,
            child: Column(
              children: [
                const SizedBox(height: 34),
                // Logo
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    gradient: _isFresh
                        ? const LinearGradient(colors: [Color(0xFF2BB673), Color(0xFF0E7A38)])
                        : const LinearGradient(colors: [Color(0xFFFF7A45), Color(0xFFF4471B)]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(_isFresh ? Icons.eco : Icons.point_of_sale, color: Colors.white, size: 28),
                ),
                const SizedBox(height: 6),
                Text('稳讯收银',
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w600)),
                Text(_versionLabel,
                    style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.45))),
                const SizedBox(height: 24),
                ..._nav.asMap().entries.map((e) {
                  final on = _index == e.key;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
                    child: Material(
                      color: on
                          ? (_isFresh ? const Color(0xFF1F5C3A) : PosTheme.sidebarActive)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() => _index = e.key),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(children: [
                            Stack(clipBehavior: Clip.none, children: [
                              Icon(e.value.icon, size: 24, color: on ? Colors.white : Colors.white60),
                              // 预约待安排红点（v3.3.104）
                              if (e.value.tag == _Retail.diningPreorder)
                                Positioned(
                                  right: -14,
                                  top: -6,
                                  child: ValueListenableBuilder<int>(
                                    valueListenable: PreorderBadge.count,
                                    builder: (_, n, __) => n <= 0
                                        ? const SizedBox.shrink()
                                        : Container(
                                            constraints: const BoxConstraints(minWidth: 16),
                                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFEF4444),
                                              borderRadius: BorderRadius.circular(9),
                                            ),
                                            child: Text('$n',
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                    fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                                          ),
                                  ),
                                ),
                            ]),
                            const SizedBox(height: 4),
                            Text(e.value.label,
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: on ? Colors.white : Colors.white60,
                                    fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
                          ]),
                        ),
                      ),
                    ),
                  );
                }),
                const Spacer(),
                // 底部：店员信息 + 退出
                PopupMenuButton<String>(
                  tooltip: '',
                  color: _isFresh ? const Color(0xFF123524) : PosTheme.sidebar,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  offset: const Offset(8, -8),
                  icon: Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Center(
                      child: Text(
                        Session.staffName.isNotEmpty ? Session.staffName.characters.first : '员',
                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  itemBuilder: (_) => [
                    PopupMenuItem(enabled: false, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(Session.staffName, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('${Session.roleName} · ${Session.shopName}', style: TextStyle(color: Colors.white60, fontSize: 12)),
                    ])),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'logout', height: 40, child: Text('退出登录', style: TextStyle(color: Colors.white, fontSize: 14))),
                  ],
                  onSelected: (v) async {
                    if (v == 'logout') {
                      final ok = await confirm(context, '退出登录', '确定退出当前收银员账号？');
                      if (ok && context.mounted) {
                        await Session.clear();
                        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginPage()));
                      }
                    }
                  },
                ),
                const SizedBox(height: 18),
              ],
            ),
          ),
          // ===== 内容区 =====
          Expanded(child: _page(_index)),
        ],
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  final String tag;
  const _NavItem(this.icon, this.label, this.tag);
}

class _Retail {
  static const cashier = 'retail_cashier';
  static const freshCashier = 'fresh_cashier';
  static const member = 'retail_member';
  static const orders = 'retail_orders';
  static const shift = 'shift';
  static const settings = 'settings';
  static const diningHome = 'dining_home';
  static const diningPreorder = 'dining_preorder';
  static const diningOrders = 'dining_orders';
  static const delivery = 'delivery';
}
