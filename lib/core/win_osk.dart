import 'dart:io';

/// Windows 触摸键盘（TabTip）抑制 v3.3.209
///
/// 现象：收银一体机是触摸屏，点任何输入框系统就弹出虚拟键盘，
/// 挡住半屏、还经常自己乱弹（Flutter 的文本框与系统 SIP 联动导致）。
/// 处理：把当前用户的「触摸键盘自动弹出」关掉（HKCU 不需要管理员权限），
/// 等价于 设置 → 时间和语言 → 输入 → 触摸键盘 → 关闭自动显示。
/// 手写数字键盘、扫码枪、外接实体键盘都不受影响。
class WinOsk {
  static const _key = r'HKCU\Software\Microsoft\TabletTip\1.7';

  /// 启动时调用一次（幂等）
  static Future<void> suppressAutoInvoke() async {
    if (!Platform.isWindows) return;
    try {
      await Process.run('reg', [
        'add', _key, '/v', 'EnableAutoInvoke', '/t', 'REG_DWORD', '/d', '0', '/f',
      ]);
    } catch (_) {}
    // 已经弹出来的这次先关掉
    try {
      await Process.run('taskkill', ['/IM', 'TabTip.exe', '/F']);
    } catch (_) {}
  }

  /// 供设置页「立即收起触摸键盘」按钮使用
  static Future<void> hideNow() async {
    if (!Platform.isWindows) return;
    try {
      await Process.run('taskkill', ['/IM', 'TabTip.exe', '/F']);
    } catch (_) {}
  }
}
