import 'package:flutter/foundation.dart';

/// 预约待安排数量（左侧导航「预约」红点用，v3.3.104）
///
/// 餐饮首页轮询 `preorderList` 后写入，左侧菜单监听显示角标；
/// 预约页刷新后也会同步，保证安排/拒绝后角标立即更新。
class PreorderBadge {
  PreorderBadge._();
  static final ValueNotifier<int> count = ValueNotifier<int>(0);
}
