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
  /// 解析稳定位：ST=稳定(true)、US=动态/不稳定(false)、识别不出=null
  ///
  /// 报文形如 "ST,GS,+  0.525kg" / "US,GS,+ 0.530kg"（托利多/大华/顶尖通用约定）。
  /// 连续称重流程依赖此位判断「数字稳定闪烁停止」。
  static bool? stableOf(String raw) {
    final line = raw.trim().toUpperCase();
    if (line.isEmpty) return null;
    if (line.startsWith('ST')) return true;
    if (line.startsWith('US')) return false;
    // 部分秤把稳定位放在别处：含 " ST " / " US "
    if (RegExp(r'[,; ]ST[,; ]').hasMatch(line)) return true;
    if (RegExp(r'[,; ]US[,; ]').hasMatch(line)) return false;
    return null;
  }

  /// 返回千克值；无法识别返回 null
  static double? parseKg(String raw, {String unitPref = 'auto'}) {
    final line = raw.trim();
    if (line.isEmpty) return null;

    // 排除仪表原始帧（如耀华 A9 的 "U11T11 2345 03"）和乱码：
    // 没有小数点、没有单位字样、却夹着字母 → 不是人类可读的重量行
    final hasUnit = RegExp(r'kg|g\b|斤', caseSensitive: false).hasMatch(line);
    if (!line.contains('.') && !hasUnit && RegExp(r'[A-Za-z]').hasMatch(line)) {
      return null;
    }

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
  String _portName = '';
  int _baud = 0;
  Timer? _timer;
  String _buf = '';
  DateTime? _lastRx;
  double? _last;
  DateTime? _lastAt;
  bool _gotData = false;
  bool _stable = true; // 最近一帧稳定位（识别不出按稳定处理）
  final _out = StreamController<double>.broadcast();
  final _frames = StreamController<ScaleFrame>.broadcast();

  Stream<double> get stream => _out.stream;

  /// 帧流（重量 + 稳定位）：连续称重/收银页常驻称重条用
  Stream<ScaleFrame> get frameStream => _frames.stream;

  /// 最近一帧是否稳定（数字闪烁停止）
  bool get stable => _stable;

  double? get last => _last;

  String get portName => _portName;
  int get baud => _baud;

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
    _portName = portName;
    _baud = baud;
    _buf = '';
    _lastRx = null;
    _gotData = false;
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) => _poll(unitPref));
    return true;
  }

  void _poll(String unitPref) {
    final port = _port;
    if (port == null || !port.isOpen) return;
    try {
      final data = port.read();
      if (data.isNotEmpty) {
        _lastRx = DateTime.now();
        _buf += latin1.decode(data, allowInvalid: true);
      }
      // 按换行/回车/STX(0x02)/ETX(0x03) 切帧，剩余半帧留到下次。
      // 不少秤的连续帧用 STX/ETX 包夹（如 02 ... 03），不带 \r\n
      final lines = _buf.split(RegExp(r'[\x02\x03\r\n]+'));
      _buf = lines.removeLast();
      if (_buf.length > 200) _buf = '';
      for (final line in lines) {
        _handleLine(line, unitPref);
      }
      // 无结束符协议兜底：缓冲里已有内容但 350ms 没新数据 → 整块当一帧解析
      // （定长帧、纯数字帧等不发结束符的秤靠这条通道出数）
      final rx = _lastRx;
      if (_buf.isNotEmpty &&
          rx != null &&
          DateTime.now().difference(rx).inMilliseconds >= 350) {
        final line = _buf;
        _buf = '';
        _handleLine(line, unitPref);
      }
    } catch (_) {
      stop(); // 串口被拔掉等异常
    }
  }

  void _handleLine(String line, String unitPref) {
    final kg = ScaleParser.parseKg(line, unitPref: unitPref);
    if (kg == null || kg < 0) return;
    final st = ScaleParser.stableOf(line);
    if (st != null) _stable = st;
    _emit(kg);
  }

  void _emit(double kg) {
    // 去抖：同一读数 300ms 内只发一次
    final now = DateTime.now();
    if (_lastAt != null && now.difference(_lastAt!).inMilliseconds < 300 && kg == _last) return;
    _lastAt = now;
    _last = kg;
    _gotData = true;
    final f = ScaleFrame(kg: kg, stable: _stable);
    if (!_out.isClosed) _out.add(kg);
    if (!_frames.isClosed) _frames.add(f);
  }

  /// 下发指令（置零/去皮等）。注意：连续输出协议的秤不接受指令，发了也没反应
  bool sendCommand(String cmd) {
    final port = _port;
    if (port == null || !port.isOpen) return false;
    try {
      return port.write(latin1.encode(cmd));
    } catch (_) {
      return false;
    }
  }

  /// 等第一帧读数（用于现场检测/自动探测端口）
  Future<double?> firstReading(Duration window) async {
    try {
      return await stream.first.timeout(window);
    } catch (_) {
      return null;
    }
  }

  /// 探测窗口：收集若干帧，够数且读数稳定（乱码噪声帧彼此跳变，稳定读数一致）即认成功。
  ///
  /// - minFrames：至少 3 帧；若其中出现 >0.05kg 的实重，2 帧一致也可提前认（秤每秒 1 帧时太慢）
  /// - maxSpread：帧间最大差 0.5kg；乱码/波特率不对时数字乱跳，会被过滤
  /// - maxKg：单帧上限 500kg（收银秤物理不可能，防乱码误判）
  Future<ScaleProbe?> probeFor({
    required Duration window,
    List<String> queryCmds = const [],
    int minFrames = 3,
    double maxSpread = 0.5,
    double maxKg = 500,
  }) async {
    final frames = <double>[];
    final sub = stream.listen(frames.add);
    final sw = Stopwatch()..start();
    var cmdIdx = 0;
    var lastCmdAt = DateTime.now();
    try {
      while (sw.elapsed < window) {
        await Future.delayed(const Duration(milliseconds: 60));
        // 静默口（指令问答式秤）：没收到连续流时，每隔 450ms 发一条查询指令试探
        if (frames.isEmpty &&
            cmdIdx < queryCmds.length &&
            DateTime.now().difference(lastCmdAt).inMilliseconds >= 450) {
          sendCommand(queryCmds[cmdIdx++]);
          lastCmdAt = DateTime.now();
        }
        if (frames.length < 2) continue;
        final mx = frames.reduce(_maxD);
        final mn = frames.reduce(_minD);
        if (mx > maxKg || (mx - mn) > maxSpread) {
          frames.clear(); // 乱码：清空重新统计
          continue;
        }
        final real = frames.any((v) => v > 0.05);
        if (frames.length >= minFrames || (real && frames.length >= 2)) {
          return ScaleProbe(port: _portName, baud: _baud, kg: frames.last);
        }
      }
      return null;
    } finally {
      await sub.cancel();
    }
  }

  static double _maxD(double a, double b) => a > b ? a : b;
  static double _minD(double a, double b) => a < b ? a : b;

  /// 自动探测：遍历所有 COM 口 × 常见波特率，谁先稳定出数就用谁
  ///
  /// 收银员不用懂 COM 号和波特率，插上秤点「自动检测」即可。
  /// - 空秤（0.000）也能检测成功：连续多帧一致即认，不要求必须有重量
  /// - 波特率含 1200/2400：大量计价秤默认低速档
  /// - 静默时会发 ENQ / W 指令试探「问答式」秤（只发查询，不触发打印）
  static Future<ScaleProbe?> autoDetect({
    List<int> bauds = const [9600, 2400, 4800, 1200, 19200, 38400, 57600, 115200],
    Duration window = const Duration(milliseconds: 2000),
  }) async {
    if (!WinSerial.supported) return null;
    for (final name in WinSerial.availablePorts()) {
      for (final b in bauds) {
        final s = SerialScale();
        if (!s.start(portName: name, baud: b, unitPref: 'auto')) continue;
        final r = await s.probeFor(
          window: window,
          queryCmds: const ['\x05', 'W\r\n'],
        );
        s.dispose();
        if (r != null) return r;
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
    _lastRx = null;
    _gotData = false;
    _stable = true;
  }

  void dispose() {
    stop();
    _out.close();
    _frames.close();
  }
}

/// 一帧秤读数：千克 + 稳定位（连续称重流程依赖稳定位判断「数字停止闪烁」）
class ScaleFrame {
  final double kg;
  final bool stable;
  const ScaleFrame({required this.kg, this.stable = true});
}

/// 条码秤标签条码解析（v3.3.207）
///
/// 常见 13 位格式：2 + 5位商品编码(PLU) + 5位克重 + 1位校验位
/// 例：25324100525 7 → 编码 53241，重量 00525g = 0.525kg
/// 扫码枪扫标签 → 按编码匹配商品 → 重量直接入购物车（不用再点商品称重）
class ScaleBarcode {
  final String plu; // 商品编码（5位，保留前导零）
  final double kg; // 标签重量（千克）
  const ScaleBarcode({required this.plu, required this.kg});

  static ScaleBarcode? tryParse(String code) {
    final s = code.trim();
    if (s.length != 13) return null;
    if (!RegExp(r'^2\d{12}$').hasMatch(s)) return null;
    final grams = int.tryParse(s.substring(6, 11));
    if (grams == null || grams < 0) return null;
    return ScaleBarcode(plu: s.substring(1, 6), kg: grams / 1000.0);
  }
}

/// 全局电子秤连接服务（v3.3.207）
///
/// 串口（Windows）与内置秤（安卓）是独占资源，全局只开一个连接，
/// 收银页常驻称重条与称重弹窗共用同一个流，避免两处抢串口。
/// - 键盘口秤不走此服务：它以键盘事件方式工作，仅在称重弹窗内监听
/// - 苹果 macOS：不启动（canUseScale=false），保持原样
class ScaleService {
  ScaleService._();
  static final ScaleService I = ScaleService._();

  ScalePrefs? _prefs;
  SerialScale? _serial;
  BuiltinScale? _builtin;
  StreamSubscription<ScaleFrame>? _subS;
  StreamSubscription<double>? _subB;
  bool _paused = false;

  final _out = StreamController<ScaleFrame>.broadcast();
  Stream<ScaleFrame> get stream => _out.stream;
  ScaleFrame? last;

  String get mode => _prefs?.mode ?? '';
  String get unitPref => _prefs?.unit ?? 'auto';

  bool get connected => _serial?.connected == true || _builtin?.connected == true;

  /// 是否支持远程置零/去皮（仅串口秤；连续输出协议的秤秤端会忽略指令）
  bool get canRemoteCommand => _serial != null;

  /// 按配置启动连接（重复调用安全，已在跑就不动）
  Future<void> ensure() async {
    if (!ScaleSupport.canUseScale || _paused) return;
    final p = await ScalePrefs.load();
    _prefs = p;
    if (!p.enabled) {
      stop();
      return;
    }
    if (p.mode == 'serial' && ScaleSupport.hasSerial) {
      if (_serial != null) return;
      final s = SerialScale();
      if (!s.start(portName: p.port, baud: p.baud, unitPref: p.unit)) {
        s.dispose();
        return; // 打不开就静默，收银员照常手输
      }
      _serial = s;
      _subS = s.frameStream.listen(_emit);
    } else if (p.mode == 'builtin' && ScaleSupport.hasBuiltin) {
      if (_builtin != null) return;
      final b = BuiltinScale();
      _subB = b.stream.listen((kg) => _emit(ScaleFrame(kg: kg, stable: true)));
      await b.start(unitPref: p.unit);
      _builtin = b;
    }
  }

  void _emit(ScaleFrame f) {
    last = f;
    if (!_out.isClosed) _out.add(f);
  }

  /// 配置变更后重启连接
  Future<void> restart() async {
    stop();
    await ensure();
  }

  void stop() {
    _subS?.cancel();
    _subS = null;
    _subB?.cancel();
    _subB = null;
    _serial?.dispose();
    _serial = null;
    _builtin?.dispose();
    _builtin = null;
    last = null;
  }

  /// 暂停（设置页测试/自动检测要独占串口前调用）
  Future<void> suspend() async {
    _paused = true;
    stop();
  }

  /// 恢复（测试结束后调用，按最新配置重连）
  Future<void> resume() async {
    _paused = false;
    await restart();
  }

  /// 远程置零（空秤归 0）。返回 false = 未连上或不支持，请按秤面【置零】键
  bool zero() => _serial?.sendCommand('Z\r\n') ?? false;

  /// 远程去皮（扣掉碗碟盒子皮重）。返回 false = 未连上或不支持，请按秤面【去皮】键
  bool tare() => _serial?.sendCommand('T\r\n') ?? false;
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
