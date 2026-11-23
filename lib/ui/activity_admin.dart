import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/session.dart';
import '../core/store_activity.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// 店铺营销活动配置（v3.3.222）
///
/// 设置 → 营销活动。四类活动 + 四个常用模板一键添加：
/// 满50减5 / 买一送一 / 买1kg送0.5kg / 满额赠品。
/// 配置存本机（ActivityStore），收银页结算时自动计算，小票打印活动与赠品。
class ActivityAdminCard extends StatefulWidget {
  const ActivityAdminCard({super.key});

  @override
  State<ActivityAdminCard> createState() => _ActivityAdminCardState();
}

class _ActivityAdminCardState extends State<ActivityAdminCard> {
  List goods = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ActivityStore.ensure();
    try {
      final r = await Api.goodsAll(Session.wenxunId);
      goods = (r['goods'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  /// 模板：点一下就能配出最常见的活动，商户只需选商品
  Future<void> _quick(String type) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    late StoreActivity a;
    switch (type) {
      case 'manjian':
        a = StoreActivity(
            id: '$now', type: 'manjian', name: '满50减5', threshold: 50, minus: 5);
        break;
      case 'bogo':
        a = StoreActivity(
            id: '$now', type: 'maizeng', name: '买一送一',
            buy: 1, gift: 1, giftSame: true, scope: 'goods');
        break;
      case 'weightbogo':
        a = StoreActivity(
            id: '$now', type: 'maizeng', name: '买1kg送0.5kg',
            buy: 1, gift: 0.5, giftSame: true, scope: 'goods');
        break;
      default:
        a = StoreActivity(
            id: '$now', type: 'manzeng', name: '满额赠品', threshold: 50, gift: 1);
    }
    final r = await _edit(a);
    if (r != null) {
      await ActivityStore.upsert(r);
      if (mounted) toast(context, '已添加活动：${r.name}');
    }
  }

  Future<StoreActivity?> _edit(StoreActivity a) => showDialog<StoreActivity>(
        context: context,
        builder: (_) => _ActivityEditor(activity: a, goods: goods),
      );

  @override
  Widget build(BuildContext context) {
    // 父级（设置页）已是 SingleChildScrollView，这里不能再套 ListView（无界高度）
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _tipCard(),
      const SizedBox(height: 14),
      Wrap(spacing: 10, runSpacing: 10, children: [
        _quickBtn('满减', '满50减5', Icons.remove_circle_outline, 'manjian'),
        _quickBtn('买一送一', '按件买赠', Icons.card_giftcard, 'bogo'),
        _quickBtn('买1kg送0.5kg', '称重买赠', Icons.scale_outlined, 'weightbogo'),
        _quickBtn('满额赠品', '满X元送赠品', Icons.redeem_outlined, 'manzeng'),
      ]),
      const SizedBox(height: 16),
      ValueListenableBuilder<List<StoreActivity>>(
        valueListenable: ActivityStore.list,
        builder: (_, list, __) {
          if (list.isEmpty) {
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 40),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: PosTheme.line),
              ),
              child: const EmptyView('还没有活动，点上面模板快速添加', icon: Icons.campaign_outlined),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final a in list) _actRow(a),
            ],
          );
        },
      ),
    ]);
  }

  Widget _tipCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: PosTheme.tint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosTheme.accentLive.withValues(alpha: 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.tips_and_updates_outlined, size: 20, color: PosTheme.accentLive),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '活动在收银结算时自动生效，小票会打印优惠与赠品。\n'
            '金额类（满减/折扣）一次只按最优惠的一个计算；赠品可与满减同时生效。',
            style: TextStyle(fontSize: 13.5, height: 1.6, color: PosTheme.textMain),
          ),
        ),
      ]),
    );
  }

  Widget _quickBtn(String title, String sub, IconData icon, String type) {
    return InkWell(
      onTap: () => _quick(type),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 176,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: PosTheme.line),
        ),
        child: Row(children: [
          Icon(icon, size: 20, color: PosTheme.accentLive),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(sub, style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint)),
            ]),
          ),
          const Icon(Icons.add_circle_outline, size: 18, color: PosTheme.textHint),
        ]),
      ),
    );
  }

  Widget _actRow(StoreActivity a) {
    final off = !a.enabled;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosTheme.line),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: PosTheme.accentLive.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(a.typeName,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PosTheme.accentLive)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: off ? PosTheme.textHint : PosTheme.textMain)),
            const SizedBox(height: 3),
            Text('${a.ruleText} · ${a.scopeText}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
          ]),
        ),
        Switch(
          value: a.enabled,
          activeTrackColor: PosTheme.accentLive,
          onChanged: (v) => ActivityStore.toggle(a.id, v),
        ),
        IconButton(
          tooltip: '编辑',
          icon: const Icon(Icons.edit_outlined, size: 20, color: PosTheme.textSub),
          onPressed: () async {
            final r = await _edit(a);
            if (r != null) await ActivityStore.upsert(r);
          },
        ),
        IconButton(
          tooltip: '删除',
          icon: const Icon(Icons.delete_outline, size: 20, color: PosTheme.textSub),
          onPressed: () async {
            final ok = await confirm(context, '删除活动', '确定删除「${a.name}」？');
            if (ok == true) await ActivityStore.remove(a.id);
          },
        ),
      ]),
    );
  }
}

// ==================== 活动编辑弹窗 ====================

class _ActivityEditor extends StatefulWidget {
  const _ActivityEditor({required this.activity, required this.goods});
  final StoreActivity activity;
  final List goods;

  @override
  State<_ActivityEditor> createState() => _ActivityEditorState();
}

class _ActivityEditorState extends State<_ActivityEditor> {
  late String type = widget.activity.type;
  late String scope = widget.activity.scope;
  late List<int> goodsIds = List<int>.from(widget.activity.goodsIds);
  late double threshold = widget.activity.threshold;
  late double minus = widget.activity.minus;
  late double rate = widget.activity.rate;
  late double buy = widget.activity.buy;
  late double gift = widget.activity.gift;
  late bool giftSame = widget.activity.giftSame;
  late int giftGoodsId = widget.activity.giftGoodsId;
  late final TextEditingController nameCtrl =
      TextEditingController(text: widget.activity.name);

  Map<int, Map> get _goodsById => {
        for (final g in widget.goods) (int.tryParse('${g['id']}') ?? 0): g as Map,
      };

  @override
  void dispose() {
    nameCtrl.dispose();
    super.dispose();
  }

  /// 名称留空时按规则自动生成
  String _autoName() {
    switch (type) {
      case 'manjian':
        return '满${_n(threshold)}减${_n(minus)}';
      case 'zhekou':
        return '${_n(rate * 10)}折优惠';
      case 'maizeng':
        return '买${_n(buy)}送${_n(gift)}';
      case 'manzeng':
        return '满${_n(threshold)}赠品';
      default:
        return '优惠活动';
    }
  }

  bool _valid() {
    if (nameCtrl.text.trim().isEmpty) return false;
    if (scope == 'goods' && goodsIds.isEmpty && type != 'manjian') return false;
    switch (type) {
      case 'manjian':
        return threshold > 0 && minus > 0;
      case 'zhekou':
        return rate > 0 && rate < 1;
      case 'maizeng':
        return buy > 0 && gift > 0 && (giftSame || giftGoodsId > 0);
      case 'manzeng':
        return threshold > 0 && giftGoodsId > 0;
      default:
        return false;
    }
  }

  void _save() {
    if (!_valid()) {
      toast(context, '请把活动条件填完整', error: true);
      return;
    }
    Navigator.of(context).pop(widget.activity.copyWith(
      type: type,
      name: nameCtrl.text.trim().isEmpty ? _autoName() : nameCtrl.text.trim(),
      scope: scope,
      goodsIds: goodsIds,
      threshold: threshold,
      minus: minus,
      rate: rate,
      buy: buy,
      gift: gift,
      giftSame: giftSame,
      giftGoodsId: giftGoodsId,
      enabled: true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final w = media.width < 760 ? media.width - 40 : 660.0;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: w,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 14, 10),
            child: Row(children: [
              const Text('活动设置', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 22, color: PosTheme.textSub),
              ),
            ]),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _label('活动类型'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final t in StoreActivity.typeNames.entries)
                    _chip(t.value, type == t.key, () => setState(() => type = t.key)),
                ]),
                const SizedBox(height: 14),
                _label('活动名称'),
                PosField(
                  controller: nameCtrl,
                  compact: true,
                  hint: '不填则自动生成，如 ${_autoName()}',
                ),
                const SizedBox(height: 14),
                _label('适用范围'),
                Row(children: [
                  _chip('全部商品', scope == 'all', () => setState(() => scope = 'all')),
                  const SizedBox(width: 8),
                  _chip('指定商品', scope == 'goods', () async {
                    final r = await _pickGoods(multi: true, selected: goodsIds);
                    if (r == null) return;
                    setState(() {
                      scope = 'goods';
                      goodsIds = r;
                    });
                  }),
                  if (scope == 'goods') ...[
                    const SizedBox(width: 10),
                    Text('已选 ${goodsIds.length} 个',
                        style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
                  ],
                ]),
                const SizedBox(height: 14),
                ..._params(),
                const SizedBox(height: 6),
                if (type == 'maizeng' && !giftSame) ...[
                  const SizedBox(height: 8),
                  _giftPickRow(),
                ],
                if (type == 'manzeng') ...[
                  const SizedBox(height: 8),
                  _giftPickRow(),
                ],
                const SizedBox(height: 10),
                Text(
                  _hintText(),
                  style: const TextStyle(fontSize: 12.5, height: 1.5, color: PosTheme.textHint),
                ),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
            child: Row(children: [
              Expanded(
                child: BigButton('取消',
                    onTap: () => Navigator.of(context).pop(),
                    color: const Color(0xFFF2F3F7),
                    textColor: PosTheme.textSub,
                    height: 50),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: BigButton('保存活动', onTap: _save, height: 50),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  List<Widget> _params() {
    switch (type) {
      case 'manjian':
        return [
          Row(children: [
            _numTile('满（元）', threshold, '满多少', (v) => setState(() => threshold = v)),
            const SizedBox(width: 12),
            _numTile('减（元）', minus, '减多少', (v) => setState(() => minus = v)),
          ]),
        ];
      case 'zhekou':
        return [
          Row(children: [
            _numTile('折扣', rate * 10, '如 9 表示 9 折', (v) {
              final r = (v / 10).clamp(0.01, 0.99);
              setState(() => rate = r.toDouble());
            }, suffix: '折'),
          ]),
        ];
      case 'maizeng':
        return [
          Row(children: [
            _numTile('买（件/kg）', buy, '买多少', (v) => setState(() => buy = v)),
            const SizedBox(width: 12),
            _numTile('送（件/kg）', gift, '送多少', (v) => setState(() => gift = v)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _chip('送同品', giftSame, () => setState(() => giftSame = true)),
            const SizedBox(width: 8),
            _chip('送指定赠品', !giftSame, () => setState(() => giftSame = false)),
          ]),
        ];
      case 'manzeng':
        return [
          Row(children: [
            _numTile('满（元）', threshold, '满多少', (v) => setState(() => threshold = v)),
            const SizedBox(width: 12),
            _numTile('赠（件）', gift, '送几件', (v) => setState(() => gift = v)),
          ]),
        ];
      default:
        return [];
    }
  }

  Widget _giftPickRow() {
    final g = _goodsById[giftGoodsId];
    return InkWell(
      onTap: () async {
        final r = await _pickGoods(multi: false, selected: giftGoodsId > 0 ? [giftGoodsId] : []);
        if (r != null && r.isNotEmpty) setState(() => giftGoodsId = r.first);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: PosTheme.line),
        ),
        child: Row(children: [
          Icon(Icons.redeem_outlined, size: 19, color: PosTheme.accentLive),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              g == null ? '选择赠品商品' : '赠品：${g['title']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: g == null ? PosTheme.textHint : PosTheme.textMain),
            ),
          ),
          const Icon(Icons.chevron_right, size: 20, color: PosTheme.textHint),
        ]),
      ),
    );
  }

  String _hintText() {
    switch (type) {
      case 'manjian':
        return '指定商品的合计金额达到门槛即减钱，减后不低于 0 元。多条满减同时满足时，只按最优惠的一条计算。';
      case 'zhekou':
        return '按指定商品小计打折，例如 9 折。与满减同时存在时取更优惠的一个。';
      case 'maizeng':
        return '按件商品：买 1 送 1 就是买一送一；称重商品：买 1kg 送 0.5kg 就是买1kg送0.5kg。'
            '赠品按每满 N 份计算，赠品以 0 元行打印在小票上。';
      case 'manzeng':
        return '指定商品（或全场）满额后赠送指定商品，赠品以 0 元行打印在小票上。';
      default:
        return '';
    }
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: PosTheme.textSub)),
      );

  Widget _chip(String text, bool on, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: on ? PosTheme.accentLive.withValues(alpha: 0.10) : Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: on ? PosTheme.accentLive : PosTheme.line),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                color: on ? PosTheme.accentLive : PosTheme.textMain)),
      ),
    );
  }

  Widget _numTile(String label, double value, String hint, ValueChanged<double> onDone, {String suffix = ''}) {
    return Expanded(
      child: InkWell(
        onTap: () async {
          final v = await showNumPadDialog(context, title: label, initial: value, hint: hint);
          if (v != null) onDone(v);
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: PosTheme.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: Text('${_n(value)}$suffix',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: value > 0 ? PosTheme.textMain : PosTheme.textHint)),
              ),
              const Icon(Icons.dialpad, size: 17, color: PosTheme.textHint),
            ]),
          ]),
        ),
      ),
    );
  }

  /// 选品（multi=true 多选；否则单选返回 1 个）
  Future<List<int>?> _pickGoods({required bool multi, required List<int> selected}) {
    return showDialog<List<int>>(
      context: context,
      builder: (_) => _GoodsPickDialog(goods: widget.goods, multi: multi, selected: selected),
    );
  }

  static String _n(double v) {
    final s = v.toStringAsFixed(3);
    return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
}

// ==================== 选品弹窗 ====================

class _GoodsPickDialog extends StatefulWidget {
  const _GoodsPickDialog({required this.goods, required this.multi, required this.selected});
  final List goods;
  final bool multi;
  final List<int> selected;

  @override
  State<_GoodsPickDialog> createState() => _GoodsPickDialogState();
}

class _GoodsPickDialogState extends State<_GoodsPickDialog> {
  late final Set<int> sel = widget.selected.toSet();
  final kw = TextEditingController();

  @override
  void dispose() {
    kw.dispose();
    super.dispose();
  }

  List get _list {
    final k = kw.text.trim().toLowerCase();
    if (k.isEmpty) return widget.goods;
    return widget.goods.where((g) {
      final title = '${g['title'] ?? ''}'.toLowerCase();
      final code = '${g['code'] ?? g['bianma'] ?? ''}';
      final jp = '${g['jianpin'] ?? ''}'.toLowerCase();
      return title.contains(k) || code.contains(k) || jp.contains(k);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: media.width < 720 ? media.width - 60 : 620,
        height: media.height < 700 ? media.height - 80 : 640,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(children: [
              Text(widget.multi ? '选择商品（可多选）' : '选择赠品',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const Spacer(),
              Text('已选 ${sel.length}', style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 22, color: PosTheme.textSub),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: PosField(
              controller: kw,
              onChanged: (_) => setState(() {}),
              compact: true,
              hint: '搜索商品名称 / 简拼 / 条码',
              icon: Icons.search,
              iconColor: PosTheme.textSub,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _list.isEmpty
                ? const EmptyView('没有匹配的商品', icon: Icons.search_off)
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _list.length,
                    itemBuilder: (_, i) {
                      final g = _list[i];
                      final id = int.tryParse('${g['id']}') ?? 0;
                      final on = sel.contains(id);
                      final weighted = '${g['sell_type'] ?? 0}' == '1';
                      return Material(
                        color: on ? PosTheme.tint : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              if (widget.multi) {
                                on ? sel.remove(id) : sel.add(id);
                              } else {
                                sel
                                  ..clear()
                                  ..add(id);
                              }
                            });
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                            child: Row(children: [
                              Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
                                  size: 21, color: on ? PosTheme.accentLive : PosTheme.textHint),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text('${g['title']}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 2),
                                  Text(
                                    '¥${Fmt.money(double.tryParse('${g['amount'] ?? 0}') ?? 0)}'
                                    '${weighted ? '/${('${g['danwei'] ?? ''}'.trim().isEmpty ? 'kg' : g['danwei'])}' : ''}'
                                    '${weighted ? ' · 称重' : ''}',
                                    style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub),
                                  ),
                                ]),
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            child: Row(children: [
              if (widget.multi)
                Expanded(
                  child: BigButton('清空已选',
                      onTap: () => setState(sel.clear),
                      color: const Color(0xFFF2F3F7),
                      textColor: PosTheme.textSub,
                      height: 48),
                ),
              if (widget.multi) const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: BigButton('确定', onTap: () => Navigator.of(context).pop(sel.toList()), height: 48),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ==================== 数字输入弹窗（触屏） ====================

/// 金额/件数输入：自带 12 宫格数字键盘，不依赖系统键盘（触摸屏收银机用）
Future<double?> showNumPadDialog(
  BuildContext context, {
  required String title,
  double initial = 0,
  String hint = '',
}) {
  return showDialog<double>(
    context: context,
    builder: (_) => _NumPadDialog(title: title, initial: initial, hint: hint),
  );
}

class _NumPadDialog extends StatefulWidget {
  const _NumPadDialog({required this.title, required this.initial, required this.hint});
  final String title;
  final double initial;
  final String hint;

  @override
  State<_NumPadDialog> createState() => _NumPadDialogState();
}

class _NumPadDialogState extends State<_NumPadDialog> {
  late String text =
      widget.initial > 0 ? widget.initial.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '') : '';

  void _tap(String k) {
    setState(() {
      if (k == '⌫') {
        if (text.isNotEmpty) text = text.substring(0, text.length - 1);
      } else if (k == '.') {
        if (!text.contains('.')) text = text.isEmpty ? '0.' : '$text.';
      } else {
        if (text == '0') text = k;
        else if (text.length < 10) text += k;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['.', '0', '⌫'],
    ];
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 340,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
            child: Row(children: [
              Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 20, color: PosTheme.textSub),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: PosTheme.line),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(text.isEmpty ? '0' : text,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => setState(() => text = ''),
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.backspace_outlined, size: 19, color: PosTheme.textSub),
                  ),
                ),
              ]),
            ),
          ),
          if (widget.hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 20, right: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.hint, style: const TextStyle(fontSize: 12, color: PosTheme.textHint)),
              ),
            ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(children: [
              for (final r in rows) ...[
                Row(children: [
                  for (final k in r) ...[
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: Material(
                          color: k == '⌫' ? const Color(0xFFEDEFF3) : Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: const BorderSide(color: PosTheme.line),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _tap(k),
                            child: Center(
                              child: Text(k,
                                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (k != r.last) const SizedBox(width: 8),
                  ],
                ]),
                const SizedBox(height: 8),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 16),
            child: BigButton('确定',
                onTap: () => Navigator.of(context).pop(double.tryParse(text) ?? 0), height: 52),
          ),
        ]),
      ),
    );
  }
}
