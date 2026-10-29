import 'package:flutter/material.dart';
import '../../core/theme.dart';

/// 微信客服页（零售版 / 餐饮版 / 生鲜版 共用）
/// 企业微信客服二维码：美化卡片展示，扫码即达人工客服
class KefuPage extends StatelessWidget {
  const KefuPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF6F7F9),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const _KefuCard(),
            const SizedBox(height: 18),
            Text('工作时间 9:00 - 22:00，扫码后由企业微信客服一对一解答',
                style: TextStyle(fontSize: 13, color: PosTheme.textHint)),
          ]),
        ),
      ),
    );
  }
}

class _KefuCard extends StatelessWidget {
  const _KefuCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 400,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 30, offset: const Offset(0, 12)),
        ],
      ),
      child: Column(children: [
        // ===== 顶部绿色横幅 =====
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 22),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF21C36A), Color(0xFF0E9F5B)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(children: [
            Container(
              width: 54, height: 54,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.18),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.support_agent, color: Colors.white, size: 30),
            ),
            const SizedBox(height: 10),
            const Text('微信扫码咨询客服',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1)),
            const SizedBox(height: 4),
            Text('企业微信 · 微信客服 · 在线一对一',
                style: TextStyle(fontSize: 12.5, color: Colors.white.withOpacity(0.85))),
          ]),
        ),
        // ===== 二维码 =====
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFF21C36A).withOpacity(0.25), width: 2),
                boxShadow: [
                  BoxShadow(color: const Color(0xFF21C36A).withOpacity(0.10), blurRadius: 18, offset: const Offset(0, 6)),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset('assets/kefu_qr.png', width: 288, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _step('1', '打开微信'),
              const _Dot(),
              _step('2', '扫一扫'),
              const _Dot(),
              _step('3', '咨询客服'),
            ]),
          ]),
        ),
        // ===== 底部提示条 =====
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFFF0FBF5),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.verified_user_outlined, size: 16, color: const Color(0xFF0E9F5B)),
            const SizedBox(width: 6),
            Text('官方客服通道，问题、建议、故障报修均可反馈',
                style: TextStyle(fontSize: 12.5, color: const Color(0xFF0E9F5B))),
          ]),
        ),
      ]),
    );
  }

  Widget _step(String n, String text) {
    return Row(children: [
      Container(
        width: 22, height: 22,
        alignment: Alignment.center,
        decoration: const BoxDecoration(color: Color(0xFF21C36A), shape: BoxShape.circle),
        child: Text(n, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white)),
      ),
      const SizedBox(width: 5),
      Text(text, style: const TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
    ]);
  }
}

class _Dot extends StatelessWidget {
  const _Dot();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Icon(Icons.chevron_right, size: 16, color: PosTheme.textHint),
    );
  }
}
