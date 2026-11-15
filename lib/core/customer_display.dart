import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 副屏 / 客显（v3.3.209）
///
/// 实现方式：主收银窗口在本机 127.0.0.1:19877 暴露当前购物车快照（只读、仅本机），
/// 副屏窗口是同一个程序的第二个进程（启动参数 --customer-display）。
/// 用了「第二个实例」而不是多窗口插件：不需要额外的原生插件依赖，
/// 收银机断网也能用，主程序崩了副屏只是停在最后一屏，不影响收银。
class CustomerDisplay {
  static const kEnabled = 'cd_enabled'; // 开机自动打开副屏
  static const kPosition = 'cd_position'; // screen2=第二块屏铺满 / window=可拖窗口
  static const kShowTotal = 'cd_show_total'; // 是否显示合计（部分商家只想给顾客看明细）
  static const port = 19877;

  static HttpServer? _server;
  static Process? _proc;
  static bool enabled = false;
  static String position = 'screen2';
  static bool showTotal = true;

  static Map<String, dynamic> _latest = empty();

  static Map<String, dynamic> empty() => {
        'shop': '',
        'items': <Map<String, dynamic>>[],
        'count': 0,
        'total': 0,
        'discount': 0,
        'payable': 0,
        'ts': 0,
      };

  static bool get running => _server != null;
  static bool get windowOpen => _proc != null;

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    enabled = sp.getBool(kEnabled) ?? false;
    position = sp.getString(kPosition) ?? 'screen2';
    showTotal = sp.getBool(kShowTotal) ?? true;
  }

  static Future<void> savePrefs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(kEnabled, enabled);
    await sp.setString(kPosition, position);
    await sp.setBool(kShowTotal, showTotal);
  }

  /// 启动本地快照服务（幂等）。端口被占（例如旧的副屏实例）时忽略。
  static Future<bool> startServer() async {
    if (_server != null) return true;
    try {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: true);
      _server = s;
      s.listen((req) async {
        final r = req.response;
        r.headers.set('content-type', 'application/json; charset=utf-8');
        r.headers.set('cache-control', 'no-store');
        try {
          switch (req.uri.path) {
            case '/state':
              r.write(jsonEncode(_latest));
              break;
            case '/ping':
              r.write('ok');
              break;
            default:
              r.statusCode = 404;
          }
        } catch (_) {}
        await r.close();
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopServer() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  /// 主程序每次购物车变化时调用（名称/数量/单位/单价/金额 + 合计）
  static void publish({
    required List<Map<String, dynamic>> items,
    required num total,
    num discount = 0,
    num payable = 0,
    String shop = '',
  }) {
    _latest = {
      'shop': shop,
      'items': items,
      'count': items.fold<int>(0, (s, e) => s + ((e['q'] as num?)?.round() ?? 0)),
      'total': total,
      'discount': discount,
      'payable': payable == 0 ? total : payable,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// 打开副屏窗口（第二个进程）
  static Future<bool> openWindow() async {
    if (!Platform.isWindows) return false;
    if (_proc != null) return true;
    try {
      final exe = Platform.resolvedExecutable;
      // detached：副屏独立存活，主程序退出后由系统一起收掉
      _proc = await Process.start(
        exe,
        ['--customer-display', '--pos=$position'],
        mode: ProcessStartMode.detached,
      );
      // 用户自己关掉副屏窗口后，下次「立即打开副屏」还能再开
      _proc!.exitCode.then((_) => _proc = null).catchError((_) {});
      return true;
    } catch (_) {
      _proc = null;
      return false;
    }
  }

  static Future<void> closeWindow() async {
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
  }

  /// 应用设置（开关 / 位置）并持久化
  static Future<void> apply() async {
    await savePrefs();
    if (enabled) {
      await startServer();
      await closeWindow();
      await openWindow();
    } else {
      await closeWindow();
      await stopServer();
    }
  }
}
