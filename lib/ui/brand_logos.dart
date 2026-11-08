import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 微信支付 / 支付宝官方品牌 logo 共享组件（v3.3.166）
///
/// - WechatPayLogo：微信支付官方图标样式（圆角方块 + 双气泡），
///   默认绿方块白气泡（官方配色），可反色用于绿色头部（白方块绿气泡）。
/// - AlipayLogo：支付宝官方矢量标志（simple-icons 官方 path，含圆角方块外形）。
///
/// 使用处：扫码收款弹窗头部、餐饮/零售结账支付方式卡片。

// 支付宝官方 logo 矢量（viewBox 24x24，单色填充）
const String kAlipaySvg = '<svg fill="#FFFFFF" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">'
    '<path d="M19.695 15.07c3.426 1.158 4.203 1.22 4.203 1.22V3.846c0-2.124-1.705-3.845-3.81-3.845H3.914C1.808.001.102 1.722.102 3.846v16.31c0 2.123 1.706 3.845 3.813 3.845h16.173c2.105 0 3.81-1.722 3.81-3.845v-.157s-6.19-2.602-9.315-4.119c-2.096 2.602-4.8 4.181-7.607 4.181-4.75 0-6.361-4.19-4.112-6.949.49-.602 1.324-1.175 2.617-1.497 2.025-.502 5.247.313 8.266 1.317a16.796 16.796 0 0 0 1.341-3.302H5.781v-.952h4.799V6.975H4.77v-.953h5.81V3.591s0-.409.411-.409h2.347v2.84h5.744v.951h-5.744v1.704h4.69a19.453 19.453 0 0 1-1.986 5.06c1.424.52 2.702 1.011 3.654 1.333m-13.81-2.032c-.596.06-1.71.325-2.321.869-1.83 1.608-.735 4.55 2.968 4.55 2.151 0 4.301-1.388 5.99-3.61-2.403-1.182-4.438-2.028-6.637-1.809"/></svg>';

class WechatPayLogo extends StatelessWidget {
  final double size;

  /// 方块底色（眼睛随底色镂空，官方即此效果）
  final Color tile;

  /// 气泡颜色（官方：白；头部反色：绿）
  final Color bubble;
  const WechatPayLogo(
      {super.key,
      this.size = 26,
      this.tile = const Color(0xFF07C160),
      this.bubble = Colors.white});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
        size: Size.square(size), painter: _WechatPayPainter(tile, bubble));
  }
}

class _WechatPayPainter extends CustomPainter {
  final Color tile;
  final Color bubble;
  _WechatPayPainter(this.tile, this.bubble);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    // 方块底
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, s, s), Radius.circular(s * 0.22)),
        Paint()..color = tile);
    final bp = Paint()..color = bubble;
    // 小气泡（右下，含右下尾巴）
    final small = Path()
      ..addOval(Rect.fromCircle(
          center: Offset(s * 0.655, s * 0.635), radius: s * 0.185))
      ..addPolygon([
        Offset(s * 0.76, s * 0.75),
        Offset(s * 0.885, s * 0.86),
        Offset(s * 0.68, s * 0.80),
      ], true);
    canvas.drawPath(small, bp);
    // 大气泡（左上，含左下尾巴）
    final big = Path()
      ..addOval(Rect.fromCenter(
          center: Offset(s * 0.40, s * 0.42),
          width: s * 0.56,
          height: s * 0.48))
      ..addPolygon([
        Offset(s * 0.26, s * 0.61),
        Offset(s * 0.14, s * 0.745),
        Offset(s * 0.38, s * 0.645),
      ], true);
    canvas.drawPath(big, bp);
    // 眼睛（镂空 = 方块底色）
    final ep = Paint()..color = tile;
    canvas.drawCircle(Offset(s * 0.315, s * 0.415), s * 0.045, ep);
    canvas.drawCircle(Offset(s * 0.485, s * 0.415), s * 0.045, ep);
    canvas.drawCircle(Offset(s * 0.615, s * 0.615), s * 0.03, ep);
    canvas.drawCircle(Offset(s * 0.70, s * 0.615), s * 0.03, ep);
  }

  @override
  bool shouldRepaint(_WechatPayPainter old) =>
      old.tile != tile || old.bubble != bubble;
}

class AlipayLogo extends StatelessWidget {
  final double size;

  /// logo 颜色：官方蓝 #1677FF；在深色头部用白色
  final Color color;
  const AlipayLogo(
      {super.key, this.size = 26, this.color = const Color(0xFF1677FF)});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(kAlipaySvg,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn));
  }
}
