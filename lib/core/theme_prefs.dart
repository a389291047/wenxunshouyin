import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主体风格（配色皮肤，v3.3.194 / v3.3.195 改为「选了才生效」）
/// 默认**不启用**任何配色方案，界面保持旧版默认外观（品牌橙 + 纯色侧边栏/主按钮）。
/// 商户在「设置 → 主体风格」里主动点选某套方案后才换色；
/// 本机持久化（SharedPreferences），ValueNotifier 全局通知，改完即时生效。
class PosSkin {
  final String id;
  final String name;
  final String desc;

  /// 渐变主色（2~4 色，从浅到深）：Logo、登录页品牌区、选中菜单项用
  final List<Color> gradient;

  /// 主题主色（价格 / 选中态 / 强调文字）
  final Color accent;

  /// 主色深色（渐变末端、按下态）
  final Color accentDeep;

  /// 侧边栏底色（深色，与渐变同色系）
  final Color sidebar;

  const PosSkin({
    required this.id,
    required this.name,
    required this.desc,
    required this.gradient,
    required this.accent,
    required this.accentDeep,
    required this.sidebar,
  });

  LinearGradient get linear => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: gradient,
      );

  /// 浅色底（选中行 / 标签底）：主色 10% 叠白
  Color get tint => Color.alphaBlend(accent.withValues(alpha: 0.10), Colors.white);

  /// 更浅的底（大块区域 / 输入底）
  Color get tintSoft => Color.alphaBlend(accent.withValues(alpha: 0.06), Colors.white);

  /// 稍深的浅底（描边 / 悬浮块）
  Color get tintStrong => Color.alphaBlend(accent.withValues(alpha: 0.18), Colors.white);
}

class ThemePrefs {
  ThemePrefs._();

  static const prefKey = 'theme_skin'; // '' = 未选择（默认外观）/ orange / open_red / ...

  /// 未选择配色方案时的外观：与 v3.3.194 之前的旧版完全一致
  /// （品牌橙、侧边栏 #1E2430、浅底 #FFF2ED、登录页橙红渐变）
  static const PosSkin legacy = PosSkin(
    id: '',
    name: '默认外观',
    desc: '未使用配色方案',
    gradient: [Color(0xFFFF9A56), Color(0xFFFF6A2C), Color(0xFFF4471B), Color(0xFFD93212)],
    accent: Color(0xFFFF5B2E),
    accentDeep: Color(0xFFF4471B),
    sidebar: Color(0xFF1E2430),
  );

  /// 6 套可选配色方案（不含默认外观）
  static const List<PosSkin> skins = [
    PosSkin(
      id: 'orange',
      name: '稳讯橙',
      desc: '经典品牌橙 · 通用',
      gradient: [Color(0xFFFF9A56), Color(0xFFFF6A2C), Color(0xFFF4471B)],
      accent: Color(0xFFFF5B2E),
      accentDeep: Color(0xFFF4471B),
      sidebar: Color(0xFF1E2430),
    ),
    PosSkin(
      id: 'open_red',
      name: '开门红',
      desc: '红金渐变 · 新店开业',
      gradient: [Color(0xFFFFB03A), Color(0xFFF03B2A), Color(0xFFB4120B)],
      accent: Color(0xFFE5382B),
      accentDeep: Color(0xFFB4120B),
      sidebar: Color(0xFF2B1512),
    ),
    PosSkin(
      id: 'fresh',
      name: '生鲜绿',
      desc: '翠绿渐变 · 生鲜果蔬',
      gradient: [Color(0xFF5BD98A), Color(0xFF16A75A), Color(0xFF0A6B33)],
      accent: Color(0xFF12A150),
      accentDeep: Color(0xFF0A6B33),
      sidebar: Color(0xFF123524),
    ),
    PosSkin(
      id: 'ocean',
      name: '海洋蓝',
      desc: '清爽蓝渐变 · 便利店/数码',
      gradient: [Color(0xFF6FC3FF), Color(0xFF2B7FFF), Color(0xFF1450C8)],
      accent: Color(0xFF2B7FFF),
      accentDeep: Color(0xFF1450C8),
      sidebar: Color(0xFF14213A),
    ),
    PosSkin(
      id: 'violet',
      name: '紫罗兰',
      desc: '梦幻紫渐变 · 奶茶/美妆',
      gradient: [Color(0xFFC4A2FF), Color(0xFF7C4DFF), Color(0xFF5526CF)],
      accent: Color(0xFF7C4DFF),
      accentDeep: Color(0xFF5526CF),
      sidebar: Color(0xFF221838),
    ),
    PosSkin(
      id: 'rose',
      name: '玫瑰金',
      desc: '轻奢玫瑰渐变 · 烘焙/花店',
      gradient: [Color(0xFFFFC1A6), Color(0xFFF0708F), Color(0xFFC33F63)],
      accent: Color(0xFFEF5B7E),
      accentDeep: Color(0xFFC33F63),
      sidebar: Color(0xFF2E1A22),
    ),
  ];

  /// 全局通知器：选中的方案 id（空字符串 = 未选择，走默认外观）
  static final ValueNotifier<String> skinId = ValueNotifier('');

  /// 是否已由商户主动选择了配色方案。
  /// false = 保持旧版默认外观（纯色侧边栏、纯色主按钮、默认品牌橙）。
  static bool get hasSkin {
    final id = skinId.value;
    if (id.isEmpty) return false;
    for (final s in skins) {
      if (s.id == id) return true;
    }
    return false;
  }

  /// 商户选中的方案；未选择时为 null
  static PosSkin? get selected => hasSkin ? byId(skinId.value) : null;

  /// 当前生效的皮肤：未选择时返回 [legacy]（默认外观）
  static PosSkin get active => selected ?? legacy;

  static PosSkin byId(String id) {
    for (final s in skins) {
      if (s.id == id) return s;
    }
    return legacy;
  }

  /// App 启动时调用一次（main.dart）
  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final v = sp.getString(prefKey) ?? '';
    // 兼容 v3.3.194 早期版本：'auto' 当时表示「跟随行业/默认」，等同于未选择配色
    if (v.isEmpty || v == 'auto' || v == 'default') {
      skinId.value = '';
    } else {
      skinId.value = byId(v).id; // 未知 id 归为未选择
    }
  }

  static Future<void> set(String id) async {
    skinId.value = byId(id).id;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefKey, skinId.value);
  }

  /// 取消配色方案，恢复旧版默认外观
  static Future<void> clear() async {
    skinId.value = '';
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefKey, '');
  }

  static Future<void> reset() => clear();
}
