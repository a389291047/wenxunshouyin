import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// 单台云打印机的绑定配置（v3.3.124）：在「设置 → 云打印机」里直接绑定
/// - role：front=前台单 / kitchen=后厨单 / 空=不参与点餐出票（只做收银小票等）
/// - mode：前台机 whole=主单一张(整桌一张) split=每菜一张；
///         后厨机 whole=整单合并一张  split=一菜一切（每个菜品一张）
/// - cats：后厨机负责的商品分类（可多台分工，同分类绑多台=双打备份）
/// - allCats：后厨机同时接收未分配分类的菜（兜底/同单双打）
/// - font：后厨票字体大小（v3.3.126）：''=标准 / 'fs'=加大(32高) / 'fs2'=特大(48高)
class PrinterCfg {
  String role;
  String mode;
  List<String> cats;
  bool allCats;
  String font;

  PrinterCfg({this.role = '', this.mode = 'whole', List<String>? cats, this.allCats = false, this.font = ''})
      : cats = cats ?? <String>[];

  Map<String, dynamic> toJson() =>
      {'role': role, 'mode': mode, 'cats': cats, 'allCats': allCats, if (font.isNotEmpty) 'font': font};

  static PrinterCfg fromJson(Map<String, dynamic> j) => PrinterCfg(
        role: '${j['role'] ?? ''}',
        mode: '${j['mode'] ?? 'whole'}',
        cats: ((j['cats'] ?? const []) as List).map((e) => '$e').toList(),
        allCats: j['allCats'] == true,
        font: '${j['font'] ?? ''}',
      );
}

/// 云打印机路由配置（v3.3.82，v3.3.124 重构为按机绑定）：
/// 每台云打印机在「设置 → 云打印机」卡片上直接绑定：前台单/后厨单、出票方式、
/// 负责的分类、是否兜底双打；配置按商户隔离（wenxun_id 前缀），存本机 SharedPreferences。
class PrinterRoute {
  static const modeWhole = 'whole'; // 整单打印
  static const modeSplit = 'split'; // 分单打印 / 一菜一切

  static String _k(String wenxunId, String key) => 'pr_route_${wenxunId}_$key';

  // ==================== 按机绑定配置（v3.3.124，当前生效） ====================
  /// {machine_code: PrinterCfg}；首次读取时把旧分散配置（前台模式/前台打印机/分类路由）
  /// 懒迁移成按机配置（不落盘，保存新配置时自然覆盖）
  static Future<Map<String, PrinterCfg>> printerCfgs(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_k(wenxunId, 'printers'));
    if (raw != null && raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw) as Map<String, dynamic>;
        return d.map((k, v) => MapEntry(k, PrinterCfg.fromJson(Map<String, dynamic>.from(v))));
      } catch (_) {
        // 数据损坏时走旧配置迁移
      }
    }
    final out = <String, PrinterCfg>{};
    try {
      final rts = await routes(wenxunId); // 旧：machine → cats
      final km = await kitchenMode(wenxunId);
      rts.forEach((code, cats) {
        out[code] = PrinterCfg(role: 'kitchen', mode: km, cats: cats, allCats: false);
      });
      final fp = await frontPrinter(wenxunId); // 旧：单选前台机
      if (fp.isNotEmpty && !out.containsKey(fp)) {
        final fm = await frontMode(wenxunId);
        out[fp] = PrinterCfg(role: 'front', mode: fm, cats: [], allCats: false);
      }
    } catch (_) {}
    return out;
  }

  /// 保存按机配置：本机必成，返回云端同步是否成功
  static Future<bool> setPrinterCfgs(String wenxunId, Map<String, PrinterCfg> cfgs) async {
    final sp = await SharedPreferences.getInstance();
    final data = <String, Map<String, dynamic>>{};
    cfgs.forEach((k, v) {
      if (v.role.isNotEmpty) data[k] = v.toJson(); // role 为空 = 不参与，不入库
    });
    await sp.setString(_k(wenxunId, 'printers'), jsonEncode(data));
    return await pushToCloud(wenxunId);
  }

  // ==================== 云端同步（v3.3.125） ====================
  // 配置存服务端 wx_printer_route（按商户一份）：换电脑 / 换收银员账号登录自动拉取，
  // 本机 SharedPreferences 仍作为缓存与离线兜底，断网时照常出票。

  /// 本机配置快照（含旧配置懒迁移结果），云端格式：{printers:{code:{...}}, rice:bool}
  static Future<Map<String, dynamic>> localCfg(String wenxunId) async {
    final cfgs = await printerCfgs(wenxunId);
    final printers = <String, dynamic>{};
    cfgs.forEach((k, v) {
      if (v.role.isNotEmpty) printers[k] = v.toJson();
    });
    return {'printers': printers, 'rice': await riceFrontOnly(wenxunId)};
  }

  /// 云端配置写回本机（整份覆盖）
  static Future<void> _applyCfg(String wenxunId, Map cfg) async {
    final sp = await SharedPreferences.getInstance();
    final out = <String, dynamic>{};
    final p = cfg['printers'];
    if (p is Map) {
      p.forEach((k, v) {
        if (v is Map) {
          final c = PrinterCfg.fromJson(Map<String, dynamic>.from(v));
          if (c.role.isNotEmpty) out['$k'] = c.toJson();
        }
      });
    }
    await sp.setString(_k(wenxunId, 'printers'), jsonEncode(out));
    if (cfg.containsKey('rice')) {
      await sp.setBool(_k(wenxunId, 'rice_front_only'), cfg['rice'] == true);
    }
    await sp.setBool(_k(wenxunId, 'cfg_dirty'), false);
  }

  /// 本机有未上传的改动（上次保存时断网）：下次同步先推本机，避免被云端旧配置覆盖
  static Future<bool> _dirty(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_k(wenxunId, 'cfg_dirty')) ?? false;
  }

  static Future<void> _setDirty(String wenxunId, bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_k(wenxunId, 'cfg_dirty'), v);
  }

  /// 登录后 / 进入设置页时同步：本机有待上传改动 → 先推本机；
  /// 否则云端有配置 → 覆盖本机；云端为空 → 上传本机（老用户首次迁移）。
  /// 返回 true=同步成功；false=网络异常，继续用本机配置。
  static Future<bool> syncFromCloud(String wenxunId) async {
    final wid = int.tryParse(wenxunId) ?? 0;
    if (wid <= 0) return false;
    try {
      // 断网时改过配置：本机为准，先补传，避免被云端旧值覆盖
      if (await _dirty(wenxunId)) {
        return await pushToCloud(wenxunId);
      }
      final remote = await Api.printerRouteCfg(wid);
      final cfg = remote['cfg'];
      if (cfg is Map && cfg.isNotEmpty) {
        await _applyCfg(wenxunId, Map<String, dynamic>.from(cfg));
        return true;
      }
      // 云端为空：把本机已有配置推上去（纯新装无配置则什么都不做，避免写空覆盖）
      final local = await localCfg(wenxunId);
      final hasData = (local['printers'] as Map).isNotEmpty || local['rice'] == true;
      if (hasData) return await pushToCloud(wenxunId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 上传本机配置到云端；失败返回 false（不抛异常，本机配置照常生效，并标记待补传）
  static Future<bool> pushToCloud(String wenxunId) async {
    final wid = int.tryParse(wenxunId) ?? 0;
    if (wid <= 0) return false;
    try {
      await Api.printerRouteCfgSave(wid, await localCfg(wenxunId));
      await _setDirty(wenxunId, false);
      return true;
    } catch (_) {
      await _setDirty(wenxunId, true);
      return false;
    }
  }

  // ==================== 米饭只打前台单（全局规则，v3.3.123） ====================
  static Future<bool> riceFrontOnly(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_k(wenxunId, 'rice_front_only')) ?? false;
  }

  /// 米饭只打前台单开关：返回云端同步是否成功
  static Future<bool> setRiceFrontOnly(String wenxunId, bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_k(wenxunId, 'rice_front_only'), v);
    return await pushToCloud(wenxunId);
  }

  /// 米饭类商品判断（名称含「米饭」即视为主食，如 米饭/米饭(小)/紫米饭）
  static bool isRiceItem(String goodsName) => goodsName.contains('米饭');

  // ==================== 旧分散配置（v3.3.82，仅供迁移读取） ====================
  static const modeWholeOld = modeWhole;
  static const modeSplitOld = modeSplit;

  static Future<String> frontMode(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_k(wenxunId, 'front_mode')) ?? modeWhole;
  }

  /// 返回指定前台打印机 machine_code；空串 = 自动（收银小票类型优先）
  static Future<String> frontPrinter(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_k(wenxunId, 'front_printer')) ?? '';
  }

  /// {machine_code: [cat_id, ...]}：每台后厨打印机负责的商品分类
  static Future<Map<String, List<String>>> routes(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_k(wenxunId, 'routes'));
    if (raw == null || raw.isEmpty) return {};
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      return d.map((k, v) => MapEntry(k, (v as List).map((e) => '$e').toList()));
    } catch (_) {
      return {};
    }
  }

  /// 旧版全局后厨模式（迁移读取用）
  static Future<String> kitchenMode(String wenxunId) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_k(wenxunId, 'kitchen_mode')) ?? modeWhole;
  }

  /// 某商品分类应发往哪些后厨打印机（按配置顺序；未配置返回空 = 走默认后厨打印机）
  static Future<List<String>> printersForCat(String wenxunId, String catId) async {
    final r = await routes(wenxunId);
    return r.entries.where((e) => e.value.contains(catId)).map((e) => e.key).toList();
  }
}
