import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Windows 串口直读（Win32 API，无第三方插件）
///
/// 适配收银机常见电子秤：USB转串口（CH340/CP2102/PL2303）或主板 COM 口。
/// 仅 Windows 可用；其它系统由上层回退到键盘口秤。
class WinSerial {
  static bool get supported => Platform.isWindows;

  ffi.Pointer<ffi.Void>? _handle; // null=未打开
  bool get isOpen => _handle != null;

  static const _invalidHandle = -1;
  static const _genericRead = 0x80000000;
  static const _genericWrite = 0x40000000;
  static const _openExisting = 3;

  // ---------------- Win32 绑定 ----------------
  static final _k32 = ffi.DynamicLibrary.open('kernel32.dll');

  static final _createFileW = _k32.lookupFunction<
      ffi.IntPtr Function(ffi.Pointer<ffi.Uint16>, ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Void>,
          ffi.Uint32, ffi.Uint32, ffi.IntPtr),
      int Function(ffi.Pointer<ffi.Uint16>, int, int, ffi.Pointer<ffi.Void>, int, int,
          int)>('CreateFileW');

  static final _closeHandle = _k32.lookupFunction<ffi.Int32 Function(ffi.IntPtr), int Function(int)>(
      'CloseHandle');

  static final _setCommState = _k32.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<_Dcb>),
      int Function(int, ffi.Pointer<_Dcb>)>('SetCommState');

  static final _setCommTimeouts = _k32.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<_CommTimeouts>),
      int Function(int, ffi.Pointer<_CommTimeouts>)>('SetCommTimeouts');

  static final _purgeComm = _k32.lookupFunction<ffi.Int32 Function(ffi.IntPtr, ffi.Uint32),
      int Function(int, int)>('PurgeComm');

  static final _readFile = _k32.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<ffi.Uint8>, ffi.Uint32,
          ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Void>),
      int Function(int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint32>,
          ffi.Pointer<ffi.Void>)>('ReadFile');

  static final _writeFile = _k32.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<ffi.Uint8>, ffi.Uint32,
          ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Void>),
      int Function(int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint32>,
          ffi.Pointer<ffi.Void>)>('WriteFile');

  /// 打开串口：portName 形如 COM3 / \\.\COM10
  bool open(String portName, int baud) {
    if (!supported) return false;
    close();
    final path = portName.trim();
    if (path.isEmpty) return false;
    // COM10 及以上必须用 \\.\COMxx 形式
    final full = path.toUpperCase().startsWith(r'\\.\') ? path : '\\\\.\\${path.replaceAll(r'\\.\', '')}';
    final wpath = full.toNativeUtf16().cast<ffi.Uint16>();
    try {
      final h = _createFileW(wpath, _genericRead | _genericWrite, 0, ffi.nullptr, _openExisting, 0, 0);
      if (h == _invalidHandle) return false;
      _handle = ffi.Pointer<ffi.Void>.fromAddress(h);

      final dcb = calloc<_Dcb>();
      final tmo = calloc<_CommTimeouts>();
      try {
        dcb.ref
          ..dcbLength = ffi.sizeOf<_Dcb>()
          ..baudRate = baud
          // fBinary=1 | fDtrControl=ENABLE(1<<4) | fRtsControl=ENABLE(1<<12)
          ..flags = 0x1011
          ..byteSize = 8
          ..parity = 0 // NOPARITY
          ..stopBits = 0; // ONESTOPBIT
        if (_setCommState(_handle!.address, dcb) == 0) {
          close();
          return false;
        }
        tmo.ref
          ..readIntervalTimeout = 50
          ..readTotalTimeoutMultiplier = 0
          ..readTotalTimeoutConstant = 50
          ..writeTotalTimeoutMultiplier = 0
          ..writeTotalTimeoutConstant = 100;
        _setCommTimeouts(_handle!.address, tmo);
      } finally {
        calloc.free(dcb);
        calloc.free(tmo);
      }
      _purgeComm(_handle!.address, 0x000F); // 清空收发缓冲
      return true;
    } finally {
      calloc.free(wpath);
    }
  }

  /// 读一批字节；无数据返回空
  Uint8List read({int max = 256}) {
    if (!isOpen) return Uint8List(0);
    final buf = calloc<ffi.Uint8>(max);
    final got = calloc<ffi.Uint32>();
    try {
      final ok = _readFile(_handle!.address, buf, max, got, ffi.nullptr);
      if (ok == 0) return Uint8List(0);
      final n = got.value;
      if (n <= 0) return Uint8List(0);
      return Uint8List.fromList(List<int>.generate(n, (i) => buf[i]));
    } finally {
      calloc.free(buf);
      calloc.free(got);
    }
  }

  /// 写入原始字节（置零/去皮指令下发）；成功返回 true
  bool write(Uint8List data) {
    if (!isOpen || data.isEmpty) return false;
    final buf = calloc<ffi.Uint8>(data.length);
    final sent = calloc<ffi.Uint32>();
    try {
      buf.asTypedList(data.length).setAll(0, data);
      return _writeFile(_handle!.address, buf, data.length, sent, ffi.nullptr) != 0;
    } catch (_) {
      return false;
    } finally {
      calloc.free(buf);
      calloc.free(sent);
    }
  }

  void close() {
    final h = _handle;
    if (h != null) {
      try {
        _closeHandle(h.address);
      } catch (_) {}
    }
    _handle = null;
  }

  /// 枚举 COM1..COM32 中可打开的口（Windows 无枚举 API，探测最实用）
  static List<String> availablePorts() {
    if (!supported) return const [];
    final out = <String>[];
    for (var i = 1; i <= 32; i++) {
      final s = WinSerial();
      try {
        if (s.open('COM$i', 9600)) out.add('COM$i');
      } finally {
        s.close();
      }
    }
    return out;
  }
}

/// Win32 DCB（串口参数），布局与 sizeof(DCB)=28 字节一致
final class _Dcb extends ffi.Struct {
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

/// Win32 COMMTIMEOUTS
final class _CommTimeouts extends ffi.Struct {
  @ffi.Uint32()
  external int readIntervalTimeout;

  @ffi.Uint32()
  external int readTotalTimeoutMultiplier;

  @ffi.Uint32()
  external int readTotalTimeoutConstant;

  @ffi.Uint32()
  external int writeTotalTimeoutMultiplier;

  @ffi.Uint32()
  external int writeTotalTimeoutConstant;
}
