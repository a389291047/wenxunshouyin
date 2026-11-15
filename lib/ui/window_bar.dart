import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/window_prefs.dart';

/// 自绘窗口标题栏（仅桌面端）
///
/// v3.3.209：隐藏 Windows 系统默认标题栏（那条又白又粗、带程序图标的原生栏），
/// 换成这条 34px 的深色条：左侧可拖动窗口，右侧自绘
/// 「全屏 / 最小化 / 最大化还原 / 关闭」，风格与深色侧边栏统一。
class WindowBar extends StatefulWidget {
  const WindowBar({super.key, this.height = 34});

  final double height;

  @override
  State<WindowBar> createState() => _WindowBarState();
}

class _WindowBarState extends State<WindowBar> with WindowListener {
  bool _max = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMax();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMax() async {
    try {
      final m = await windowManager.isMaximized();
      if (mounted && m != _max) setState(() => _max = m);
    } catch (_) {}
  }

  @override
  void onWindowMaximize() => setState(() => _max = true);
  @override
  void onWindowUnmaximize() => setState(() => _max = false);

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF1E2430);
    return Material(
      color: bg,
      child: SizedBox(
        height: widget.height,
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Icon(Icons.point_of_sale, size: 14, color: Colors.white54),
            const SizedBox(width: 7),
            const Text('稳讯收银',
                style: TextStyle(fontSize: 11.5, color: Colors.white54, letterSpacing: 0.6)),
            // 拖动区（双击最大化/还原）
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => windowManager.startDragging(),
                onDoubleTap: () => _toggleMax(),
                child: const SizedBox(height: double.infinity),
              ),
            ),
            _btn(
              icon: WindowPrefs.fullscreen.value ? Icons.fullscreen_exit : Icons.fullscreen,
              tip: '全屏（F11）',
              onTap: () => WindowPrefs.toggleFullScreen(),
            ),
            _btn(icon: Icons.remove, tip: '最小化', onTap: () => windowManager.minimize()),
            _btn(
              icon: _max ? Icons.filter_none : Icons.crop_square,
              tip: _max ? '还原' : '最大化',
              size: 15,
              onTap: () => _toggleMax(),
            ),
            _btn(icon: Icons.close, tip: '关闭', hover: const Color(0xFFE5484D), onTap: () => windowManager.close()),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleMax() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    await _syncMax();
  }

  Widget _btn({
    required IconData icon,
    required String tip,
    required VoidCallback onTap,
    double size = 16,
    Color? hover,
  }) {
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onTap,
        hoverColor: hover ?? Colors.white.withValues(alpha: 0.10),
        child: SizedBox(
          width: 42,
          height: widget.height,
          child: Icon(icon, size: size, color: Colors.white70),
        ),
      ),
    );
  }
}

/// 只在桌面端显示自绘标题栏（安卓一体机没有窗口概念）
bool get needWindowBar => Platform.isWindows || Platform.isLinux;
