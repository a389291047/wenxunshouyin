import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'cloud_printer.dart';
import 'print_prefs.dart';
import 'session.dart';

/// 预约单自动打印（v3.3.139）：
/// 顾客扫码提交预约（待安排）后自动出一张「预约单」到前台/收银机，供备菜核对。
///
/// 触发点：
/// - 桌台页 20 秒轮询（_loadPreorderCount）后调 check()
/// - 预约页手动刷新/切页 _load() 后调 check()
///
/// 开关（设置 → 小票打印设置）：
/// - `booking`      预约单打印开关（关闭则连自动打印也不出）
/// - `booking_auto` 自动打印开关（关闭则只手动点「打印预约单」）
///
/// 防重：已打印的预约 id 持久化到本机（最近 300 条）；升级后首次运行只记录
/// 已存在的待安排单不补打，之后新提交的才自动出票。打印失败不标记，下次轮询重试。
class PreorderAutoPrint {
  PreorderAutoPrint._();
  static const _spKey = 'booking_printed_ids';
  static Set<String> _printed = {};
  static bool _loaded = false;
  static bool _marked = false; // 是否已完成首次基线记录
  static bool _busy = false;

  static Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final sp = await SharedPreferences.getInstance();
    _printed = (sp.getStringList(_spKey) ?? const []).toSet();
    _marked = sp.containsKey(_spKey);
  }

  static Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    var l = _printed.toList();
    if (l.length > 300) l = l.sublist(l.length - 300);
    await sp.setStringList(_spKey, l);
  }

  /// 检查新预约并自动打印（不抛异常，失败静默下次重试）
  static Future<void> check() async {
    if (_busy) return;
    _busy = true;
    try {
      await _load();
      if (!(await PrintPrefs.on('booking_auto'))) return;
      if (!(await PrintPrefs.on('booking'))) return;
      final r = await Api.preorderList(wenxunId: Session.wenxunId, status: '0');
      final raw = r['data'];
      final d = raw is Map ? raw : const <String, dynamic>{};
      final list = d['list'] is List ? d['list'] as List : const [];
      final firstRun = !_marked;
      var changed = false;
      for (final row in list) {
        final m = Map<String, dynamic>.from(row as Map);
        final id = '${m['id']}';
        if (id.isEmpty || _printed.contains(id)) continue;
        if (firstRun) {
          // 首次基线：只记录历史待安排单，不补打
          _printed.add(id);
          changed = true;
          continue;
        }
        final items = ((m['items'] ?? const []) as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        await CloudPrinter.printFront(CloudPrinter.preorderTicket(
          name: _nameOf(m),
          phone: '${m['contact_phone'] ?? ''}'.trim(),
          peopleNum: int.tryParse('${m['people_num'] ?? 0}') ?? 0,
          arriveTime: '${m['arrive_time'] ?? ''}'.trim(),
          createTime: '${m['create_time'] ?? ''}'.trim(),
          items: items,
          total: double.tryParse('${m['total'] ?? 0}') ?? 0,
          remark: '${m['remark'] ?? ''}'.trim(),
        ));
        _printed.add(id);
        changed = true;
        await _save(); // 每打一张存一次，中断也不重打
      }
      _marked = true;
      if (changed) await _save();
    } catch (_) {
      // 网络/打印异常静默，下轮重试
    } finally {
      _busy = false;
    }
  }

  /// 手动打印指定预约单（预约详情页「打印预约单」按钮）：不受开关限制，失败抛给调用方提示
  static Future<void> printNow(Map<String, dynamic> m) async {
    final items = ((m['items'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    await CloudPrinter.printFront(CloudPrinter.preorderTicket(
      name: _nameOf(m),
      phone: '${m['contact_phone'] ?? ''}'.trim(),
      peopleNum: int.tryParse('${m['people_num'] ?? 0}') ?? 0,
      arriveTime: '${m['arrive_time'] ?? ''}'.trim(),
      createTime: '${m['create_time'] ?? ''}'.trim(),
      items: items,
      total: double.tryParse('${m['total'] ?? 0}') ?? 0,
      remark: '${m['remark'] ?? ''}'.trim(),
    ));
    // 手动打过也标记，避免自动打印重复出票
    await _load();
    final id = '${m['id']}';
    if (id.isNotEmpty && !_printed.contains(id)) {
      _printed.add(id);
      _marked = true;
      await _save();
    }
  }

  /// 显示名：顾客填写称呼 → 服务端下发显示名 → 微信昵称
  static String _nameOf(Map<String, dynamic> m) {
    for (final k in ['display_name', 'contact_name', 'vip_xm', 'nickname']) {
      final v = '${m[k] ?? ''}'.trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }
}
