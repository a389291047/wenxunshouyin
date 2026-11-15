import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'core/customer_display.dart';
import 'core/display_prefs.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'core/theme_prefs.dart';
import 'core/updater.dart';
import 'core/win_osk.dart';
import 'core/window_prefs.dart';
import 'pages/customer_screen_page.dart';
import 'pages/login_page.dart';
import 'pages/shell_page.dart';
import 'ui/window_bar.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 副屏（客显）：同一个 exe 的第二个实例，只跑客显界面，不做登录/更新检查
  if (args.contains('--customer-display')) {
    final pos = args
        .firstWhere((a) => a.startsWith('--pos='), orElse: () => '--pos=screen2')
        .substring('--pos='.length);
    await _runCustomerScreen(pos);
    return;
  }

  await Updater.init(); // 在线更新：读取当前版本号（设置页显示/比较用）
  // v3.3.209：收银一体机是触摸屏，点输入框系统就弹虚拟键盘挡住半屏，
  // 启动时关掉「触摸键盘自动弹出」（HKCU，免管理员），扫码枪/实体键盘不受影响
  await WinOsk.suppressAutoInvoke();

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
    final windowOptions = WindowOptions(
      center: true,
      // 小屏收银机（1024×768）也要能正常显示，不再强制 1180 宽
      minimumSize: const Size(960, 600),
      size: await _initialWindowSize(),
      title: '稳讯收银',
      // v3.3.209：Windows 也隐藏原生标题栏，改用自绘标题栏（ui/window_bar.dart），
      // 顶部不再有那条白色系统栏；最小化/最大化/关闭/全屏都在自绘栏里
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await Session.load();
      await DisplayPrefs.load(); // 显示自定义设置（整体字体缩放等，v3.3.193）
      await ThemePrefs.load();   // 主体风格配色方案（v3.3.194）
      await WindowPrefs.load();  // 全屏偏好（v3.3.209）
      await CustomerDisplay.load(); // 副屏偏好（v3.3.209）
      runApp(WenxunPosApp(
          loggedIn: Session.token.isNotEmpty && Session.wenxunId > 0));
      await windowManager.show();
      await windowManager.focus();
      if (WindowPrefs.fullscreen.value) {
        await windowManager.setFullScreen(true);
      }
      // 上次开着副屏就自动再开（收银机每天开机即用）
      if (Platform.isWindows && CustomerDisplay.enabled) {
        await CustomerDisplay.startServer();
        await CustomerDisplay.openWindow();
        _startCdHeartbeat();
      }
    });
    return;
  }

  await Session.load();
  await DisplayPrefs.load();
  await ThemePrefs.load();
  await WindowPrefs.load();
  await CustomerDisplay.load();
  runApp(
      WenxunPosApp(loggedIn: Session.token.isNotEmpty && Session.wenxunId > 0));
}

/// 副屏心跳（v3.3.210）：购物车没变化时每 3 秒补发一次店名快照，
/// 保证副屏一直知道主程序在线（显示店名而不是「欢迎光临」占位）。
/// 只在快照超过 5 秒没更新时才发，不影响收银页的 600ms 实时推送。
Timer? _cdHeartbeat;
void _startCdHeartbeat() {
  _cdHeartbeat?.cancel();
  _cdHeartbeat = Timer.periodic(const Duration(seconds: 3), (_) async {
    if (!CustomerDisplay.enabled && !CustomerDisplay.running) return;
    await CustomerDisplay.ensureServer();
    if (!CustomerDisplay.running) return;
    // 快照超过 5 秒没更新（用户不在收银页）才发店名心跳，不干扰收银页实时推送
    if (DateTime.now().millisecondsSinceEpoch - CustomerDisplay.latestTs > 5000) {
      CustomerDisplay.publish(shop: Session.shopName, total: 0, items: const []);
    }
  });
}

/// 初始窗口尺寸：不超过当前屏幕可用区域（小屏收银机不能被切掉一截）
Future<Size> _initialWindowSize() async {
  const prefer = Size(1366, 860);
  try {
    final d = await screenRetriever.getPrimaryDisplay();
    final avail = d.visibleSize ?? d.size;
    var w = prefer.width;
    var h = prefer.height;
    if (w > avail.width - 20) w = avail.width - 20;
    if (h > avail.height - 20) h = avail.height - 20;
    if (w < 960) w = 960;
    if (h < 600) h = 600;
    return Size(w, h);
  } catch (_) {
    return prefer;
  }
}

/// 副屏窗口：默认铺在第二块屏幕（有的话），没有就居中一个窗口
Future<void> _runCustomerScreen(String pos) async {
  await windowManager.ensureInitialized();
  var size = const Size(1024, 768);
  Offset? at;
  if (pos == 'screen2') {
    try {
      final ds = await screenRetriever.getAllDisplays();
      if (ds.length > 1) {
        final d = ds[1];
        size = d.size;
        at = d.visiblePosition;
      }
    } catch (_) {}
  }
  final opts = WindowOptions(
    size: size,
    center: at == null,
    minimumSize: const Size(640, 480),
    title: '稳讯收银 · 客显屏',
    titleBarStyle: TitleBarStyle.hidden,
    skipTaskbar: true,
    backgroundColor: Colors.black,
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    if (at != null) {
      await windowManager.setPosition(at);
      await windowManager.setSize(size);
    }
    runApp(CustomerScreenApp(windowMode: pos != 'screen2'));
    await windowManager.show();
  });
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
    if (w >= 1000) return 0.8;
    return 0.76; // 小屏 / 高 DPI 缩放下的窗口（v3.3.204 再收一档）
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
            final content = MediaQuery(data: data, child: child ?? const SizedBox.shrink());
            if (!needWindowBar) return content;
            // 自绘标题栏：全屏时自动隐藏（F11 或设置里可切回窗口模式）
            // 注意不要在这里放 autofocus 的 Focus：会抢走收银页搜索框的焦点
            return CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.f11): () =>
                    WindowPrefs.toggleFullScreen(),
              },
              child: ListenableBuilder(
                listenable: WindowPrefs.fullscreen,
                builder: (context, __) => Column(children: [
                  if (!WindowPrefs.fullscreen.value) const WindowBar(),
                  Expanded(child: content),
                ]),
              ),
            );
          },
          home: widget.loggedIn ? const ShellPage() : const LoginPage(),
        );
      },
    );
  }
}
