import 'package:flutter/material.dart';
import '../core/theme.dart';

/// 通用 UI 组件
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: PosTheme.card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      padding: padding,
      child: child,
    );
  }
}

class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  final IconData icon;
  const StatTile({super.key, required this.label, required this.value, this.color, this.icon = Icons.receipt_long});
  @override
  Widget build(BuildContext context) {
    final c = color ?? PosTheme.accentLive;
    return AppCard(
      child: Row(children: [
        Container(
          width: 46, height: 46,
          decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: c, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: PosTheme.textMain)),
        ])),
      ]),
    );
  }
}

class BigButton extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  final Color? color;
  final Color textColor;
  final double height;
  final double? width;

  /// [color] 不传 = 主操作按钮：选了配色方案时用方案渐变，未选择配色时用旧版品牌橙纯色；
  /// 传颜色 = 纯色按钮（挂单/清空等次要操作）。
  const BigButton(this.text, {super.key, this.onTap, this.color, this.textColor = Colors.white, this.height = 52, this.width});

  @override
  Widget build(BuildContext context) {
    final c = color;
    final enabled = onTap != null;
    final radius = BorderRadius.circular(height / 2);
    // 只有商户主动选了配色方案才用渐变（v3.3.195：未选择保持旧版纯色外观）
    final useGradient = c == null && PosTheme.hasSkin;
    final cols = PosTheme.brandColors;
    final solid = c ?? PosTheme.accent;
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: useGradient
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: enabled
                        ? cols
                        : cols.map((e) => e.withValues(alpha: 0.4)).toList(),
                  )
                : null,
            color: useGradient ? null : (enabled ? solid : solid.withValues(alpha: 0.4)),
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Container(
              height: height,
              alignment: Alignment.center,
              child: Text(text, style: TextStyle(color: textColor, fontSize: 17, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  final String text;
  final IconData icon;
  const EmptyView(this.text, {super.key, this.icon = Icons.inbox_outlined});
  @override
  Widget build(BuildContext context) {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 56, color: PosTheme.textHint),
      const SizedBox(height: 12),
      Text(text, style: const TextStyle(fontSize: 15, color: PosTheme.textHint)),
    ]));
  }
}

class TagChip extends StatelessWidget {
  final String text;
  final Color color;
  const TagChip(this.text, {super.key, this.color = PosTheme.blue});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// 页面标题栏（内容区顶部）
class PageHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  const PageHeader(this.title, {super.key, this.actions = const []});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
      child: Row(children: [
        Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        const Spacer(),
        ...actions,
      ]),
    );
  }
}

void toast(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: const TextStyle(fontSize: 15)),
    backgroundColor: error ? PosTheme.red : const Color(0xFF2A2F3A),
    behavior: SnackBarBehavior.floating,
    duration: const Duration(milliseconds: 1800),
  ));
}

Future<bool> confirm(BuildContext context, String title, String content) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      content: Text(content, style: const TextStyle(fontSize: 15, color: PosTheme.textSub)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          style: TextButton.styleFrom(foregroundColor: PosTheme.accentLive),
          child: const Text('确定', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
  return r == true;
}

void loadingDialog(BuildContext context, String text) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: PosTheme.accentLive),
          const SizedBox(height: 16),
          Text(text, style: const TextStyle(fontSize: 14, color: PosTheme.textSub)),
        ]),
      ),
    ),
  );
}
