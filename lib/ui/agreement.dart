import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/theme.dart';

/// 线上协议地址（与小程序/微信转App 隐私弹窗共用同一套）
class AgreementUrls {
  static const user = 'https://shop.wx-zf.com/api/api/agreement';
  static const privacy = 'https://shop.wx-zf.com/api/api/privacy';
}

Future<void> openAgreement(BuildContext context, {required bool privacy}) async {
  final url = Uri.parse(privacy ? AgreementUrls.privacy : AgreementUrls.user);
  try {
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('无法打开浏览器，请手动访问协议链接'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('打开失败：${privacy ? AgreementUrls.privacy : AgreementUrls.user}'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

/// 「我已阅读并同意《用户协议》和《隐私政策》」勾选行
/// 协议名称可点击，跳系统浏览器打开线上协议页（Android / macOS / Windows 通用）
class AgreementCheck extends StatelessWidget {
  const AgreementCheck({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 13, color: PosTheme.textSub);
    final link = TextStyle(
        fontSize: 13, color: PosTheme.accent, fontWeight: FontWeight.w600,
        decoration: TextDecoration.underline, decorationColor: PosTheme.accent.withValues(alpha: 0.5));
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 22, height: 22,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: PosTheme.accent,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: style,
                children: [
                  const TextSpan(text: '我已阅读并同意'),
                  TextSpan(text: '《用户协议》', style: link, recognizer: TapGestureRecognizer()..onTap = () => openAgreement(context, privacy: false)),
                  const TextSpan(text: '和'),
                  TextSpan(text: '《隐私政策》', style: link, recognizer: TapGestureRecognizer()..onTap = () => openAgreement(context, privacy: true)),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
