import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'core/session.dart';
import 'core/theme.dart';
import 'pages/login_page.dart';
import 'pages/shell_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android（商米等收银机）：全屏沉浸 + 跟随设备横竖屏
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
    ));
  }

  // 桌面端：runApp 必须放在 waitUntilReadyToShow 回调内（官方要求），
  // 否则窗口先于 Flutter 首帧显示，Metal 渲染层无内容 → 黑屏
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    final WindowOptions windowOptions = WindowOptions(
      center: true,
      minimumSize: Size(1180, 760),
      size: Size(1366, 860),
      title: '稳讯收银',
      // macOS 隐藏标题栏（视觉更干净）；Windows 保留原生标题栏，确保有最小化/关闭按钮
      titleBarStyle: Platform.isMacOS ? TitleBarStyle.hidden : TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await Session.load();
      runApp(WenxunPosApp(
          loggedIn: Session.token.isNotEmpty && Session.wenxunId > 0));
      await windowManager.show();
      await windowManager.focus();
    });
    return;
  }

  await Session.load();
  runApp(
      WenxunPosApp(loggedIn: Session.token.isNotEmpty && Session.wenxunId > 0));
}

class WenxunPosApp extends StatelessWidget {
  final bool loggedIn;
  const WenxunPosApp({super.key, required this.loggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '稳讯收银',
      debugShowCheckedModeBanner: false,
      theme: PosTheme.light(),
      home: loggedIn ? const ShellPage() : const LoginPage(),
    );
  }
}
