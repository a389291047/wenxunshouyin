import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 商品数据本地缓存（v3.3.276b 方案 C）：零售/生鲜/餐饮共用。
/// 进页面先读缓存秒显，同时带指纹后台校验——指纹相同零流量，
/// 有变化（改价/改库存/增删商品/上下架/分类变更）才拉全量并刷新缓存。
/// key 按商户 wenxun_id 区分，切商户自动各用各的。
class GoodsStore {
  static String _key(int wenxunId) => 'goods_cache_$wenxunId';

  /// 读缓存：返回 {fp, cat, goods}；无缓存或数据损坏返回 null
  static Future<Map<String, dynamic>?> load(int wenxunId) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final s = sp.getString(_key(wenxunId));
      if (s == null || s.isEmpty) return null;
      final d = jsonDecode(s);
      if (d is Map && d['goods'] is List) {
        return {
          'fp': '${d['fp'] ?? ''}',
          'cat': (d['cat'] ?? []) as List,
          'goods': d['goods'] as List,
        };
      }
    } catch (_) {
      // 缓存损坏静默清除式忽略：返回 null 走全量
    }
    return null;
  }

  /// 写缓存
  static Future<void> save(int wenxunId, String fp, List cat, List goods) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key(wenxunId), jsonEncode({'fp': fp, 'cat': cat, 'goods': goods}));
    } catch (_) {
      // 写缓存失败不阻塞主流程（下次进页面走全量）
    }
  }
}
