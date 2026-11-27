import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/api.dart';
import '../core/session.dart';
import '../core/theme.dart';

/// 会员激活码弹窗（v3.3.282）：复用副屏客显右卡的会员激活码
///
/// 二维码与副屏同源：GET /index/vip/qrcode?vip_id=<商户ID>&size=1200（PNG），
/// 顾客微信扫码进入激活页注册/绑定会员，充值享赠送。
Future<void> showVipQrDialog(BuildContext context) async {
  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (_) => const _VipQrDialog(),
  );
}

class _VipQrDialog extends StatefulWidget {
  const _VipQrDialog();

  @override
  State<_VipQrDialog> createState() => _VipQrDialogState();
}

class _VipQrDialogState extends State<_VipQrDialog> {
  Uint8List? _qr;
  String? _err;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 与副屏 customer_screen_page._loadQr 同款判定（200 且字节 > 600 视为图片）
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final url =
          Uri.parse('${Api.base}/index/vip/qrcode?vip_id=${Session.wenxunId}&size=1200');
      final res = await http.get(url).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (res.statusCode == 200 && res.bodyBytes.length > 600) {
        setState(() {
          _qr = res.bodyBytes;
          _loading = false;
        });
      } else {
        setState(() {
          _loading = false;
          _err = '二维码加载失败，点击重试';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = '网络异常，点击重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: EdgeInsets.zero,
      contentPadding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 4, 24, 18),
      title: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [PosTheme.accentLive, PosTheme.deepLive],
            ),
          ),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.qr_code_2, size: 24, color: Colors.white),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('会员激活码',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
                SizedBox(height: 2),
                Text('微信扫一扫 · 免费注册会员',
                    style: TextStyle(fontSize: 12.5, color: Colors.white70)),
              ]),
            ),
          ]),
        ),
      ),
      content: SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // 二维码：渐变描边 + 白底留白（保证可扫）
          GestureDetector(
            onTap: (_loading || _qr != null) ? null : _load,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFFC79A), Color(0xFFFF7A45)],
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              padding: const EdgeInsets.all(4),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(15),
                ),
                padding: const EdgeInsets.all(10),
                alignment: Alignment.center,
                child: _loading
                    ? const SizedBox(
                        width: 30,
                        height: 30,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      )
                    : _qr != null
                        ? Image.memory(_qr!, fit: BoxFit.contain)
                        : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            const Icon(Icons.wifi_off_rounded,
                                size: 34, color: PosTheme.textHint),
                            const SizedBox(height: 8),
                            Text('$_err',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 12.5, color: PosTheme.textSub)),
                          ]),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: PosTheme.tint,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.card_giftcard, size: 14, color: PosTheme.accentLive),
              const SizedBox(width: 6),
              Text('注册会员 · 充值享赠送',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: PosTheme.accentLive)),
            ]),
          ),
        ]),
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: PosTheme.textSub,
              side: const BorderSide(color: PosTheme.line),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(context),
            child: const Text('我知道了', style: TextStyle(fontSize: 14.5)),
          ),
        ),
      ],
    );
  }
}
