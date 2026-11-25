import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxun/core/theme.dart';

/// 店铺营销活动（v3.3.222）
///
/// 四类常用活动，商户在「设置 → 营销活动」自定义：
/// - manjian 满减：指定商品满 X 元减 Y 元
/// - zhekou  折扣：指定商品打 X 折
/// - maizeng 买赠：买 N（件/kg）送 M（件/kg），送同品或指定赠品
///            按件商品即「买一送一」，称重商品即「买1kg送0.5kg」
/// - manzeng 满赠：指定商品满 X 元送指定赠品
///
/// 结算规则：金额类（满减/折扣）一次只取优惠最大的一个；赠品类可同时生效，
/// 同一赠品自动合并数量。赠品不进购物车，单独在结算区展示、小票打 0 元赠品行。
class StoreActivity {
  StoreActivity({
    required this.id,
    required this.type,
    required this.name,
    this.enabled = true,
    this.scope = 'all', // all 全场 | goods 指定商品
    List<int>? goodsIds,
    this.threshold = 0, // 满减门槛（元）/ 满赠门槛（元）
    this.minus = 0, // 满减金额（元）
    this.rate = 0.9, // 折扣率（0.9 = 9 折）
    this.buy = 1, // 买 N
    this.gift = 1, // 送 M
    this.giftSame = true, // 买赠是否送同品
    this.giftGoodsId = 0, // 指定赠品商品 id
    this.note = '',
  }) : goodsIds = goodsIds ?? [];

  final String id;
  final String type; // manjian / zhekou / maizeng / manzeng
  final String name;
  final bool enabled;
  final String scope;
  final List<int> goodsIds;
  final double threshold;
  final double minus;
  final double rate;
  final double buy;
  final double gift;
  final bool giftSame;
  final int giftGoodsId;
  final String note;

  static const typeNames = {
    'manjian': '满减',
    'zhekou': '折扣',
    'maizeng': '买赠',
    'manzeng': '满赠',
  };

  String get typeName => typeNames[type] ?? type;

  /// 一句话规则说明（列表页展示）
  String get ruleText {
    switch (type) {
      case 'manjian':
        return '满 ¥${_n(threshold)} 减 ¥${_n(minus)}';
      case 'zhekou':
        return '${_n(rate * 10)} 折';
      case 'maizeng':
        return '买 ${_n(buy)} 送 ${_n(gift)}${giftSame ? '（同品）' : '（指定赠品）'}';
      case 'manzeng':
        return '满 ¥${_n(threshold)} 赠 ${_n(gift)} 件';
      default:
        return '';
    }
  }

  String get scopeText => scope == 'all' ? '全部商品' : '指定 ${goodsIds.length} 个商品';

  StoreActivity copyWith({
    String? type,
    String? name,
    bool? enabled,
    String? scope,
    List<int>? goodsIds,
    double? threshold,
    double? minus,
    double? rate,
    double? buy,
    double? gift,
    bool? giftSame,
    int? giftGoodsId,
    String? note,
  }) {
    return StoreActivity(
      id: id,
      type: type ?? this.type,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      scope: scope ?? this.scope,
      goodsIds: goodsIds ?? List<int>.from(this.goodsIds),
      threshold: threshold ?? this.threshold,
      minus: minus ?? this.minus,
      rate: rate ?? this.rate,
      buy: buy ?? this.buy,
      gift: gift ?? this.gift,
      giftSame: giftSame ?? this.giftSame,
      giftGoodsId: giftGoodsId ?? this.giftGoodsId,
      note: note ?? this.note,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        'enabled': enabled,
        'scope': scope,
        'goodsIds': goodsIds,
        'threshold': threshold,
        'minus': minus,
        'rate': rate,
        'buy': buy,
        'gift': gift,
        'giftSame': giftSame,
        'giftGoodsId': giftGoodsId,
        'note': note,
      };

  static StoreActivity fromJson(Map j) => StoreActivity(
        id: '${j['id'] ?? ''}',
        type: '${j['type'] ?? 'manjian'}',
        name: '${j['name'] ?? ''}',
        enabled: j['enabled'] != false,
        scope: '${j['scope'] ?? 'all'}',
        goodsIds: (j['goodsIds'] is List)
            ? (j['goodsIds'] as List).map((e) => int.tryParse('$e') ?? 0).where((e) => e > 0).toList()
            : [],
        threshold: _d(j['threshold']),
        minus: _d(j['minus']),
        rate: j['rate'] == null ? 0.9 : _d(j['rate']),
        buy: j['buy'] == null ? 1 : _d(j['buy']),
        gift: j['gift'] == null ? 1 : _d(j['gift']),
        giftSame: j['giftSame'] != false,
        giftGoodsId: int.tryParse('${j['giftGoodsId'] ?? 0}') ?? 0,
        note: '${j['note'] ?? ''}',
      );

  static double _d(dynamic v) => double.tryParse('$v') ?? 0;

  static String _n(double v) {
    final s = v.toStringAsFixed(2);
    return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
}

/// 参与计算的购物车行（与页面私有模型解耦）
class ActivityCartLine {
  const ActivityCartLine({
    required this.goodsId,
    required this.catId,
    required this.qty,
    required this.unitPrice,
    required this.byWeight,
    required this.goods,
  });

  final int goodsId;
  final int catId;
  final double qty; // 件数或重量
  final double unitPrice;
  final bool byWeight;
  final Map goods;

  double get subtotal => qty * unitPrice;
}

/// 赠品（0 元行）
class ActivityGift {
  ActivityGift({
    required this.goods,
    required this.qty,
    required this.byWeight,
    required this.activityName,
  });

  final Map goods;
  final double qty;
  final bool byWeight;
  final String activityName;

  String get title => '${goods['title'] ?? ''}';
  int get goodsId => int.tryParse('${goods['id'] ?? 0}') ?? 0;

  String get unit {
    return Fmt.unit(goods['danwei']); // 空/'null'/'undefined' 一律兜底 kg
  }

  String get qtyText {
    if (!byWeight) return '×${qty.round()}';
    var s = qty.toStringAsFixed(3);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return '$s$unit';
  }
}

/// 一次结算的活动计算结果
class ActivityResult {
  const ActivityResult({
    this.discount = 0,
    this.gifts = const [],
    this.labels = const [],
    this.hitName = '',
  });

  final double discount; // 金额类优惠（满减/折扣）
  final List<ActivityGift> gifts; // 赠品（已合并同品）
  final List<String> labels; // 展示文案，如「满50减5 -¥5.00」
  final String hitName; // 命中的金额类活动名

  bool get isEmpty => discount <= 0 && gifts.isEmpty;

  static const empty = ActivityResult();
}

/// 活动计算引擎
class ActivityEngine {
  /// [lines] 购物车行；[acts] 全部活动；[goodsById] 商品资料索引（找指定赠品用）
  static ActivityResult compute({
    required List<ActivityCartLine> lines,
    required List<StoreActivity> acts,
    required Map<int, Map> goodsById,
  }) {
    if (lines.isEmpty || acts.isEmpty) return ActivityResult.empty;

    double bestDiscount = 0;
    String bestLabel = '';
    String bestName = '';
    final gifts = <ActivityGift>[];

    for (final a in acts) {
      if (!a.enabled) continue;
      final inScope = lines.where((l) => _match(a, l)).toList();
      if (inScope.isEmpty) continue;

      switch (a.type) {
        case 'manjian':
          final sub = inScope.fold<double>(0, (s, l) => s + l.subtotal);
          if (a.threshold > 0 && sub >= a.threshold && a.minus > 0) {
            final d = math.min(a.minus, sub);
            if (d > bestDiscount) {
              bestDiscount = d;
              bestName = a.name;
              bestLabel = '${a.name} -¥${_money(d)}';
            }
          }
          break;

        case 'zhekou':
          final sub = inScope.fold<double>(0, (s, l) => s + l.subtotal);
          if (sub > 0 && a.rate > 0 && a.rate < 1) {
            final d = sub * (1 - a.rate);
            if (d > bestDiscount) {
              bestDiscount = d;
              bestName = a.name;
              bestLabel = '${a.name}（${StoreActivity._n(a.rate * 10)}折） -¥${_money(d)}';
            }
          }
          break;

        case 'maizeng':
          // 买 N 送 M：逐行判断（同品赠送时按行商品），跨行不累计，符合门店习惯。
          // 称重商品按重量算（买1kg送0.5kg），按件商品自动取整（送礼必须整件）。
          for (final l in inScope) {
            if (a.buy <= 0 || a.gift <= 0) continue;
            final times = (l.qty / a.buy).floor();
            if (times <= 0) continue;
            var gq = a.gift * times;
            if (!l.byWeight) gq = gq.floorToDouble();
            if (gq <= 0) continue;
            if (a.giftSame) {
              gifts.add(ActivityGift(
                  goods: l.goods, qty: gq, byWeight: l.byWeight, activityName: a.name));
            } else {
              final g = goodsById[a.giftGoodsId];
              if (g != null) {
                final gw = '${g['sell_type'] ?? 0}' == '1';
                gifts.add(ActivityGift(
                    goods: g, qty: gw ? gq : gq.floorToDouble(), byWeight: gw, activityName: a.name));
              }
            }
          }
          break;

        case 'manzeng':
          final sub = inScope.fold<double>(0, (s, l) => s + l.subtotal);
          if (a.threshold > 0 && sub >= a.threshold) {
            final g = goodsById[a.giftGoodsId];
            if (g != null) {
              gifts.add(ActivityGift(
                goods: g,
                qty: a.gift <= 0 ? 1 : a.gift,
                byWeight: '${g['sell_type'] ?? 0}' == '1',
                activityName: a.name,
              ));
            }
          }
          break;
      }
    }

    // 同品赠品合并（同一商品被多个活动送，或同一活动多行命中）
    final merged = <String, ActivityGift>{};
    for (final g in gifts) {
      final key = '${g.goodsId}_${g.byWeight}';
      final old = merged[key];
      if (old == null) {
        merged[key] = g;
      } else {
        merged[key] = ActivityGift(
          goods: old.goods,
          qty: old.qty + g.qty,
          byWeight: old.byWeight,
          activityName: old.activityName,
        );
      }
    }

    final labels = <String>[
      if (bestDiscount > 0) bestLabel,
      for (final g in merged.values) '赠 ${g.title} ${g.qtyText}',
    ];

    return ActivityResult(
      discount: _round2(bestDiscount),
      gifts: merged.values.toList(),
      labels: labels,
      hitName: bestName,
    );
  }

  static bool _match(StoreActivity a, ActivityCartLine l) {
    if (a.scope == 'all') return true;
    return a.goodsIds.contains(l.goodsId);
  }

  static double _round2(double v) => (v * 100).round() / 100;

  static String _money(double v) => v.toStringAsFixed(2);
}

/// 活动持久化（本机 SharedPreferences，JSON 整份存）
///
/// 收银页与设置页共用同一个 [list]（ValueNotifier），改完立刻生效。
class ActivityStore {
  static const _key = 'retail_activities';

  static final ValueNotifier<List<StoreActivity>> list = ValueNotifier([]);
  static bool _loaded = false;

  static Future<List<StoreActivity>> ensure() async {
    if (_loaded) return list.value;
    await reload();
    return list.value;
  }

  static Future<void> reload() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      final out = <StoreActivity>[];
      if (raw != null && raw.isNotEmpty) {
        final data = jsonDecode(raw);
        if (data is List) {
          for (final j in data) {
            if (j is Map) out.add(StoreActivity.fromJson(j));
          }
        }
      }
      list.value = out;
    } catch (_) {
      list.value = [];
    }
    _loaded = true;
  }

  static Future<void> save(List<StoreActivity> acts) async {
    list.value = List<StoreActivity>.from(acts);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(acts.map((e) => e.toJson()).toList()));
  }

  /// 新增/更新一条，返回最新列表
  static Future<void> upsert(StoreActivity a) async {
    final next = List<StoreActivity>.from(list.value);
    final i = next.indexWhere((e) => e.id == a.id);
    if (i >= 0) {
      next[i] = a;
    } else {
      next.add(a);
    }
    await save(next);
  }

  static Future<void> remove(String id) async {
    final next = list.value.where((e) => e.id != id).toList();
    await save(next);
  }

  static Future<void> toggle(String id, bool on) async {
    final next = list.value.map((e) => e.id == id ? e.copyWith(enabled: on) : e).toList();
    await save(next);
  }

  /// 收银页直接读当前启用活动
  static List<StoreActivity> get active => list.value.where((e) => e.enabled).toList();
}
