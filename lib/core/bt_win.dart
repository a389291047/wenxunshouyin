import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'api.dart';

/// Windows 蓝牙小票打印机（经典蓝牙 SPP 虚拟串口）
///
/// 原理：蓝牙打印机在 Windows 上配对后，SPP 服务会生成一个虚拟串口
/// （设备名形如 "Standard Serial over Bluetooth link (COM4)" / "蓝牙串口 (COM5)"）。
/// 用 SetupAPI 枚举 GUID_DEVCLASS_PORTS 里名称带 Bluetooth/蓝牙 的串口，
/// 打印直接往该 COM 口写 ESC/POS 字节流（CreateFileW + WriteFile）。
/// 配对动作由用户在 Windows 蓝牙设置里完成（与电子秤做法一致）。
class BtWin {
  static bool get supported => Platform.isWindows;

  // ---------------- SetupAPI：枚举串口设备 ----------------

  static final _setupApi = ffi.DynamicLibrary.open('setupapi.dll');
  static final _k32 = ffi.DynamicLibrary.open('kernel32.dll');

  /// GUID_DEVCLASS_PORTS {4D36E978-E325-11CE-BFC1-08002BE10318}
  static ffi.Pointer<_Guid> _newPortsGuid() {
    final g = calloc<_Guid>()
      ..ref.d1 = 0x4D36E978
      ..ref.d2 = 0xE325
      ..ref.d3 = 0x11CE
      ..ref.setTail(0xBFC1, 0x08002BE10318);
    return g;
  }

  static final _setupDiGetClassDevs = _setupApi.lookupFunction<
      ffi.IntPtr Function(ffi.Pointer<_Guid>, ffi.Pointer<ffi.Uint16>,
          ffi.IntPtr, ffi.Uint32),
      int Function(ffi.Pointer<_Guid>, ffi.Pointer<ffi.Uint16>, int,
          int)>('SetupDiGetClassDevsW');

  static final _setupDiEnumDeviceInfo = _setupApi.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.Uint32, ffi.Pointer<_DevinfoData>),
      int Function(int, int, ffi.Pointer<_DevinfoData>)>(
      'SetupDiEnumDeviceInfo');

  static final _setupDiGetDeviceRegistryProperty = _setupApi.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<_DevinfoData>, ffi.Uint32,
          ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint8>, ffi.Uint32,
          ffi.Pointer<ffi.Uint32>),
      int Function(int, ffi.Pointer<_DevinfoData>, int, ffi.Pointer<ffi.Uint32>,
          ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint32>)>(
      'SetupDiGetDeviceRegistryPropertyW');

  static final _setupDiDestroyDeviceInfoList = _setupApi.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr), int Function(int)>(
      'SetupDiDestroyDeviceInfoList');

  static const _digcfPresent = 0x2;
  static const _spdrpFriendlyname = 12;

  /// 返回 [{port: COM4, name: 完整设备名}]，只留蓝牙串口
  static List<Map<String, dynamic>> list() {
    if (!supported) return const [];
    final out = <Map<String, dynamic>>[];
    final guid = _newPortsGuid();
    final devInfo = _setupDiGetClassDevs(
        guid,
        ffi.Pointer<ffi.Uint16>.fromAddress(0),
        0,
        _digcfPresent);
    if (devInfo == 0) {
      calloc.free(guid);
      return out;
    }
    final devData = calloc<_DevinfoData>();
    final propType = calloc<ffi.Uint32>();
    final needed = calloc<ffi.Uint32>();
    ffi.Pointer<ffi.Uint8> buf = ffi.Pointer.fromAddress(0);
    try {
      for (var i = 0;; i++) {
        devData.ref.cbSize = ffi.sizeOf<_DevinfoData>();
        if (_setupDiEnumDeviceInfo(devInfo, i, devData) == 0) break;
        // 先取长度
        if (_setupDiGetDeviceRegistryProperty(devInfo, devData,
                _spdrpFriendlyname, propType, ffi.Pointer.fromAddress(0), 0, needed) !=
            0) {
          continue; // 不可能成功，防御
        }
        final err = needed.value;
        if (err == 0 || err > 512) continue;
        buf = calloc<ffi.Uint8>(err);
        final ok = _setupDiGetDeviceRegistryProperty(devInfo, devData,
            _spdrpFriendlyname, propType, buf, err, needed);
        String name = '';
        if (ok != 0) {
          name = buf.cast<Utf16>().toDartString();
        }
        calloc.free(buf);
        buf = ffi.Pointer.fromAddress(0);
        if (name.isEmpty) continue;
        // 抠出 COM 口号：设备名形如 "xxx (COM4)"
        final m = RegExp(r'\((COM\d+)\)\s*$').firstMatch(name);
        final port = m?.group(1);
        if (port == null) continue;
        final lower = name.toLowerCase();
        if (!lower.contains('bluetooth') && !name.contains('蓝牙')) continue;
        out.add({'port': port, 'name': name});
      }
    } finally {
      if (buf.address != 0) calloc.free(buf);
      calloc.free(devData);
      calloc.free(propType);
      calloc.free(needed);
      calloc.free(guid);
      _setupDiDestroyDeviceInfoList(devInfo);
    }
    return out;
  }

  // ---------------- 串口写入（SPP 打印） ----------------

  static const _genericWrite = 0x40000000;
  static const _genericRead = 0x80000000;
  static const _openExisting = 3;

  static final _createFileW = _k32.lookupFunction<
      ffi.IntPtr Function(ffi.Pointer<ffi.Uint16>, ffi.Uint32, ffi.Uint32,
          ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.IntPtr),
      int Function(ffi.Pointer<ffi.Uint16>, int, int, ffi.Pointer<ffi.Void>,
          int, int, int)>('CreateFileW');

  static final _writeFile = _k32.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<ffi.Uint8>, ffi.Uint32,
          ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Void>),
      int Function(int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint32>,
          ffi.Pointer<ffi.Void>)>('WriteFile');

  static final _closeHandle =
      _k32.lookupFunction<ffi.Int32 Function(ffi.IntPtr), int Function(int)>(
          'CloseHandle');

  static final _setCommState = _k32.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<_BtDcb>),
      int Function(int, ffi.Pointer<_BtDcb>)>('SetCommState');

  /// 往蓝牙串口写 ESC/POS 字节流
  static Future<void> printTo(String port, List<int> bytes) async {
    final full = port.toUpperCase().startsWith(r'\\.\')
        ? port
        : '\\\\.\\${port.replaceAll(r'\\.\', '')}';
    final wpath = full.toNativeUtf16().cast<ffi.Uint16>();
    final handle = calloc<ffi.IntPtr>();
    final written = calloc<ffi.Uint32>();
    final dcb = calloc<_BtDcb>();
    ffi.Pointer<ffi.Uint8>? pBytes;
    try {
      final h = _createFileW(wpath, _genericRead | _genericWrite, 0,
          ffi.Pointer<ffi.Void>.fromAddress(0), _openExisting, 0, 0);
      if (h == -1 || h == 0) {
        throw ApiError('打开蓝牙串口失败：$port（请确认打印机已开机且在系统蓝牙设置中已配对）');
      }
      handle.value = h;
      // 蓝牙 SPP 虚拟串口波特率仅是占位（数据走蓝牙栈），9600 即可
      dcb.ref
        ..dcbLength = ffi.sizeOf<_BtDcb>()
        ..baudRate = 9600
        ..flags = 0x1011 // fBinary=1 | DTR/RTS 使能
        ..byteSize = 8
        ..parity = 0
        ..stopBits = 0;
      if (_setCommState(h, dcb) == 0) {
        throw ApiError('蓝牙串口参数设置失败：$port');
      }
      pBytes = calloc<ffi.Uint8>(bytes.length);
      pBytes.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final chunk =
            (bytes.length - offset) > 1024 ? 1024 : bytes.length - offset;
        final ok = _writeFile(h, ffi.Pointer<ffi.Uint8>.fromAddress(
                pBytes.address + offset),
            chunk, written, ffi.Pointer<ffi.Void>.fromAddress(0));
        if (ok == 0 || written.value <= 0) {
          throw ApiError('小票数据发送失败（请检查打印机电源、纸仓与蓝牙连接）');
        }
        offset += written.value;
        await Future.delayed(const Duration(milliseconds: 5));
      }
    } finally {
      if (handle.value != 0) _closeHandle(handle.value);
      calloc.free(wpath);
      calloc.free(handle);
      calloc.free(written);
      calloc.free(dcb);
      if (pBytes != null) calloc.free(pBytes);
    }
  }
}

// ---------------- Win32 结构体 ----------------

final class _Guid extends ffi.Struct {
  @ffi.Uint32()
  external int d1;

  @ffi.Uint16()
  external int d2;

  @ffi.Uint16()
  external int d3;

  @ffi.Array.multi([8])
  external ffi.Array<ffi.Uint8> d4;

  void setTail(int hi, int lo) {
    d4[0] = (hi >> 8) & 0xFF;
    d4[1] = hi & 0xFF;
    for (var i = 0; i < 6; i++) {
      d4[2 + i] = (lo >> (8 * (5 - i))) & 0xFF;
    }
  }
}

/// SP_DEVINFO_DATA（sizeof = 32，64 位）
final class _DevinfoData extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize;

  @ffi.Array.multi([16])
  external ffi.Array<ffi.Uint8> classGuid;

  @ffi.Uint32()
  external int devInst;

  @ffi.Uint64()
  external int reserved;
}

/// 精简 DCB（只设常用字段，布局同 Win32 DCB 前 5 项）
final class _BtDcb extends ffi.Struct {
  @ffi.Uint32()
  external int dcbLength;

  @ffi.Uint32()
  external int baudRate;

  @ffi.Uint32()
  external int flags;

  @ffi.Uint16()
  external int wReserved;

  @ffi.Uint16()
  external int xonLim;

  @ffi.Uint16()
  external int xoffLim;

  @ffi.Uint8()
  external int byteSize;

  @ffi.Uint8()
  external int parity;

  @ffi.Uint8()
  external int stopBits;

  @ffi.Int8()
  external int xonChar;

  @ffi.Int8()
  external int xoffChar;

  @ffi.Int8()
  external int errorChar;

  @ffi.Int8()
  external int eofChar;

  @ffi.Int8()
  external int evtChar;

  @ffi.Uint16()
  external int wReserved1;
}
