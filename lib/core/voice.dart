import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 收银语音播报（系统原生 TTS：macOS AVSpeechSynthesizer /
/// Windows SAPI / Android 系统TTS，离线可用，无费用）。
/// 设置页「语音播报」开关控制，收款成功时播报「微信收款X元Y角」。
class VoiceService {
  VoiceService._();
  static final VoiceService instance = VoiceService._();

  static const prefEnabled = 'voice_enabled';

  FlutterTts? _tts;
  bool? _enabledCache;

  /// 是否开启语音播报（默认开启）
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
    if (!v) stop();
  }

  FlutterTts get _engine {
    if (_tts != null) return _tts!;
    final t = FlutterTts();
    t.setLanguage('zh-CN');
    t.setSpeechRate(0.45); // 语速适中，收银场景清晰易听
    t.setVolume(1.0);
    t.setPitch(1.0);
    t.awaitSpeakCompletion(false); // 异步播报，不阻塞收银
    _tts = t;
    return t;
  }

  /// 播报文本（未开启时静默忽略；异常吞掉不影响业务）
  Future<void> speak(String text) async {
    try {
      if (!await enabled()) return;
      await _engine.speak(text);
    } catch (_) {}
  }

  /// 收款成功播报：如「微信收款，8元8角」
  Future<void> pay(String method, double amount) async {
    if (!await enabled()) return;
    await speak('${method.isEmpty ? '收款' : method}收款，${money(amount)}');
  }

  void stop() {
    try {
      _tts?.stop();
    } catch (_) {}
  }

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
