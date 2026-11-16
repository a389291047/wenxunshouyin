import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 客显（副屏）动态海洋背景 v3.3.212
///
/// 与会员激活页同一套视觉：晴空 + 低垂太阳 + 海平线光带 + 多层起伏海浪，
/// 纯代码绘制（无图片资源），低端安卓机也不掉帧：
/// 只有一个 AnimationController 驱动一个 CustomPainter，不重建任何 widget。
class OceanBackground extends StatefulWidget {
  const OceanBackground({super.key, this.animate = true});

  final bool animate;

  @override
  State<OceanBackground> createState() => _OceanBackgroundState();
}

class _OceanBackgroundState extends State<OceanBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _OceanPainter(_c),
        size: Size.infinite,
        isComplex: true,
        willChange: widget.animate,
      ),
    );
  }
}

class _OceanPainter extends CustomPainter {
  _OceanPainter(this.a) : super(repaint: a);

  final Animation<double> a;

  static const _sky = [
    Color(0xFF0A2C4A),
    Color(0xFF14547F),
    Color(0xFF3682AC),
    Color(0xFF7FC0D2),
    Color(0xFFCFEFF0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final t = a.value;
    final twoPi = math.pi * 2;
    final horizon = h * 0.20;

    // ---- 天空 ----
    final skyPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, horizon + 1),
        _sky,
        const [0.0, 0.30, 0.62, 0.86, 1.0],
      );
    canvas.drawRect(Rect.fromLTWH(0, 0, w, horizon + 1), skyPaint);

    // ---- 太阳（缓慢呼吸） ----
    final sunCenter = Offset(w * 0.5, horizon - h * 0.065);
    final pulse = 0.94 + 0.06 * math.sin(t * twoPi);
    final sunR = math.max(w, h) * 0.24 * pulse;
    canvas.drawCircle(
      sunCenter,
      sunR,
      Paint()
        ..shader = ui.Gradient.radial(sunCenter, sunR, const [
          Color(0xFFFFFDF3),
          Color(0xE6FFEFC8),
          Color(0x55FFD79E),
          Color(0x00FFCE92),
        ], const [0.0, 0.18, 0.46, 1.0]),
    );

    // ---- 云（横向缓慢漂移） ----
    _cloud(canvas,
        center: Offset(w * (0.20 + 0.05 * math.sin(t * twoPi)), horizon * 0.38),
        size: Size(w * 0.44, h * 0.048),
        alpha: 0.32);
    _cloud(canvas,
        center: Offset(w * (0.70 - 0.04 * math.sin(t * twoPi + 1.2)), horizon * 0.66),
        size: Size(w * 0.34, h * 0.036),
        alpha: 0.22);

    // ---- 海面 ----
    final seaPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, horizon),
        Offset(0, h),
        const [
          Color(0xFFB3E4E7),
          Color(0xFF5DB9CE),
          Color(0xFF2A93B2),
          Color(0xFF146E90),
          Color(0xFF0A4A69),
          Color(0xFF052F44),
        ],
        const [0.0, 0.05, 0.20, 0.45, 0.72, 1.0],
      );
    canvas.drawRect(Rect.fromLTWH(0, horizon, w, h - horizon), seaPaint);

    // ---- 海平线光带 ----
    final horizonGlow = Rect.fromLTWH(0, horizon - h * 0.022, w, h * 0.05);
    canvas.drawRect(
      horizonGlow,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, horizonGlow.top),
          Offset(0, horizonGlow.bottom),
          const [Color(0x00FFFDF4), Color(0xFFFFFBE8), Color(0x00FFF3D2)],
          const [0.0, 0.5, 1.0],
        ),
    );

    // ---- 阳光在海面的倒影 ----
    final glareW = w * 0.30;
    final glareTop = horizon;
    final glareH = (h - horizon) * 0.62;
    final glareA = 0.55 + 0.20 * math.sin(t * twoPi * 1.5);
    canvas.drawRect(
      Rect.fromLTWH(w * 0.5 - glareW / 2, glareTop, glareW, glareH),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, glareTop),
          Offset(0, glareTop + glareH),
          [
            const Color(0xFFFFF8E0).withValues(alpha: glareA),
            const Color(0xFFFFE9B8).withValues(alpha: glareA * 0.42),
            const Color(0x00FFE0A8),
          ],
          const [0.0, 0.35, 1.0],
        ),
    );

    // ---- 海浪层（远 → 近，相位不同） ----
    for (var i = 0; i < 4; i++) {
      final baseY = horizon + (h - horizon) * (0.04 + i * 0.15);
      final amp = h * (0.008 + i * 0.008);
      final freq = 1.4 + i * 0.55;
      final phase = t * twoPi * (i.isEven ? 1 : -1) * (0.5 + i * 0.22);
      _wave(canvas, w, h, baseY, amp, freq, phase, 0.13 + i * 0.04);
    }

    // ---- 近处浪花 ----
    canvas.drawRect(
      Rect.fromLTWH(0, h * 0.90, w, h * 0.10),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, h * 0.90),
          Offset(0, h),
          const [Color(0x00DFF6FA), Color(0x40E8FAFD), Color(0x8AF0FCFF)],
          const [0.0, 0.55, 1.0],
        ),
    );
  }

  void _wave(Canvas canvas, double w, double h, double baseY, double amp,
      double freq, double phase, double alpha) {
    const steps = 26;
    final path = Path()..moveTo(0, baseY);
    for (var i = 1; i <= steps; i++) {
      final x = w * i / steps;
      final y = baseY + math.sin(x / w * math.pi * 2 * freq + phase) * amp;
      path.lineTo(x, y);
    }
    final fill = Path.from(path)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, baseY - amp),
          Offset(0, baseY + h * 0.10),
          [
            Colors.white.withValues(alpha: alpha),
            Colors.white.withValues(alpha: alpha * 0.15),
          ],
        ),
    );
    // 浪脊高光
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: alpha * 1.6),
    );
  }

  void _cloud(Canvas canvas,
      {required Offset center, required Size size, required double alpha}) {
    final r = Rect.fromCenter(
        center: center, width: size.width, height: size.height);
    canvas.drawOval(
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    // 云顶再叠一层，形状更有层次
    canvas.drawOval(
      Rect.fromCenter(
        center: center.translate(size.width * 0.16, -size.height * 0.22),
        width: size.width * 0.52,
        height: size.height * 0.72,
      ),
      Paint()
        ..color = Colors.white.withValues(alpha: alpha * 0.7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
  }

  @override
  bool shouldRepaint(covariant _OceanPainter old) => false;
}
