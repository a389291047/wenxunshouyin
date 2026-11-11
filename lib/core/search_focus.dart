import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 搜索框始终聚焦（v3.3.187，参考稳讯另一套收银系统的「功能设置」）
///
/// 开启后收银页的商品搜索框始终保持聚焦：
/// - 扫码枪扫商品条码直接进搜索框，无需先点输入框
/// - 点选商品/操作后焦点自动回到搜索框
/// - 弹窗里如果还有其它输入框，不会抢焦点（不影响会员搜索、无码商品等）
class SearchFocus {
  SearchFocus._();

  static const prefKey = 'search_always_focus';

  static Future<bool> enabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(prefKey) ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(prefKey, v);
  }
}

/// 各收银页挂一个实例，把 [node] 接到搜索框 TextField 的 focusNode 上：
/// `keeper = SearchFocusKeeper(); await keeper.init();`（initState）
/// `keeper.dispose();`（dispose）
class SearchFocusKeeper {
  final FocusNode node = FocusNode(debugLabel: 'cashierSearchAlwaysFocus');
  bool _enabled = false;
  bool _disposed = false;
  bool _scheduled = false;

  Future<void> init() async {
    _enabled = await SearchFocus.enabled();
    node.addListener(_onFocusChanged);
    if (_enabled) _scheduleSteal();
  }

  void _onFocusChanged() {
    if (_disposed) return;
    if (node.hasFocus) return;
    if (_enabled) _scheduleSteal();
  }

  /// 焦点丢了 → 稍等片刻，若没有别的输入框接住焦点则抢回搜索框
  void _scheduleSteal() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    Future.delayed(const Duration(milliseconds: 500), () {
      _scheduled = false;
      if (_disposed || !_enabled) return;
      final ctx = node.context;
      if (ctx != null && !ctx.mounted) return;
      // 页面不在导航栈顶（有弹窗盖在本页上）：暂不抢，稍后重试，
      // 等弹窗关闭后焦点自动回到搜索框（v3.3.189 修复充值等弹窗光标被抢）
      final route = ctx == null ? null : ModalRoute.of(ctx);
      if (ctx != null && route != null && !route.isCurrent) {
        _scheduled = false;
        _scheduleSteal();
        return;
      }
      final primary = FocusManager.instance.primaryFocus;
      if (primary != null && primary != node) {
        final w = primary.context?.widget;
        if (w is EditableText) return; // 其它输入框持有焦点：不抢
      }
      if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) {
        node.requestFocus();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_disposed) node.requestFocus();
        });
      }
    });
  }

  void dispose() {
    _disposed = true;
    node.dispose();
  }
}
