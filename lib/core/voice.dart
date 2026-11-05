import 'package:shared_preferences/shared_preferences.dart';

/// 语音播报（已停用）。
/// 为兼容 Windows 7 移除了 flutter_tts 插件（其 Windows 实现依赖 Win8+ API），
/// 本类保留原有 API 作为静默空实现，收款流程调用不受影响；
/// 设置页「语音播报」开关仍可保存偏好，但不再发声。
class VoiceService {
  VoiceService._();
  static final VoiceService instance = VoiceService._();

  static const prefEnabled = 'voice_enabled';

  bool? _enabledCache;

  /// 是否开启语音播报（默认开启；当前版本静默不发声）
  Future<bool> enabled() async {
    if (_enabledCache != null) return _enabledCache!;
    final sp = await SharedPreferences.getInstance();
    _enabledCache = sp.getBool(prefEnabled) ?? true;
    return _enabledCache!;
  }

  Future<void> setEnabled(bool v) async {
    _enabledCache = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(prefEnabled, v);
  }

  /// 播报文本（当前版本静默空实现）
  Future<void> speak(String text) async {}

  /// 收款成功播报（当前版本静默空实现）
  Future<void> pay(String method, double amount) async {}

  void stop() {}

  /// 金额转口语读法：8.80 → 「8元8角」；12.00 → 「12元」；0.05 → 「5分」
  static String money(double v) {
    final cents = (v * 100).round();
    final yuan = cents ~/ 100;
    final jiao = (cents % 100) ~/ 10;
    final fen = cents % 10;
    final parts = <String>[];
    if (yuan > 0) parts.add('$yuan元');
    if (jiao > 0) parts.add('$jiao角');
    if (fen > 0) parts.add('$fen分');
    if (parts.isEmpty) return '0元';
    return parts.join();
  }
}
