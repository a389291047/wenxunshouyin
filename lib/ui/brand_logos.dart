import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 微信支付 / 支付宝官方品牌 logo 共享组件（v3.3.167）
///
/// - WechatPayLogo：微信支付官方 logo（来源：微信支付官方资源
///   gtimg.wechatpay.cn wechat_partner_logo.svg，截取左侧气泡图标部分，
///   官方矢量：绿色气泡 + 白色对勾）
/// - AlipayLogo：支付宝官方矢量标志（simple-icons 官方 path，含圆角方块外形）
///
/// 使用处：扫码收款弹窗头部、餐饮/零售结账支付方式卡片。

// 微信支付官方 logo 图标部分（从官方横版 logo SVG 截取，viewBox 40x36）
const String kWechatPaySvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 36">'
    '<path d="M14.4243 22.0958C14.2406 22.1877 14.0568 22.2336 13.8271 22.2336C13.3218 22.2336 12.9084 21.958 12.6787 21.5446L12.5868 21.3608L8.95777 13.4596C8.91183 13.3677 8.91183 13.2759 8.91183 13.184C8.91183 12.8165 9.18745 12.5409 9.55495 12.5409C9.69276 12.5409 9.83057 12.5868 9.96839 12.6787L14.2406 15.7105C14.5621 15.8943 14.9296 16.0321 15.343 16.0321C15.5727 16.0321 15.8024 15.9862 16.0321 15.8943L36.0608 6.98246C32.4776 2.75624 26.5517 0 19.8449 0C8.91183 0 0 7.3959 0 16.5374C0 21.4986 2.66436 26.0005 6.84465 29.0324C7.16621 29.262 7.3959 29.6755 7.3959 30.0889C7.3959 30.2267 7.34996 30.3645 7.30403 30.5023C6.98246 31.7427 6.43122 33.7639 6.43122 33.8558C6.38528 33.9936 6.33934 34.1773 6.33934 34.3611C6.33934 34.7286 6.61497 35.0042 6.98246 35.0042C7.12028 35.0042 7.25809 34.9583 7.34996 34.8664L11.6681 32.3398C11.9896 32.1561 12.3571 32.0183 12.7246 32.0183C12.9084 32.0183 13.1381 32.0642 13.3218 32.1101C15.343 32.7073 17.548 33.0289 19.799 33.0289C30.732 33.0289 39.6439 25.633 39.6439 16.4915C39.6439 13.7352 38.817 11.1168 37.3929 8.81995L14.5621 22.004L14.4243 22.0958Z" fill="#22AC38"/></svg>';

// 支付宝官方 logo 矢量（viewBox 24x24，单色填充）
const String kAlipaySvg = '<svg fill="#FFFFFF" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">'
    '<path d="M19.695 15.07c3.426 1.158 4.203 1.22 4.203 1.22V3.846c0-2.124-1.705-3.845-3.81-3.845H3.914C1.808.001.102 1.722.102 3.846v16.31c0 2.123 1.706 3.845 3.813 3.845h16.173c2.105 0 3.81-1.722 3.81-3.845v-.157s-6.19-2.602-9.315-4.119c-2.096 2.602-4.8 4.181-7.607 4.181-4.75 0-6.361-4.19-4.112-6.949.49-.602 1.324-1.175 2.617-1.497 2.025-.502 5.247.313 8.266 1.317a16.796 16.796 0 0 0 1.341-3.302H5.781v-.952h4.799V6.975H4.77v-.953h5.81V3.591s0-.409.411-.409h2.347v2.84h5.744v.951h-5.744v1.704h4.69a19.453 19.453 0 0 1-1.986 5.06c1.424.52 2.702 1.011 3.654 1.333m-13.81-2.032c-.596.06-1.71.325-2.321.869-1.83 1.608-.735 4.55 2.968 4.55 2.151 0 4.301-1.388 5.99-3.61-2.403-1.182-4.438-2.028-6.637-1.809"/></svg>';

class WechatPayLogo extends StatelessWidget {
  final double size;

  /// logo 颜色：官方绿 #22AC38；绿色头部上用白色（镂空对勾透出底色）
  final Color color;
  const WechatPayLogo(
      {super.key, this.size = 26, this.color = const Color(0xFF22AC38)});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(kWechatPaySvg,
        width: size,
        height: size * 36 / 40,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn));
  }
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
