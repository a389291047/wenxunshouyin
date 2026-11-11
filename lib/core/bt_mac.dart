import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

import 'api.dart';

/// macOS 蓝牙小票打印机（经典蓝牙 SPP，IOBluetooth RFCOMM）
///
/// 原理：系统设置里配对的蓝牙打印机，通过 IOBluetoothDevice.pairedDevices
/// 枚举，找其 SDP 服务里的 SPP（RFCOMM 通道），openRFCOMMChannelSync 打开后
/// writeSync 直写 ESC/POS 字节流。
/// 注意：本应用非 App Store 分发（dmg），IOBluetooth 可用；需沙箱蓝牙权限。
class BtMac {
  static bool get supported => Platform.isMacOS;

  // ---------------- ObjC runtime ----------------

  static final _objc = ffi.DynamicLibrary.open('/usr/lib/libobjc.A.dylib');

  static final _objcGetClass = _objc.lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>),
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>)>('objc_getClass');

  static final _selRegisterName = _objc.lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>),
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>)>('sel_registerName');

  // objc_msgSend 按返回值/参数形态分别 cast（同一个函数符号）
  static final _msgSendObj0 = _objc.lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>),
      ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>('objc_msgSend');

  static final _msgSendObj1 = _objc.lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>),
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>('objc_msgSend');

  static final _msgSendUint0 = _objc.lookupFunction<
      ffi.Uint64 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>),
      int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>(
      'objc_msgSend');

  static final _msgSendInt3 = _objc.lookupFunction<
      ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>, ffi.Uint16),
      int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>, int)>('objc_msgSend');

  static final _msgSendInt4 = _objc.lookupFunction<
      ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>,
          ffi.Uint8,
          ffi.Pointer<ffi.Void>),
      int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Void>)>('objc_msgSend');

  static ffi.Pointer<ffi.Void> _cls(String name) {
    final n = name.toNativeUtf8();
    try {
      return _objcGetClass(n);
    } finally {
      calloc.free(n);
    }
  }

  static ffi.Pointer<ffi.Void> _sel(String name) {
    final n = name.toNativeUtf8();
    try {
      return _selRegisterName(n);
    } finally {
      calloc.free(n);
    }
  }

  static String? _str(ffi.Pointer<ffi.Void> nsstr) {
    if (nsstr.address == 0) return null;
    final utf8Sel = _sel('UTF8String');
    final r = _objc.lookupFunction<
            ffi.Pointer<ffi.Uint8> Function(
                ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>),
            ffi.Pointer<ffi.Uint8> Function(
                ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>('objc_msgSend')(
        nsstr, utf8Sel);
    if (r.address == 0) return null;
    return r.cast<Utf8>().toDartString();
  }

  // ---------------- 配对设备枚举 ----------------

  /// 返回 [{id: MAC地址, name: 设备名, channel: SPP RFCOMM 通道号}]
  /// channel 为 null 表示该设备没有 SPP 服务（不能直接打印）
  static List<Map<String, dynamic>> list() {
    if (!supported) return const [];
    final devCls = _cls('IOBluetoothDevice');
    if (devCls.address == 0) return const [];
    final devices = _msgSendObj0(devCls, _sel('pairedDevices'));
    if (devices.address == 0) return const [];

    final countSel = _sel('count');
    final objAtSel = _sel('objectAtIndex:');
    final nameSel = _sel('name');
    final addrSel = _sel('addressString');
    final servicesSel = _sel('services');
    final chanIdSel = _sel('getRFCOMMChannelID:');
    final codSel = _sel('classOfDevice');

    final n = _msgSendUint0(devices, countSel);
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < n; i++) {
      final dev = _msgSendObj1(devices, objAtSel, ffi.Pointer<ffi.Void>.fromAddress(i));
      if (dev.address == 0) continue;
      // 按蓝牙设备类型过滤：手机(0x02)/音频(0x04)设备不参与打印
      // （iPhone 等手机带 OBEX 文件传输服务也有 RFCOMM 通道号，会被误判为 SPP）
      final cod = _msgSendUint0(dev, codSel);
      final major = (cod >> 8) & 0x1F;
      if (major == 0x02 || major == 0x04) continue;
      final name = _str(_msgSendObj0(dev, nameSel)) ?? '蓝牙设备';
      final addr = _str(_msgSendObj0(dev, addrSel)) ?? '';
      if (addr.isEmpty) continue;
      // 找 SPP 服务（有 RFCOMM 通道的服务）
      int? channel;
      final services = _msgSendObj0(dev, servicesSel);
      if (services.address != 0) {
        final sc = _msgSendUint0(services, countSel);
        final cidBuf = calloc<ffi.Uint8>();
        try {
          for (var j = 0; j < sc; j++) {
            final svc =
                _msgSendObj1(services, objAtSel, ffi.Pointer<ffi.Void>.fromAddress(j));
            if (svc.address == 0) continue;
            final r = _msgSendInt3(svc, chanIdSel, cidBuf.cast<ffi.Void>(), 0);
            if (r == 0 && cidBuf.value > 0) {
              channel = cidBuf.value;
              break;
            }
          }
        } finally {
          calloc.free(cidBuf);
        }
      }
      out.add({'id': addr, 'name': name, 'channel': channel});
    }
    return out;
  }

  // ---------------- SPP 写入 ----------------

  /// 往配对设备写 ESC/POS 字节流（SPP RFCOMM 通道）
  static Future<void> printTo(Map<String, dynamic> device, List<int> bytes) async {
    final targetAddr = '${device['id']}'.toUpperCase();
    final devCls = _cls('IOBluetoothDevice');
    final devices = _msgSendObj0(devCls, _sel('pairedDevices'));
    if (devices.address == 0) throw ApiError('无法访问蓝牙（请确认已在系统蓝牙设置中配对打印机）');

    final countSel = _sel('count');
    final objAtSel = _sel('objectAtIndex:');
    final addrSel = _sel('addressString');
    final servicesSel = _sel('services');
    final chanIdSel = _sel('getRFCOMMChannelID:');

    // 定位设备并取 SPP 通道号
    var dev = ffi.Pointer<ffi.Void>.fromAddress(0);
    int channel = -1;
    if ('${device['channel']}' != '' && '${device['channel']}' != 'null') {
      channel = int.tryParse('${device['channel']}') ?? -1;
    }
    final n = _msgSendUint0(devices, countSel);
    for (var i = 0; i < n; i++) {
      final d = _msgSendObj1(devices, objAtSel, ffi.Pointer<ffi.Void>.fromAddress(i));
      if (d.address == 0) continue;
      final addr = _str(_msgSendObj0(d, addrSel)) ?? '';
      if (addr.toUpperCase() != targetAddr) continue;
      dev = d;
      break;
    }
    if (dev.address == 0) {
      throw ApiError('蓝牙打印机不在配对列表中（请在「系统设置 → 蓝牙」重新配对）');
    }
    if (channel <= 0) {
      final services = _msgSendObj0(dev, servicesSel);
      if (services.address != 0) {
        final sc = _msgSendUint0(services, countSel);
        final cidBuf = calloc<ffi.Uint8>();
        try {
          for (var j = 0; j < sc; j++) {
            final svc =
                _msgSendObj1(services, objAtSel, ffi.Pointer<ffi.Void>.fromAddress(j));
            if (svc.address == 0) continue;
            final r = _msgSendInt3(svc, chanIdSel, cidBuf.cast<ffi.Void>(), 0);
            if (r == 0 && cidBuf.value > 0) {
              channel = cidBuf.value;
              break;
            }
          }
        } finally {
          calloc.free(cidBuf);
        }
      }
    }
    if (channel <= 0) {
      throw ApiError('该蓝牙设备没有 SPP 串口服务，无法直接打印');
    }

    // 打开 RFCOMM 通道
    final openSel = _sel('openRFCOMMChannelSync:withChannelID:delegate:');
    final chanBuf = calloc<ffi.Pointer<ffi.Void>>();
    try {
      final openR = _msgSendInt4(dev, openSel, chanBuf.cast<ffi.Void>(), channel,
          ffi.Pointer<ffi.Void>.fromAddress(0));
      if (openR != 0 || chanBuf.value.address == 0) {
        throw ApiError('蓝牙连接失败（错误码 $openR）：请确认打印机已开机、在蓝牙范围内且未被其它设备占用');
      }
      final chan = chanBuf.value;
      final writeSel = _sel('writeSync:length:');
      final data = <int>[...bytes];
      final buf = calloc<ffi.Uint8>(data.length);
      try {
        buf.asTypedList(data.length).setAll(0, data);
        var offset = 0;
        // RFCOMM MTU 一般 200~489，按 200 分块稳妥
        while (offset < data.length) {
          final len = (data.length - offset) > 200 ? 200 : data.length - offset;
          final w = _msgSendInt3(chan, writeSel,
              ffi.Pointer<ffi.Uint8>.fromAddress(buf.address + offset).cast<ffi.Void>(), len);
          if (w != 0) {
            throw ApiError('小票数据发送失败（错误码 $w）：请检查打印机电源与纸仓');
          }
          offset += len;
        }
      } finally {
        calloc.free(buf);
      }
      final closeSel = _sel('closeChannel');
      _msgSendObj0(chan, closeSel);
    } finally {
      calloc.free(chanBuf);
    }
  }
}
