import 'package:flutter/material.dart';
import 'order_page.dart'; // 包含 OrderPageMode
import 'kaitai_page.dart';
import 'huiyuan_page.dart';
import 'dingdan_page.dart';
import 'shezhi_page.dart';
import 'jiaoban_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // 底部导航选项：给 OrderPage 传入必填的 mode 参数
  final List<Map<String, dynamic>> _navItems = [
    // 这里选择一个默认模式（比如同时包含收银+点单，或选其中一个）
    {'title': '点单', 'page': const OrderPage(mode: OrderPageMode.shouyin)},
    {'title': '开台', 'page': const KaiTaiPage()},
    {'title': '会员', 'page': const HuiYuanPage()},
    {'title': '订单', 'page': const DingDanPage()},
    {'title': '设置', 'page': const SheZhiPage()},
    {'title': '交班', 'page': const JiaoBanPage()},
  ];
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _navItems[_selectedIndex]['page'],
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.red,
        unselectedItemColor: Colors.grey,
        selectedFontSize: 23,
        unselectedFontSize: 21,
        onTap: (index) {
          setState(() => _selectedIndex = index);
        },
        items: _navItems
            .map((item) => BottomNavigationBarItem(
          icon: const SizedBox.shrink(),
          label: item['title'],
        ))
            .toList(),
      ),
    );
  }
}