import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'core/session.dart';
import 'core/theme.dart';
import 'core/updater.dart';
import 'pages/login_page.dart';
import 'pages/shell_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Updater.init(); // 在线更新：读取当前版本号（设置页显示/比较用）

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

  /// 桌面端按窗口宽度自适应整体缩放（v3.3.187）：
  /// 参考稳讯另一套收银系统的小屏适配——小屏收银机（1024/1280 宽）
  /// 自动缩小整体字号让内容显示更完整，大屏保持原样。
  static double adaptiveScale(BuildContext context) {
    if (!Platform.isWindows && !Platform.isMacOS) return 1.0;
    final w = MediaQuery.of(context).size.width;
    if (w >= 1600) return 1.0;
    if (w >= 1366) return 0.94;
    if (w >= 1200) return 0.88;
    return 0.8;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '稳讯收银',
      debugShowCheckedModeBanner: false,
      theme: PosTheme.light(),
      builder: (context, child) {
        final scale = adaptiveScale(context);
        if (scale == 1.0) return child ?? const SizedBox.shrink();
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: loggedIn ? const ShellPage() : const LoginPage(),
    );
  }
}
