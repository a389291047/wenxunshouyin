import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'bt_mac.dart';
import 'bt_win.dart';
import 'esc_pos.dart';

/// 蓝牙小票打印机（经典蓝牙 SPP）：Windows / macOS / Android
///
/// 与 USB 打印同级的本地出票通道：USB 未启用时自动兜底。
/// - Windows/macOS：打印机先在系统蓝牙设置配对，App 里直接选
/// - Android：App 内直接扫描附近打印机并配对
class BtPrinter {
  BtPrinter._();

  static const prefEnabled = 'bt_print_enabled';
  static const prefDevice = 'bt_print_device';
  static const prefSpec = 'bt_print_spec';
  static const _channel = MethodChannel('wenxun/bt_printer');

  static bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isAndroid;

  // ==================== 配置读写 ====================

  static Future<bool> enabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(prefEnabled) ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(prefEnabled, v);
  }

  static Future<Map<String, dynamic>?> selectedDevice() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(prefDevice);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> selectDevice(Map<String, dynamic>? d) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefDevice, d == null ? '' : jsonEncode(d));
  }

  /// 纸张规格：蓝牙便携机都是热敏，只有 58 / 80 两种
  static Future<String> spec() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(prefSpec) ?? 'pos58';
  }

  static Future<void> setSpec(String s) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefSpec, s);
  }

  static Map<String, dynamic> specOf(String spec) {
    if (spec == 'pos80') {
      return {'key': 'pos80', 'width': 80, 'textW': 48, 'label': '热敏小票 80mm'};
    }
    return {'key': 'pos58', 'width': 58, 'textW': 32, 'label': '热敏小票 58mm'};
  }

  /// 当前规格（合并 specOf，供打印参数用）
  static Future<Map<String, dynamic>> currentSpec() async =>
      specOf(await spec());

  // ==================== 出票分流 ====================

  /// 打印分流入口：未启用返回 false（调用方继续走后续通道）；
  /// 已启用则直接走蓝牙打印，失败抛 ApiError。
  static Future<bool> tryPrint(String content) async {
    if (!await enabled()) return false;
    final d = await selectedDevice();
    if (d == null) {
      throw ApiError('已启用蓝牙打印但未选择打印机，请到「设置 → 蓝牙打印」选择');
    }
    final spec = await currentSpec();
    await printTicket(d, content,
        paperWidth: spec['width'] as int, textW: spec['textW'] as int?);
    return true;
  }

  // ==================== 设备枚举 ====================

  /// 已配对蓝牙打印机：[{id, name, kind, channel/port, ...}]
  /// 只列有 SPP 串口服务的设备（能直接打印的）
  static Future<List<Map<String, dynamic>>> list() async {
    if (Platform.isAndroid) {
      final res = await _channel.invokeMethod<List<dynamic>>('list');
      return (res ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    if (Platform.isWindows) {
      return BtWin.list().map((e) => {
            'id': '${e['port']}',
            'name': '${e['name']}',
            'port': '${e['port']}',
            'kind': 'spp',
          }).toList();
    }
    if (Platform.isMacOS) {
      return BtMac.list()
          .map((e) => {
                'id': '${e['id']}',
                'name': '${e['name']}',
                'channel': e['channel'],
                'kind': e['channel'] == null ? 'nospp' : 'spp',
              })
          .toList();
    }
    return [];
  }

  /// Android：扫描附近蓝牙设备（未配对的），返回 [{id, name, paired}]
  static Future<List<Map<String, dynamic>>> scan() async {
    final res = await _channel.invokeMethod<List<dynamic>>('scan');
    return (res ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Android：配对指定地址的设备
  static Future<bool> pair(String address) async {
    return await _channel.invokeMethod<bool>('pair', {'address': address}) == true;
  }

  /// Android：申请蓝牙运行时权限（Android 12+ 需要）
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestPermission') == true;
    } catch (_) {
      return false;
    }
  }

  // ==================== 打印 ====================

  static Future<void> printTicket(Map<String, dynamic> device, String content,
      {int paperWidth = 58, int? textW}) async {
    final bytes =
        EscPos.encode(content, paperWidth: paperWidth, mode: 'pos', textW: textW);
    await sendRaw(device, bytes);
  }

  /// 原始字节直发（打印 / 钱箱弹箱共用底层通道，v3.3.202）
  static Future<void> sendRaw(Map<String, dynamic> device, List<int> bytes) async {
    final data = Uint8List.fromList(bytes);
    if (Platform.isAndroid) {
      await _channel.invokeMethod('print', {
        'address': '${device['id']}',
        'name': '${device['name']}',
        'bytes': data,
      });
    } else if (Platform.isWindows) {
      await BtWin.printTo('${device['port']}', data);
    } else if (Platform.isMacOS) {
      await BtMac.printTo(device, data);
    } else {
      throw ApiError('当前平台不支持蓝牙打印');
    }
  }
}
