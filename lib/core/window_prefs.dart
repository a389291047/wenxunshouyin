import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面窗口偏好（Windows）：全屏模式（收银机铺满整屏，隐藏任务栏/标题栏）
///
/// 存本机 SharedPreferences，重启后自动恢复；改动即时生效。
class WindowPrefs {
  static const kFull = 'win_fullscreen';

  /// 当前是否全屏（界面用它决定是否显示自绘标题栏）
  static final ValueNotifier<bool> fullscreen = ValueNotifier(false);

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    fullscreen.value = sp.getBool(kFull) ?? false;
  }

  /// 应用全屏/窗口模式并保存
  static Future<void> setFullScreen(bool v) async {
    fullscreen.value = v;
    try {
      await windowManager.setFullScreen(v);
    } catch (_) {
      // 非桌面端/窗口未就绪时忽略
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(kFull, v);
  }

  static Future<void> toggleFullScreen() => setFullScreen(!fullscreen.value);
}
