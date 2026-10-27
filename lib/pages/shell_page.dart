import 'package:flutter/material.dart';
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
import 'login_page.dart';

/// 主框架：深色侧边栏 + 内容区
/// 按商户行业 hangye 路由：1零售/3生鲜 → 零售收银版；2餐饮 → 餐饮收银版
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});
  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int _index = 0;
  bool get _isDining => Session.hangye == 2;

  List<_NavItem> get _nav {
    if (_isDining) {
      return const [
        _NavItem(Icons.restaurant_menu, '点餐', _Retail.diningHome),
        _NavItem(Icons.badge_outlined, '会员', _Retail.member),
        _NavItem(Icons.receipt_long, '订单', _Retail.diningOrders),
        _NavItem(Icons.swap_horiz, '交班', _Retail.shift),
        _NavItem(Icons.settings_outlined, '设置', _Retail.settings),
      ];
    }
    return const [
      _NavItem(Icons.point_of_sale, '收银', _Retail.cashier),
      _NavItem(Icons.badge_outlined, '会员', _Retail.member),
      _NavItem(Icons.receipt_long, '订单', _Retail.orders),
      _NavItem(Icons.swap_horiz, '交班', _Retail.shift),
      _NavItem(Icons.settings_outlined, '设置', _Retail.settings),
    ];
  }

  Widget _page(int i) {
    if (_isDining) {
      switch (i) {
        case 0: return const DiningPage();
        case 1: return const MemberPage(); // 餐饮版会员：复用零售会员界面
        case 2: return const DiningOrdersPage();
        case 3: return const ShiftPage();
        default: return const SettingsPage();
      }
    }
    switch (i) {
      case 0: return const RetailCashierPage();
      case 1: return const MemberPage();
      case 2: return const RetailOrdersPage();
      case 3: return const ShiftPage();
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
            color: PosTheme.sidebar,
            child: Column(
              children: [
                const SizedBox(height: 34),
                // Logo
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFFFF7A45), Color(0xFFF4471B)]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.point_of_sale, color: Colors.white, size: 28),
                ),
                const SizedBox(height: 6),
                Text('稳讯收银',
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w600)),
                Text(_isDining ? '餐饮版' : '零售版',
                    style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.45))),
                const SizedBox(height: 24),
                ..._nav.asMap().entries.map((e) {
                  final on = _index == e.key;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
                    child: Material(
                      color: on ? PosTheme.sidebarActive : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() => _index = e.key),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(children: [
                            Icon(e.value.icon, size: 24, color: on ? Colors.white : Colors.white60),
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
                  color: PosTheme.sidebar,
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
  static const member = 'retail_member';
  static const orders = 'retail_orders';
  static const shift = 'shift';
  static const settings = 'settings';
  static const diningHome = 'dining_home';
  static const diningOrders = 'dining_orders';
}
