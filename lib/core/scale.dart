import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scale_win.dart';

/// 电子秤配置（本机保存，随收银机走）
///
/// 支持两类 Windows 常见收银秤：
/// - 键盘口（USB-HID，免驱）：秤把重量当键盘输入发出来，以回车结束，最常见
/// - 串口（RS232 / USB转串口）：COM 口 + 波特率，票据秤/大台秤常用
class ScalePrefs {
  static const kEnabled = 'scale_enabled';
  static const kMode = 'scale_mode'; // keyboard / serial
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
    return ScalePrefs()
      ..enabled = sp.getBool(kEnabled) ?? false
      ..mode = sp.getString(kMode) ?? 'keyboard'
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

  String get modeLabel => mode == 'serial' ? '串口（COM）' : '键盘口（USB-HID）';
  String get unitLabel => const {'auto': '自动识别', 'kg': '千克 kg', 'g': '克 g', 'jin': '斤'}[unit] ?? '自动识别';
}

/// 电子秤报文解析：把各种秤的原始行解析成「千克」
///
/// 兼容常见格式：
/// - `ST,GS,+  0.525kg`（顶尖/大华 ACS 系列，稳定位+总重位）
/// - `= 0.525 kg`
/// - `0525 g` / `525g`（克为单位）
/// - `12.5斤`
/// - 裸数字 `0.525`（按配置单位解释）
class ScaleParser {
  /// 返回千克值；无法识别返回 null
  static double? parseKg(String raw, {String unitPref = 'auto'}) {
    final line = raw.trim();
    if (line.isEmpty) return null;

    // 报文形如 "ST,GS,+ 0.525kg" / "= 0.525 kg" / " 0.525"：
    // 状态位（ST/GS/US）不含数字，取最后一个十进制数即重量
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
}

/// 串口电子秤读取
///
/// Windows：Win32 API 直读（scale_win.dart），无需第三方驱动/插件；
/// 其它系统：暂不支持（回退键盘口秤）。
class SerialScale {
  WinSerial? _port;
  Timer? _timer;
  String _buf = '';
  double? _last;
  DateTime? _lastAt;
  final _out = StreamController<double>.broadcast();

  Stream<double> get stream => _out.stream;
  double? get last => _last;
  bool get connected => _port?.isOpen ?? false;

  /// 当前系统是否支持串口模式（仅 Windows）
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
    if (!_out.isClosed) _out.add(kg);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    try {
      _port?.close();
    } catch (_) {}
    _port = null;
    _buf = '';
  }

  void dispose() {
    stop();
    _out.close();
  }
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
