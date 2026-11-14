import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'bt_printer.dart';
import 'usb_printer.dart';

/// 钱箱（v3.3.202）：现金结算自动弹箱
///
/// 市售钱箱普遍通过 RJ11 线接在小票打印机上，弹箱 = 给打印机发一条
/// ESC/POS 开箱指令，无需单独驱动：
///   ESC p m t1 t2 = 0x1B 0x70 m t1 t2
///   m  = 0 → 针脚 2，1 → 针脚 5（两种接法的钱箱都有，两个都发兼容面最广）
///   t1 = 通电时长，单位 2ms（25 → 50ms）
///   t2 = 断电时长，单位 2ms（250 → 500ms）
/// 支持 Windows（winspool RAW）与 Android（USB Host），走 USB 或蓝牙打印通道。
class CashDrawer {
  CashDrawer._();

  static const prefEnabled = 'cash_drawer_enabled';
  static const prefChannel = 'cash_drawer_channel'; // usb | bt

  static bool get supported => Platform.isWindows || Platform.isAndroid;

  // ==================== 配置读写 ====================

  static Future<bool> enabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(prefEnabled) ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(prefEnabled, v);
  }

  /// 弹箱通道：usb = USB 小票打印机，bt = 蓝牙打印机
  static Future<String> channel() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(prefChannel) ?? 'usb';
  }

  static Future<void> setChannel(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefChannel, v);
  }

  // ==================== 弹箱指令 ====================

  /// 开箱字节流：针脚 2 + 针脚 5 各发一遍（未接线的那路指令打印机会忽略）
  static Uint8List kickBytes() {
    final b = BytesBuilder();
    b.add([0x1B, 0x70, 0x00, 0x19, 0xFA]); // ESC p 0 25 250：针脚 2
    b.add([0x1B, 0x70, 0x01, 0x19, 0xFA]); // ESC p 1 25 250：针脚 5
    return b.toBytes();
  }

  /// 手动弹箱（设置页「测试弹出」/ 收银成功后调用）
  /// 打印机未连好时抛 ApiError，由调用方决定提示方式
  static Future<void> open() async {
    final ch = await channel();
    if (ch == 'bt') {
      final d = await BtPrinter.selectedDevice();
      if (d == null) {
        throw ApiError('弹箱走蓝牙通道但未选择蓝牙打印机，请到「设置 → 蓝牙打印」选择');
      }
      await BtPrinter.sendRaw(d, kickBytes());
    } else {
      final p = await UsbPrinter.selectedPrinter();
      if (p == null) {
        throw ApiError('弹箱走 USB 通道但未选择 USB 打印机，请到「设置 → USB小票打印机」选择');
      }
      await UsbPrinter.sendRaw(p, kickBytes());
    }
  }

  /// 收银落单成功后调用：现金支付且已开启时自动弹箱。
  /// 异步执行、不抛错不阻塞收银（打印通道异常只记 toast 提示，不弹弹窗）。
  static Future<void> autoOpen(String method) async {
    try {
      if (!method.contains('现金')) return;
      if (!await enabled()) return;
      await open();
    } catch (_) {}
  }
}
