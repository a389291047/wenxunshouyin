import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'cloud_printer.dart';
import 'print_prefs.dart';
import 'session.dart';
import 'usb_printer.dart';

/// 预约单自动打印（v3.3.139；v3.3.152 修复漏打）
/// 顾客扫码提交预约（待安排）后自动出一张「预约单」到前台/收银机，供备菜核对。
///
/// 触发点（v3.3.152 改为全局轮询，任意页面都生效）：
/// - 外壳页 ShellPage 每 20 秒 check（餐饮版，常驻）
/// - 预约页手动刷新 _load() 后 check
/// - 登录后立即 check 一次（补打关机期间新提交的预约）
///
/// 开关（设置 → 小票打印设置）：
/// - `booking`      预约单打印开关（关闭则连自动打印也不出）
/// - `booking_auto` 自动打印开关（关闭则只手动点「打印预约单」）
///
/// 防重：已打印的预约 id 持久化到本机（最近 300 条，按商户分开存）。
/// v3.3.152 修复：以前「首次基线」在没有可打印单据时不落盘，导致每次重启都重新基线、
/// 把新提交的预约当历史单静默吞掉（用户表现为「不自动打印，只能手动点」）。
/// 现在首启基线一定落盘；并且首启时只把「本进程启动前」已存在的单记成历史，
/// 启动后新到的预约照常出票。打印失败不标记，下轮重试。
/// v3.3.153：① 已打印记录/基线按商户（wenxun_id）分开，同一台电脑切店不串号；
/// ② 首启放行「启动前 30 分钟内」的待安排单（收银机刚开机/升级重启时顾客已提交的单不丢）。
class PreorderAutoPrint {
  PreorderAutoPrint._();
  static const _spPrefix = 'booking_printed_ids';
  static final DateTime _launchAt = DateTime.now(); // 本进程启动时间（首启基线分界）
  static const Duration _grace = Duration(minutes: 30); // 启动补打窗口
  static String _wid = '';
  static Set<String> _printed = {};
  static bool _loaded = false;
  static bool _marked = false; // 是否已完成首次基线记录
  static bool _busy = false;

  static String _keyOf(String wid) => '${_spPrefix}_$wid';

  static Future<void> _load([String? wid]) async {
    final w = wid ?? _wid;
    if (_loaded && _wid == w && w.isNotEmpty) return;
    _wid = w;
    _loaded = true;
    _marked = false;
    _printed = {};
    if (w.isEmpty) return;
    final sp = await SharedPreferences.getInstance();
    final key = _keyOf(w);
    if (!sp.containsKey(key) && sp.containsKey(_spPrefix)) {
      // 老版本（v3.3.152 及以前）用不分商户的旧键，升级时迁移过来，
      // 避免首启把刚手动打过的单再自动打一遍
      _printed = (sp.getStringList(_spPrefix) ?? const []).toSet();
      _marked = true;
      await sp.setStringList(key, _printed.toList());
      return;
    }
    _printed = (sp.getStringList(key) ?? const []).toSet();
    _marked = sp.containsKey(key);
  }

  static Future<void> _save() async {
    if (_wid.isEmpty) return;
    final sp = await SharedPreferences.getInstance();
    var l = _printed.toList();
    if (l.length > 300) l = l.sublist(l.length - 300);
    await sp.setStringList(_keyOf(_wid), l);
  }

  /// 解析后端 create_time（"2026-11-07 09:20:00" / 斜杠分隔都兼容）
  static DateTime? _parseTime(String v) {
    final t = v.trim().replaceAll('/', '-');
    if (t.isEmpty) return null;
    return DateTime.tryParse(t);
  }

  /// 检查新预约并自动打印（不抛异常，失败静默下次重试）；返回本次打印张数
  static Future<int> check() async {
    if (_busy) return 0;
    _busy = true;
    var printed = 0;
    try {
      final wid = '${Session.wenxunId}';
      await _load(wid);
      if (!(await PrintPrefs.on('booking_auto'))) return 0;
      if (!(await PrintPrefs.on('booking'))) return 0;
      // USB「手动打印」模式下不自动出任何小票（手动点「打印预约单」仍可出，v3.3.156）
      if (await UsbPrinter.isManual()) return 0;
      final r = await Api.preorderList(wenxunId: Session.wenxunId, status: '0');
      final raw = r['data'];
      final d = raw is Map ? raw : const <String, dynamic>{};
      final list = d['list'] is List ? d['list'] as List : const [];
      final firstRun = !_marked;
      final earliest = _launchAt.subtract(_grace); // 启动补打窗口起点
      for (final row in list) {
        final m = Map<String, dynamic>.from(row as Map);
        final id = '${m['id']}';
        if (id.isEmpty || _printed.contains(id)) continue;
        if (firstRun) {
          // 升级后首启：只把「本进程启动前」已存在的待安排单记为历史不补打，
          // 启动后新到的（如刚开收银机顾客就提交了）照常出票；
          // 启动前 30 分钟内的单也照常出（收银机重启不丢单）
          final ct = _parseTime('${m['create_time'] ?? ''}');
          if (ct == null || ct.isBefore(earliest)) {
            _printed.add(id);
            await _save();
            continue;
          }
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
        printed++;
        await _save(); // 每打一张存一次，中断也不重打
      }
      _marked = true;
      // 首启必须落盘（哪怕列表为空），否则每次重启都重新基线会把新单吞掉
      if (firstRun) await _save();
    } catch (e) {
      // 网络/打印异常静默，下轮重试（记录日志便于排查）
      debugPrint('预约单自动打印失败：$e');
    } finally {
      _busy = false;
    }
    return printed;
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
    await _load('${Session.wenxunId}');
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
