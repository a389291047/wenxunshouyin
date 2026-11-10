import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scale_win.dart';

/// 平台能力：哪些端支持接电子秤
///
/// - Windows：键盘口秤（USB-HID）+ 串口秤（COM / RS232，市面通用收银秤）
/// - 安卓：键盘口秤 + 一体机内置秤（商米等，走原生广播）
/// - 苹果 macOS：不接秤，称重弹窗只手工输入重量（保持 v3.3.182 的交互）
class ScaleSupport {
  static bool get isWindows => Platform.isWindows;
  static bool get isAndroid => Platform.isAndroid;

  /// 本机是否支持接电子秤（苹果端为 false，设置页不显示「称重设备」）
  static bool get canUseScale => isWindows || isAndroid;

  /// 是否有「一体机内置秤」（安卓走原生广播监听）
  static bool get hasBuiltin => isAndroid;

  /// 是否支持串口秤（仅 Windows）
  static bool get hasSerial => isWindows;
}

/// 电子秤配置（本机保存，随收银机走）
///
/// 连接方式 mode：
/// - keyboard：键盘口秤（USB-HID，免驱）—— Windows / 安卓通用
/// - serial：串口秤（COM / RS232）—— 仅 Windows
/// - builtin：一体机内置秤（商米等）—— 仅安卓
class ScalePrefs {
  static const kEnabled = 'scale_enabled';
  static const kMode = 'scale_mode'; // keyboard / serial / builtin
  static const kPort = 'scale_port'; // COM3
  static const kBaud = 'scale_baud'; // 9600
  static const kUnit = 'scale_unit'; // auto / kg / g / jin

  bool enabled = false;
  String mode = 'keyboard';
  String port = '';
  int baud = 9600;
  String unit = 'auto';

  static Future<ScalePrefs> load() async {
    final sp = await SharedPreferences.getInstance();
    final m = sp.getString(kMode) ?? 'keyboard';
    return ScalePrefs()
      ..enabled = sp.getBool(kEnabled) ?? false
      // 非 Android 不允许 builtin（换端后不残留）
      ..mode = (m == 'builtin' && !ScaleSupport.hasBuiltin) ? 'keyboard' : m
      ..port = sp.getString(kPort) ?? ''
      ..baud = sp.getInt(kBaud) ?? 9600
      ..unit = sp.getString(kUnit) ?? 'auto';
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(kEnabled, enabled);
    await sp.setString(kMode, mode);
    await sp.setString(kPort, port);
    await sp.setInt(kBaud, baud);
    await sp.setString(kUnit, unit);
  }

  String get modeLabel => const {
        'serial': '串口（COM）',
        'builtin': '一体机内置秤',
        'keyboard': '键盘口（USB-HID）',
      }[mode] ??
      '键盘口（USB-HID）';

  String get unitLabel => const {'auto': '自动识别', 'kg': '千克 kg', 'g': '克 g', 'jin': '斤'}[unit] ?? '自动识别';
}

/// 电子秤报文解析：把各种秤的原始行解析成「千克」
///
/// 兼容常见格式：
/// - `ST,GS,+  0.525kg`（托利多/顶尖/大华 ACS 系列，稳定位+总重位）
/// - `= 0.525 kg` / `US,GS,+ 0.525kg`
/// - `0525 g` / `525g`（克为单位）
/// - `12.5斤`
/// - 裸数字 `0.525`（按配置单位解释）
class ScaleParser {
  /// 返回千克值；无法识别返回 null
  static double? parseKg(String raw, {String unitPref = 'auto'}) {
    final line = raw.trim();
    if (line.isEmpty) return null;

    // 报文形如 "ST,GS,+ 0.525kg"：状态位（ST/GS/US）不含数字，取最后一个十进制数即重量
    final matches = RegExp(r'\d+(?:\.\d+)?').allMatches(line).toList();
    if (matches.isEmpty) return null;
    final value = double.tryParse(matches.last.group(0)!);
    if (value == null) return null;

    final low = line.toLowerCase();
    String unit;
    if (unitPref != 'auto') {
      unit = unitPref;
    } else if (low.contains('kg')) {
      unit = 'kg';
    } else if (low.contains('斤')) {
      unit = 'jin';
    } else if (RegExp(r'g\b').hasMatch(low) || low.endsWith('g')) {
      unit = 'g';
    } else {
      unit = 'kg'; // 裸数字默认按千克
    }

    switch (unit) {
      case 'g':
        return value / 1000.0;
      case 'jin':
        return value * 0.5; // 1 斤 = 0.5 kg
      default:
        return value;
    }
  }

  /// 一体机内置秤（原生广播）给的是纯数值，没有单位
  ///
  /// 商米/天波等机型多数回传「克」（如 525 表示 525g），也有回传千克的；
  /// 自动模式下 ≥20 按克处理（20kg 以上的散称商品极少，误判风险低）。
  static double? fromRawValue(double v, {String unitPref = 'auto'}) {
    if (v.isNaN || v.isInfinite || v <= 0) return null;
    switch (unitPref) {
      case 'g':
        return v / 1000.0;
      case 'jin':
        return v * 0.5;
      case 'kg':
        return v;
      default:
        return v >= 20 ? v / 1000.0 : v;
    }
  }
}

/// 一体机内置秤（安卓）：走原生广播（商米 / 天波等一体机自带秤）
///
/// 原生端（MainActivity）监听常见厂商广播 action，收到重量后通过
/// `wenxun/scale` 通道的 `weight` 回传（单位按克/千克原样给，Dart 侧换算）。
/// 非安卓设备调用 start() 返回 false，不影响手输。
class BuiltinScale {
  static const _ch = MethodChannel('wenxun/scale');

  final _out = StreamController<double>.broadcast();
  Stream<double> get stream => _out.stream;

  bool _connected = false;
  bool get connected => _connected;

  static bool get supported => ScaleSupport.hasBuiltin;

  static bool _handlerSet = false;

  Future<bool> start({String unitPref = 'auto'}) async {
    if (!supported) return false;
    try {
      if (!_handlerSet) {
        _ch.setMethodCallHandler((call) async {
          if (call.method == 'weight') {
            final v = (call.arguments as num?)?.toDouble();
            if (v == null) return null;
            final kg = ScaleParser.fromRawValue(v, unitPref: unitPref);
            if (kg != null && kg >= 0) {
              _connected = true;
              if (!_out.isClosed) _out.add(kg);
            }
          }
          return null;
        });
        _handlerSet = true;
      }
      final ok = await _ch.invokeMethod<bool>('start');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  void stop() {
    if (!supported) return;
    try {
      _ch.invokeMethod('stop');
    } catch (_) {}
  }

  void dispose() {
    stop();
    if (!_out.isClosed) _out.close();
  }
}

/// 串口电子秤读取
///
/// Windows：Win32 API 直读（scale_win.dart），无需第三方驱动/插件；
/// 其它系统：不支持（安卓走内置秤/键盘口）。
class SerialScale {
  WinSerial? _port;
  Timer? _timer;
  String _buf = '';
  double? _last;
  DateTime? _lastAt;
  bool _gotData = false;
  final _out = StreamController<double>.broadcast();

  Stream<double> get stream => _out.stream;
  double? get last => _last;

  /// 真正「连上」= 端口打开且读到过重量（只打开端口不算，避免误报绿灯）
  bool get connected => _port != null && _gotData;

  static bool get supported => WinSerial.supported;

  static List<String> availablePorts() => WinSerial.availablePorts();

  /// 打开串口并开始轮询读取；成功返回 true
  bool start({required String portName, required int baud, String unitPref = 'auto'}) {
    stop();
    if (!WinSerial.supported) return false;
    final port = WinSerial();
    if (!port.open(portName, baud)) {
      port.close();
      return false;
    }
    _port = port;
    _buf = '';
    _gotData = false;
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) => _poll(unitPref));
    return true;
  }

  void _poll(String unitPref) {
    final port = _port;
    if (port == null || !port.isOpen) return;
    try {
      final data = port.read();
      if (data.isEmpty) return;
      _buf += latin1.decode(data, allowInvalid: true);
      // 按换行/回车切帧，剩余半帧留到下次
      final lines = _buf.split(RegExp(r'[\r\n]+'));
      _buf = lines.removeLast();
      if (_buf.length > 200) _buf = '';
      for (final line in lines) {
        final kg = ScaleParser.parseKg(line, unitPref: unitPref);
        if (kg != null && kg >= 0) _emit(kg);
      }
    } catch (_) {
      stop(); // 串口被拔掉等异常
    }
  }

  void _emit(double kg) {
    // 去抖：同一读数 300ms 内只发一次
    final now = DateTime.now();
    if (_lastAt != null && now.difference(_lastAt!).inMilliseconds < 300 && kg == _last) return;
    _lastAt = now;
    _last = kg;
    _gotData = true;
    if (!_out.isClosed) _out.add(kg);
  }

  /// 等第一帧读数（用于现场检测/自动探测端口）
  Future<double?> firstReading(Duration window) async {
    try {
      return await stream.first.timeout(window);
    } catch (_) {
      return null;
    }
  }

  /// 自动探测：遍历 COM1..COM20 × 常见波特率，谁先读到重量就用谁
  ///
  /// 收银员不用懂 COM 号和波特率，插上秤点「自动检测」即可。
  /// 打不开的口会瞬间跳过，正常只有 1~2 个串口存在，耗时很短。
  static Future<ScaleProbe?> autoDetect({
    List<int> bauds = const [9600, 4800, 19200, 38400, 115200],
    Duration window = const Duration(milliseconds: 900),
  }) async {
    if (!WinSerial.supported) return null;
    for (var i = 1; i <= 20; i++) {
      final name = 'COM$i';
      // 先试探这个口是否存在，不存在直接跳过（不浪费时间试波特率）
      final probe = WinSerial();
      final opened = probe.open(name, 9600);
      probe.close();
      if (!opened) continue;

      for (final b in bauds) {
        final s = SerialScale();
        if (!s.start(portName: name, baud: b, unitPref: 'auto')) continue;
        final kg = await s.firstReading(window);
        s.dispose();
        if (kg != null && kg > 0) return ScaleProbe(port: name, baud: b, kg: kg);
      }
    }
    return null;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    try {
      _port?.close();
    } catch (_) {}
    _port = null;
    _buf = '';
    _gotData = false;
  }

  void dispose() {
    stop();
    _out.close();
  }
}

/// 自动探测结果
class ScaleProbe {
  final String port;
  final int baud;
  final double kg;
  const ScaleProbe({required this.port, required this.baud, required this.kg});
}

/// 键盘口电子秤：秤以键盘方式「打」出重量并回车。
/// 收银界面（称重弹窗）挂一个监听即可，不影响其他输入。
class KeyboardScale {
  final StringBuffer _buf = StringBuffer();
  Timer? _reset;
  DateTime _lastKey = DateTime.now();
  double? _pending; // 最近一帧解析结果（无回车协议由定时器兜底写入）

  /// 喂入一个按键；凑够一帧（回车）返回解析后的千克值
  double? feed(KeyEvent e, {String unitPref = 'auto'}) {
    final now = DateTime.now();
    // 两次按键间隔超过 1.2 秒视为新的一帧（秤连续发送时以回车切帧）
    if (now.difference(_lastKey).inMilliseconds > 1200) _buf.clear();
    _lastKey = now;

    final ch = e.character;
    if (e is KeyDownEvent && ch != null && ch.isNotEmpty) {
      if (ch == '\r' || ch == '\n') {
        final line = _buf.toString();
        _buf.clear();
        final kg = ScaleParser.parseKg(line, unitPref: unitPref);
        if (kg != null && kg >= 0) _pending = kg;
        return kg;
      }
      if (RegExp(r'[0-9.,+\-A-Za-z ]').hasMatch(ch)) {
        _buf.write(ch);
        // 有些秤用 'g' / 'kg' 结尾后即发送，不加回车也能收到
        if (_buf.length > 60) _buf.clear();
      }
    }
    // 无回车协议兜底：1 秒内没新键且缓冲里有数字，按一帧处理
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 900), () {
      final line = _buf.toString();
      _buf.clear();
      if (line.trim().isEmpty) return;
      final kg = ScaleParser.parseKg(line, unitPref: unitPref);
      if (kg != null && kg >= 0) _pending = kg;
    });
    return null;
  }

  /// 取走最近一帧读数（无回车协议由 900ms 静默兜底）
  double? takePending() {
    final v = _pending;
    _pending = null;
    return v;
  }

  void clear() {
    _buf.clear();
    _pending = null;
    _reset?.cancel();
  }
}
