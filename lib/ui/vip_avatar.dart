import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/theme.dart';

/// 会员头像地址：微信头像（wx_vip.avatar），空/相对路径归一化（v3.3.251 抽公用）
String vipAvatarUrl(Map? v) {
  if (v == null) return '';
  final raw = '${v['avatar'] ?? ''}'.trim();
  if (raw.isEmpty) return '';
  if (raw.startsWith('http')) return raw;
  return Api.base + (raw.startsWith('/') ? '' : '/') + raw;
}

/// 头像字符：姓名 → 手机号 → '?'，空串不能取 first（会抛 Bad state）
String vipAvatarChar(Map? v) {
  if (v == null) return '?';
  final n = '${v['name'] ?? ''}'.trim();
  if (n.isNotEmpty) return n.characters.first;
  final p = '${v['phone'] ?? ''}'.trim();
  if (p.isNotEmpty) return p.characters.first;
  return '?';
}

/// 会员头像（微信头像 → 默认头像图）：
/// 优先显示微信头像（wx_vip.avatar），加载中显示姓名首字占位，
/// 无头像 / 加载失败回退到 assets/avatar_default.png 默认头像图
/// rounded=true 时为固定圆角方形（微信样式），否则圆形
class VipAvatar extends StatefulWidget {
  final String avatarUrl;
  final double radius;
  final String fallbackText;
  final bool highlight; // 列表选中态：默认头像底色带主题色
  final bool showRing;  // 详情面板：外圈描边
  final bool rounded;   // 圆角方形（v3.3.120），false=圆形
  const VipAvatar({
    super.key,
    required this.avatarUrl,
    required this.radius,
    required this.fallbackText,
    this.highlight = false,
    this.showRing = false,
    this.rounded = false,
  });
  @override
  State<VipAvatar> createState() => _VipAvatarState();
}

class _VipAvatarState extends State<VipAvatar> {
  bool failed = false;

  /// 圆角半径：圆角方形 = 边长 × 0.28（微信头像比例）
  double get _cornerRadius => widget.radius * 2 * 0.28;

  /// 按形状裁切
  Widget _clip(Widget child) {
    if (!widget.rounded) return ClipOval(child: child);
    return ClipRRect(
      borderRadius: BorderRadius.circular(_cornerRadius),
      child: child,
    );
  }

  /// 默认头像图（裁切 + 选中态淡主题描边）
  Widget _defaultAvatar() {
    final img = _clip(
      Image.asset('assets/avatar_default.png', fit: BoxFit.cover,
          width: widget.radius * 2, height: widget.radius * 2),
    );
    if (!widget.showRing) return img;
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: widget.rounded ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: widget.rounded ? BorderRadius.circular(_cornerRadius + 2.5) : null,
        border: Border.all(color: PosTheme.accent.withOpacity(0.35), width: 1.6),
      ),
      child: img,
    );
  }

  /// 姓名首字占位（加载中 / 微信头像为空前的兜底）
  Widget _charAvatar() {
    return Container(
      width: widget.radius * 2,
      height: widget.radius * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: (widget.highlight ? PosTheme.accent : PosTheme.blue).withOpacity(0.14),
        shape: widget.rounded ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: widget.rounded ? BorderRadius.circular(_cornerRadius) : null,
      ),
      child: Text(
        widget.fallbackText,
        style: TextStyle(
          fontSize: widget.radius * 0.82,
          color: widget.highlight ? PosTheme.accent : PosTheme.blue,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.avatarUrl;
    if (url.isEmpty || failed) return _defaultAvatar();
    return _clip(
      SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : _charAvatar(),
          errorBuilder: (_, __, ___) {
            // 加载失败 → 下一帧切到默认头像图
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => failed = true);
            });
            return _defaultAvatar();
          },
        ),
      ),
    );
  }
}
