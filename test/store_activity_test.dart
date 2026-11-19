import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/store_activity.dart';

/// 店铺活动计算引擎（v3.3.222）
/// 覆盖：满减、折扣取最优、买一送一（按件）、买一斤送半斤（称重）、
/// 满赠、赠品合并、指定商品范围、按件赠品取整。
void main() {
  Map goods(int id, String title, {int sellType = 0, String unit = ''}) => {
        'id': id,
        'title': title,
        'sell_type': sellType,
        'danwei': unit,
        'amount': 10,
      };

  ActivityCartLine line(Map g, double qty, double price) => ActivityCartLine(
        goodsId: int.parse('${g['id']}'),
        catId: 1,
        qty: qty,
        unitPrice: price,
        byWeight: '${g['sell_type']}' == '1',
        goods: g,
      );

  final apple = goods(1, '苹果', sellType: 1, unit: 'kg'); // 称重
  final cola = goods(2, '可乐');
  final chips = goods(3, '薯片');
  final giftWater = goods(9, '矿泉水');

  Map<int, Map> index(List<Map> list) => {for (final g in list) int.parse('${g['id']}'): g};

  test('满减：达到门槛减固定金额', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 6, 10)], // 60
      acts: [
        StoreActivity(id: '1', type: 'manjian', name: '满50减5', threshold: 50, minus: 5),
      ],
      goodsById: {},
    );
    expect(r.discount, 5);
    expect(r.labels.first, contains('满50减5'));
  });

  test('满减：未达门槛不优惠', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 3, 10)], // 30
      acts: [StoreActivity(id: '1', type: 'manjian', name: '满50减5', threshold: 50, minus: 5)],
      goodsById: {},
    );
    expect(r.discount, 0);
    expect(r.isEmpty, isTrue);
  });

  test('多条满减同时满足：只取最优惠的一条', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 12, 10)], // 120
      acts: [
        StoreActivity(id: '1', type: 'manjian', name: '满50减5', threshold: 50, minus: 5),
        StoreActivity(id: '2', type: 'manjian', name: '满100减15', threshold: 100, minus: 15),
      ],
      goodsById: {},
    );
    expect(r.discount, 15);
    expect(r.hitName, '满100减15');
  });

  test('折扣：9 折按小计折算', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 10, 10)], // 100
      acts: [StoreActivity(id: '1', type: 'zhekou', name: '9折', rate: 0.9)],
      goodsById: {},
    );
    expect(r.discount, 10); // 100 * 0.1
  });

  test('折扣与满减并存：取优惠更大的', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 10, 10)], // 100
      acts: [
        StoreActivity(id: '1', type: 'manjian', name: '满100减5', threshold: 100, minus: 5),
        StoreActivity(id: '2', type: 'zhekou', name: '9折', rate: 0.9), // 减 10
      ],
      goodsById: {},
    );
    expect(r.discount, 10);
    expect(r.hitName, '9折');
  });

  test('买一送一（按件）：买2件送2件同品', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 2, 3)],
      acts: [
        StoreActivity(
            id: '1', type: 'maizeng', name: '买一送一',
            buy: 1, gift: 1, giftSame: true, scope: 'goods', goodsIds: [2]),
      ],
      goodsById: index([cola]),
    );
    expect(r.gifts.length, 1);
    expect(r.gifts.first.title, '可乐');
    expect(r.gifts.first.qty, 2);
    expect(r.labels.any((e) => e.contains('赠')), isTrue);
  });

  test('买一斤送半斤（称重）：买1.2kg 送 0.5kg 同品', () {
    final r = ActivityEngine.compute(
      lines: [line(apple, 1.2, 10)],
      acts: [
        StoreActivity(
            id: '1', type: 'maizeng', name: '买一斤送半斤',
            buy: 1, gift: 0.5, giftSame: true, scope: 'goods', goodsIds: [1]),
      ],
      goodsById: index([apple]),
    );
    expect(r.gifts.length, 1);
    expect(r.gifts.first.qty, 0.5);
    expect(r.gifts.first.byWeight, isTrue);
    expect(r.gifts.first.qtyText, '0.5kg');
  });

  test('买一斤送半斤配到按件商品：赠品取整，不足 1 件不送', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 1, 3)],
      acts: [
        StoreActivity(
            id: '1', type: 'maizeng', name: '买一斤送半斤',
            buy: 1, gift: 0.5, giftSame: true, scope: 'goods', goodsIds: [2]),
      ],
      goodsById: index([cola]),
    );
    expect(r.gifts, isEmpty); // 0.5 件取整为 0，不产生赠品
  });

  test('满赠：满 50 送指定赠品', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 6, 10)], // 60
      acts: [
        StoreActivity(
            id: '1', type: 'manzeng', name: '满50送水',
            threshold: 50, gift: 1, giftGoodsId: 9),
      ],
      goodsById: index([giftWater]),
    );
    expect(r.gifts.length, 1);
    expect(r.gifts.first.title, '矿泉水');
    expect(r.gifts.first.qty, 1);
  });

  test('两个活动送同一赠品：数量合并', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 6, 10)],
      acts: [
        StoreActivity(
            id: '1', type: 'manzeng', name: '满50送水',
            threshold: 50, gift: 1, giftGoodsId: 9),
        StoreActivity(
            id: '2', type: 'manzeng', name: '满60送水',
            threshold: 60, gift: 2, giftGoodsId: 9),
      ],
      goodsById: index([giftWater]),
    );
    expect(r.gifts.length, 1);
    expect(r.gifts.first.qty, 3);
  });

  test('指定商品范围：只算范围内的金额', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 3, 10), line(chips, 2, 30)], // 可乐 30 + 薯片 60
      acts: [
        StoreActivity(id: '1', type: 'manjian', name: '薯片满50减10',
            threshold: 50, minus: 10, scope: 'goods', goodsIds: [3]),
      ],
      goodsById: {},
    );
    expect(r.discount, 10); // 薯片 60 达门槛
  });

  test('停用的活动不参与计算', () {
    final r = ActivityEngine.compute(
      lines: [line(cola, 10, 10)],
      acts: [
        StoreActivity(id: '1', type: 'manjian', name: '满50减5',
            threshold: 50, minus: 5, enabled: false),
      ],
      goodsById: {},
    );
    expect(r.isEmpty, isTrue);
  });

  test('JSON 往返：配置持久化字段不丢', () {
    final a = StoreActivity(
      id: 'x1', type: 'maizeng', name: '买一送一', scope: 'goods', goodsIds: [2, 3],
      buy: 1, gift: 1, giftSame: false, giftGoodsId: 9, enabled: true,
    );
    final b = StoreActivity.fromJson(a.toJson());
    expect(b.type, 'maizeng');
    expect(b.goodsIds, [2, 3]);
    expect(b.giftSame, isFalse);
    expect(b.giftGoodsId, 9);
    expect(b.ruleText, contains('买'));
  });
}
