import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 副屏 / 客显（v3.3.209，v3.3.210 加固）
///
/// 实现方式：主收银窗口在本机 127.0.0.1:19877~19886 暴露当前购物车快照
/// （只读、仅本机），副屏窗口是同一个程序的第二个进程（启动参数 --customer-display）。
///
/// v3.3.210 数据链路三重保险（修复「副屏一直停在欢迎光临」）：
/// 1. 端口自动探测：19877 被占（其他软件/残留进程）自动换 19878…19886，
///    显示端按同样顺序探测，主显示两边永远能对上；
/// 2. 本地快照兜底：主程序发布购物车时同步落地一份 JSON 到 SharedPreferences
///    （cd_state_json，跨进程共享），HTTP 不通（防火墙/安全软件拦回环）时
///    副屏直接读本地快照，照样显示；
/// 3. 懒启动 + 心跳：主程序只要开了副屏开关，收银页每次发布前都会确保
///    快照服务在跑；没有购物车变化时由主程序心跳发布店名，副屏不会白屏。
class CustomerDisplay {
  static const kEnabled = 'cd_enabled'; // 开机自动打开副屏
  static const kPosition = 'cd_position'; // screen2=第二块屏铺满 / window=可拖窗口
  static const kShowTotal = 'cd_show_total'; // 是否显示合计（部分商家只想给顾客看明细）
  static const kState = 'cd_state_json'; // 购物车快照本地兜底（跨进程共享）
  static const portBase = 19877;
  static const portCount = 10; // 19877 ~ 19886

  static HttpServer? _server;
  static Process? _proc;
  static bool enabled = false;
  static String position = 'screen2';
  static bool showTotal = true;
  static int _port = portBase;
  static DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);

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
  static int get latestTs => (_latest['ts'] as num?)?.toInt() ?? 0;
  static bool get windowOpen => _proc != null;
  static int get port => _port;
  static int lastOkPort = portBase; // 显示端记住的可连通端口（跨 tick 复用）

  /// 收银页发布前的总闸：开了副屏开关（或服务已在跑）才发布
  static bool get active => enabled || _server != null;

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

  /// 启动本地快照服务（幂等）。19877 被占自动顺延到 19886。
  static Future<bool> startServer() async {
    if (_server != null) return true;
    for (var p = portBase; p < portBase + portCount; p++) {
      try {
        final s =
            await HttpServer.bind(InternetAddress.loopbackIPv4, p, shared: true);
        _server = s;
        _port = p;
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
        continue; // 端口被占，试下一个
      }
    }
    return false;
  }

  /// 懒启动：收银页发布数据前调用，服务没跑且开关是开的就补启动
  static Future<void> ensureServer() async {
    if (_server == null && enabled) await startServer();
  }

  static Future<void> stopServer() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  /// 主程序每次购物车变化时调用（名称/数量/单位/单价/金额 + 合计）。
  /// 同时节流落地一份快照（≥800ms 一次），给 HTTP 不通时的副屏兜底用。
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
      // q 可能是字符串（'0.534'/'1'）也可能是数字，安全解析；
      // v3.3.209 这里用 (e['q'] as num?) 强转，收银页传字符串时每次发布都抛
      // TypeError，_latest 永远停在空快照 —— 副屏一直显示「欢迎光临」的根因
      'count': items.fold<int>(0, (s, e) => s + (num.tryParse('${e['q']}')?.round() ?? 0)),
      'total': total,
      'discount': discount,
      'payable': payable == 0 ? total : payable,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    final now = DateTime.now();
    if (now.difference(_lastPersist).inMilliseconds >= 800) {
      _lastPersist = now;
      final json = jsonEncode(_latest);
      SharedPreferences.getInstance()
          .then((sp) => sp.setString(kState, json))
          .catchError((_) => false);
    }
  }

  /// 显示端拉取：优先 HTTP（记住可用的端口，失败时按序探测）。
  /// 返回 null 表示 HTTP 全部不通（调用方可回落本地快照）。
  static Future<Map<String, dynamic>?> fetch(HttpClient client,
      {int? preferPort}) async {
    final prefer = preferPort ?? lastOkPort;
    final ports = <int>[
      prefer,
      for (var p = portBase; p < portBase + portCount; p++)
        if (p != prefer) p,
    ];
    for (final p in ports) {
      try {
        final req = await client
            .getUrl(Uri.parse('http://127.0.0.1:$p/state'))
            .timeout(const Duration(seconds: 1));
        final resp = await req.close().timeout(const Duration(seconds: 1));
        final body = await resp.transform(utf8.decoder).join();
        lastOkPort = p;
        return jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// 本地快照兜底（副屏 HTTP 不通时读主程序落地的 JSON）
  static Future<Map<String, dynamic>?> readLocal() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      final raw = sp.getString(kState);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
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
