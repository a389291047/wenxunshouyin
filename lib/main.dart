import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/login_model.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 强制横屏（适配收银设备）
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // 优化全屏设置：适配所有尺寸设备稳定全屏（仅修改此部分）
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.immersiveSticky, // 沉浸式粘性全屏，适配所有尺寸设备
    overlays: [], // 彻底隐藏所有系统UI（状态栏、导航栏）
  );
  // 额外保障：设置系统UI样式为透明，避免残留UI显示
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));

  // 检查登录状态
  final userInfoManager = UserInfoManager();
  final isLoggedIn = await userInfoManager.isLoggedIn();

  runApp(MyApp(isLoggedIn: isLoggedIn));
}

class MyApp extends StatelessWidget {
  final bool isLoggedIn;

  const MyApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '稳讯收银',
      theme: ThemeData(
        primarySwatch: Colors.red,
        useMaterial3: false,
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(120, 50),
            textStyle: const TextStyle(fontSize: 18),
          ),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 16),
          bodyMedium: TextStyle(fontSize: 14),
        ),
      ),
      home: isLoggedIn ? const HomePage() : const LoginPage(),
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
    );
  }
}