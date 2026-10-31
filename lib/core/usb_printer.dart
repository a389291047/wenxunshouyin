import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffi/ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'esc_pos.dart';

/// 本机 USB 小票打印机（Windows winspool RAW / macOS CUPS raw 队列 / Android USB Host）
class UsbPrinter {
  UsbPrinter._();

  static const prefEnabled = 'usb_print_enabled';
  static const prefPrinter = 'usb_print_printer';
  static const prefPaper = 'usb_print_paper';

  static const _channel = MethodChannel('wenxun/usb_printer');

  static bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isAndroid;

  // ==================== 配置读写 ====================

  static Future<bool> enabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(prefEnabled) ?? false;
  }

  /// 打印分流入口：未启用返回 false（调用方回退云打印）；
  /// 已启用则直接走本地 USB 打印，失败抛 ApiError。
  static Future<bool> tryPrint(String content) async {
    if (!await enabled()) return false;
    final p = await selectedPrinter();
    if (p == null) {
      throw ApiError('已启用 USB 打印但未选择打印机，请到「设置 → USB小票打印机」选择');
    }
    final sp = await SharedPreferences.getInstance();
    final width = sp.getInt(prefPaper) ?? 58;
    await printTicket(p, content, paperWidth: width);
    return true;
  }

  static Future<Map<String, dynamic>?> selectedPrinter() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(prefPrinter);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ==================== 打印机枚举 ====================

  /// 返回 [{id, name, kind, ...}]，kind: win / queue / usb / sunmi
  static Future<List<Map<String, dynamic>>> list() async {
    if (Platform.isWindows) return _listWindows();
    if (Platform.isMacOS) return _listMacos();
    if (Platform.isAndroid) {
      final res = await _channel.invokeMethod<List<dynamic>>('list');
      return (res ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .map((m) {
            final kind = '${m['kind'] ?? 'usb'}';
            return <String, dynamic>{
              'id': kind == 'sunmi' ? 'sunmi' : '${m['vid']}:${m['pid']}',
              'vid': m['vid'],
              'pid': m['pid'],
              'name': m['name'] ?? (kind == 'sunmi' ? '商米内置打印机' : 'USB打印机'),
              'kind': kind,
              'hasPermission': m['hasPermission'] == true,
            };
          })
          .toList();
    }
    return [];
  }

  // ==================== 打印 ====================

  static Future<void> printTicket(
      Map<String, dynamic> printer, String content,
      {int paperWidth = 58}) async {
    final bytes = EscPos.encode(content, paperWidth: paperWidth);
    if (Platform.isWindows) {
      await _printWindows('${printer['id']}', bytes);
    } else if (Platform.isMacOS) {
      await _printMacos(printer, bytes);
    } else if (Platform.isAndroid) {
      await _channel.invokeMethod('print', {
        'kind': '${printer['kind'] ?? 'usb'}',
        'vid': printer['vid'],
        'pid': printer['pid'],
        'bytes': Uint8List.fromList(bytes),
      });
    } else {
      throw ApiError('当前平台不支持 USB 打印');
    }
  }

  // ==================== Windows: winspool RAW ====================

  static final ffi.DynamicLibrary _ws = ffi.DynamicLibrary.open('winspool.drv');

  static List<Map<String, dynamic>> _listWindows() {
    final enumPrinters = _ws.lookupFunction<
        ffi.IntPtr Function(ffi.Uint32, ffi.Pointer<Utf16>, ffi.Uint32,
            ffi.Pointer<ffi.Uint8>, ffi.Uint32, ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>),
        int Function(int, ffi.Pointer<Utf16>, int, ffi.Pointer<ffi.Uint8>,
            int, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint32>)>(
        'EnumPrintersW');
    final needed = calloc<ffi.Uint32>();
    final returned = calloc<ffi.Uint32>();
    ffi.Pointer<ffi.Uint8> buf = ffi.Pointer.fromAddress(0);
    try {
      // PRINTER_ENUM_LOCAL(2) | PRINTER_ENUM_CONNECTIONS(4)，level 4
      const flags = 2 | 4;
      enumPrinters(flags, (ffi.Pointer<Utf16>.fromAddress(0)), 4,
          ffi.Pointer<ffi.Uint8>.fromAddress(0), 0, needed, returned);
      final size = needed.value;
      if (size == 0) return [];
      buf = calloc<ffi.Uint8>(size);
      final r = enumPrinters(flags, (ffi.Pointer<Utf16>.fromAddress(0)), 4, buf, size, needed, returned);
      if (r == 0) throw ApiError('枚举系统打印机失败（winspool）');
      final n = returned.value;
      // PRINTER_INFO_4: {LPWSTR name; LPWSTR server; DWORD attr;} 64位占 24 字节
      final out = <Map<String, dynamic>>[];
      final fields = buf.cast<ffi.Pointer<Utf16>>();
      for (var i = 0; i < n; i++) {
        final namePtr = fields.elementAt(i * 3).value; // 每元素 3 个指针槽
        if (namePtr.address == 0) continue;
        final name = namePtr.toDartString();
        out.add({'id': name, 'name': name, 'kind': 'win'});
      }
      return out;
    } finally {
      calloc.free(needed);
      calloc.free(returned);
      if (buf.address != 0) calloc.free(buf);
    }
  }

  static Future<void> _printWindows(String name, Uint8List bytes) async {
    final openPrinter = _ws.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf16>, ffi.Pointer<ffi.IntPtr>,
            ffi.Pointer<ffi.Void>),
        int Function(ffi.Pointer<Utf16>, ffi.Pointer<ffi.IntPtr>,
            ffi.Pointer<ffi.Void>)>('OpenPrinterW');
    final startDoc = _ws.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Int32, ffi.Pointer<ffi.Uint8>),
        int Function(int, int, ffi.Pointer<ffi.Uint8>)>('StartDocPrinterW');
    final startPage = _ws.lookupFunction<ffi.Int32 Function(ffi.IntPtr),
        int Function(int)>('StartPagePrinter');
    final write = _ws.lookupFunction<
        ffi.Int32 Function(
            ffi.IntPtr, ffi.Pointer<ffi.Uint8>, ffi.Int32, ffi.Pointer<ffi.Int32>),
        int Function(int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Int32>)>(
        'WritePrinter');
    final endPage = _ws.lookupFunction<ffi.Int32 Function(ffi.IntPtr),
        int Function(int)>('EndPagePrinter');
    final endDoc = _ws.lookupFunction<ffi.Int32 Function(ffi.IntPtr),
        int Function(int)>('EndDocPrinter');
    final close = _ws.lookupFunction<ffi.Int32 Function(ffi.IntPtr),
        int Function(int)>('ClosePrinter');

    final pName = name.toNativeUtf16();
    final handle = calloc<ffi.IntPtr>();
    final docName = '稳讯收银小票'.toNativeUtf16();
    final dataType = 'RAW'.toNativeUtf16();
    final doc = calloc<ffi.Uint8>(24); // DOC_INFO_1: pDocName/pOutputFile/pDatatype
    final written = calloc<ffi.Int32>();
    ffi.Pointer<ffi.Uint8>? pBytes;
    try {
      if (openPrinter(pName, handle, ffi.Pointer<ffi.Void>.fromAddress(0)) == 0 || handle.value == 0) {
        throw ApiError('打开打印机失败：$name（请确认已连接并安装驱动）');
      }
      final h = handle.value;
      final pDoc = doc.cast<ffi.Pointer<Utf16>>();
      pDoc[0] = docName;
      pDoc[1] = (ffi.Pointer<Utf16>.fromAddress(0));
      pDoc[2] = dataType;
      if (startDoc(h, 1, doc) == 0) throw ApiError('创建打印任务失败');
      if (startPage(h) == 0) throw ApiError('启动打印页失败');
      pBytes = calloc<ffi.Uint8>(bytes.length);
      pBytes.asTypedList(bytes.length).setAll(0, bytes);
      final ok = write(h, pBytes, bytes.length, written) != 0 &&
          written.value == bytes.length;
      endPage(h);
      endDoc(h);
      close(h);
      if (!ok) throw ApiError('小票数据发送失败（请检查打印机电源与纸仓）');
    } finally {
      calloc.free(pName);
      calloc.free(docName);
      calloc.free(dataType);
      calloc.free(doc);
      calloc.free(handle);
      calloc.free(written);
      if (pBytes != null) calloc.free(pBytes!);
    }
  }

  // ==================== macOS: CUPS ====================

  static Future<String> _runMac(String exe, List<String> args) async {
    final r = await Process.run(exe, args, runInShell: false);
    if (r.exitCode != 0) {
      throw ApiError('$exe 失败：${(r.stderr as String).trim()}');
    }
    return '${r.stdout}';
  }

  static Future<List<Map<String, dynamic>>> _listMacos() async {
    final out = <Map<String, dynamic>>[];
    // 1. 已存在的 CUPS 队列
    try {
      final r = await Process.run('/usr/sbin/lpstat', const ['-p']);
      for (final line in '${r.stdout}'.split('\n')) {
        if (line.startsWith('printer ')) {
          final name = line.substring(8).split(' ').first;
          out.add({'id': name, 'name': name, 'kind': 'queue'});
        }
      }
    } catch (_) {}
    // 2. 直连的 USB 打印设备（可能还没建队列）
    final queueUris = <String, Map<String, dynamic>>{};
    try {
      final r = await Process.run('/usr/sbin/lpstat', const ['-v']);
      for (final line in '${r.stdout}'.split('\n')) {
        final m = RegExp(r'device for (\S+): (.+)$').firstMatch(line.trim());
        if (m != null) queueUris[m.group(2)!] = {'id': m.group(1)};
      }
    } catch (_) {}
    try {
      final r = await Process.run('/usr/sbin/lpinfo', const ['-v']);
      for (final line in '${r.stdout}'.split('\n')) {
        final parts = line.trim().split(' ');
        if (parts.length < 2) continue;
        final uri = parts.last;
        if (!uri.startsWith('usb://')) continue;
        final label = uri.substring(6).split('?').first.replaceAll('/', ' ').trim();
        final hasQueue = queueUris.containsKey(uri);
        out.add({
          'id': hasQueue ? queueUris[uri]!['id'] : uri,
          'name': hasQueue ? '${queueUris[uri]!['id']}（$label）' : label,
          'kind': hasQueue ? 'queue' : 'usb',
          'uri': uri,
        });
      }
    } catch (_) {}
    // 去重
    final seen = <String>{};
    return out.where((e) => seen.add('${e['id']}')).toList();
  }

  static Future<void> _printMacos(
      Map<String, dynamic> printer, Uint8List bytes) async {
    var queue = '${printer['id']}';
    // USB 直连设备先自动创建 raw 队列（管理员组成员无需 sudo）
    if ('${printer['kind']}' == 'usb') {
      final uri = '${printer['uri']}';
      try {
        await _runMac(
            '/usr/sbin/lpadmin', ['-p', 'WenXunUSB', '-E', '-v', uri, '-m', 'raw']);
      } on ApiError catch (e) {
        throw ApiError('创建 macOS 打印队列失败：${e.message}。'
            '可手动创建：系统设置 → 打印机与扫描仪 → 添加打印机，或终端执行'
            ' sudo lpadmin -p WenXunUSB -E -v $uri -m raw');
      }
      queue = 'WenXunUSB';
    }
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/wenxun_esc_${DateTime.now().millisecondsSinceEpoch}.bin');
    await f.writeAsBytes(bytes, flush: true);
    try {
      final r = await Process.run('/usr/sbin/lpr', ['-P', queue, '-l', f.path]);
      if (r.exitCode != 0) {
        throw ApiError('打印发送失败：${(r.stderr as String).trim()}（队列 $queue）');
      }
    } finally {
      if (await f.exists()) await f.delete();
    }
  }

  // ==================== Android 权限预检 ====================

  /// 触发系统 USB 权限弹窗（打印时若无权限原生层会自动等待授权，此方法用于设置页主动申请）
  static Future<bool> requestPermission(Map<String, dynamic> printer) async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestPermission', {
            'kind': '${printer['kind'] ?? 'usb'}',
            'vid': printer['vid'],
            'pid': printer['pid'],
          }) ==
          true;
    } catch (_) {
      return false;
    }
  }
}

/// dart:ffi 便捷空指针（避免直接依赖 win32 包）
