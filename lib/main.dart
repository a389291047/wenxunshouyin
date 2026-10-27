import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'core/session.dart';
import 'core/theme.dart';
import 'pages/login_page.dart';
import 'pages/shell_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端：runApp 必须放在 waitUntilReadyToShow 回调内（官方要求），
  // 否则窗口先于 Flutter 首帧显示，Metal 渲染层无内容 → 黑屏
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    const WindowOptions windowOptions = WindowOptions(
      center: true,
      minimumSize: Size(1180, 760),
      size: Size(1366, 860),
      titleBarStyle: TitleBarStyle.hidden,
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
