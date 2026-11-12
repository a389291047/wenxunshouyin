import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'core/display_prefs.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'core/theme_prefs.dart';
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
      await DisplayPrefs.load(); // 显示自定义设置（整体字体缩放等，v3.3.193）
      await ThemePrefs.load();   // 主体风格配色方案（v3.3.194）
      runApp(WenxunPosApp(
          loggedIn: Session.token.isNotEmpty && Session.wenxunId > 0));
      await windowManager.show();
      await windowManager.focus();
    });
    return;
  }

  await Session.load();
  await DisplayPrefs.load();
  await ThemePrefs.load();
  runApp(
      WenxunPosApp(loggedIn: Session.token.isNotEmpty && Session.wenxunId > 0));
}

class WenxunPosApp extends StatefulWidget {
  final bool loggedIn;
  const WenxunPosApp({super.key, required this.loggedIn});
  @override
  State<WenxunPosApp> createState() => _WenxunPosAppState();
}

class _WenxunPosAppState extends State<WenxunPosApp> {
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
    // 商户自定义显示（设置 → 显示设置）+ 主体风格（设置 → 主题风格）：
    // 整体字体缩放、字体粗细、配色方案，改动后即时重建生效
    return ListenableBuilder(
      listenable: Listenable.merge([
        DisplayPrefs.fontScale,
        DisplayPrefs.fontWeight,
        ThemePrefs.skinId,
      ]),
      builder: (context, _) {
        final userScale = DisplayPrefs.fontScale.value;
        return MaterialApp(
          title: '稳讯收银',
          debugShowCheckedModeBanner: false,
          theme: PosTheme.light(weight: DisplayPrefs.weightOf, skin: ThemePrefs.active),
          themeAnimationDuration: const Duration(milliseconds: 220),
          builder: (context, child) {
            final scale = adaptiveScale(context) * userScale;
            // 加粗：boldText 会让 Text 在合并样式后强制加粗（连显式写死字重的文字也生效）；
            // 主题字重同时置 w700，保证输入框等非 Text 组件同步变粗
            final bold = DisplayPrefs.fontWeight.value == 'bold';
            var data = MediaQuery.of(context);
            if (scale != 1.0) {
              data = data.copyWith(textScaler: TextScaler.linear(scale));
            }
            if (bold) data = data.copyWith(boldText: true);
            return MediaQuery(data: data, child: child ?? const SizedBox.shrink());
          },
          home: widget.loggedIn ? const ShellPage() : const LoginPage(),
        );
      },
    );
  }
}
