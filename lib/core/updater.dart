import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

/// macOS 更新走 App Store（v3.3.203）：检查到新版本直接跳商店，不再下载 DMG
class AppStore {
  AppStore._();

  static const url = 'https://apps.apple.com/cn/app/%E7%A8%B3%E8%AE%AF%E6%94%B6%E9%93%B6/id6746535178';

  /// 用 itms-apps 协议直接拉起 App Store 应用；失败回落浏览器打开网页
  static Future<void> open() async {
    final itms = Uri.parse('itms-apps://apps.apple.com/cn/app/id6746535178');
    try {
      if (await launchUrl(itms, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}

/// 在线更新服务（v3.3.79）
/// 原则：只在设置页商户手动点击时检查/下载/安装；没有新版本或商户不点，什么都不发生。
/// 数据安全：更新只替换程序目录文件；本地配置（USB 打印机、打印开关、记住的登录等）
/// 存在系统用户目录（Win %APPDATA% / mac ~/Library），业务数据在服务器，均不受更新影响。
class UpdateInfo {
  final String version; // 最新版本号，如 3.3.79
  final int versionCode; // 最新构建号，如 3379
  final String notes; // 更新说明
  final String urlWin; // Windows 安装包（Inno Setup exe）下载地址
  final String urlMac; // macOS DMG 下载地址
  final String md5Win; // 安装包 MD5（空则跳过校验）
  final String md5Mac;
  final int force; // 预留：1 强制更新（当前版本仅提示）

  UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.notes,
    required this.urlWin,
    required this.urlMac,
    required this.md5Win,
    required this.md5Mac,
    required this.force,
  });

  factory UpdateInfo.fromMap(Map m) => UpdateInfo(
        version: '${m['version'] ?? ''}',
        versionCode: int.tryParse('${m['version_code'] ?? 0}') ?? 0,
        notes: '${m['notes'] ?? ''}',
        urlWin: '${m['url_win'] ?? ''}',
        urlMac: '${m['url_mac'] ?? ''}',
        md5Win: '${m['md5_win'] ?? ''}',
        md5Mac: '${m['md5_mac'] ?? ''}',
        force: int.tryParse('${m['force'] ?? 0}') ?? 0,
      );
}

class Updater {
  static PackageInfo? _pkg;

  /// App 启动后调用一次（读取当前版本，失败不影响使用）
  static Future<void> init() async {
    if (_pkg != null) return;
    try {
      _pkg = await PackageInfo.fromPlatform();
    } catch (_) {
      _pkg = null;
    }
  }

  static String get curVersion => _pkg?.version ?? '';
  static int get curCode => int.tryParse(_pkg?.buildNumber ?? '') ?? 0;

  /// 仅桌面端支持在线更新
  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// 检查更新：有新版本返回 UpdateInfo；无新版本 / 后端未配置返回 null
  static Future<UpdateInfo?> check() async {
    await init();
    if (!supported || curCode <= 0) return null;
    final r = await Api.post(
        '/api/shengji/check', {'version_code': curCode},
        withToken: false);
    if ('${r['code']}' != '200') return null;
    final data = r['data'];
    if (data is! Map) return null;
    final info = UpdateInfo.fromMap(Map<String, dynamic>.from(data));
    return info.versionCode > curCode ? info : null;
  }

  /// 下载安装包（onProgress 0.0~1.0），成功返回本地文件路径；MD5 不匹配删除并抛错
  static Future<String> download(UpdateInfo info,
      {void Function(double)? onProgress}) async {
    final isMac = Platform.isMacOS;
    final url = (isMac ? info.urlMac : info.urlWin).trim();
    final wantMd5 = (isMac ? info.md5Mac : info.md5Win).trim().toLowerCase();
    if (url.isEmpty) {
      throw ApiError('服务器未配置${isMac ? ' macOS' : ' Windows'} 安装包，请联系管理员');
    }
    final dir = await getTemporaryDirectory();
    final ext = isMac ? '.dmg' : '.exe';
    final savePath =
        '${dir.path}${Platform.pathSeparator}wenxun-setup-v${info.version}$ext';

    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw ApiError('下载失败（HTTP ${res.statusCode}），请稍后重试');
      }
      final total = res.contentLength ?? 0;
      final sink = File(savePath).openWrite();
      var received = 0;
      await for (final chunk in res.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0 && onProgress != null) onProgress(received / total);
      }
      await sink.close();
    } finally {
      client.close();
    }

    if (wantMd5.isNotEmpty) {
      final digest = md5.convert(await File(savePath).readAsBytes()).toString();
      if (digest != wantMd5) {
        try {
          File(savePath).deleteSync();
        } catch (_) {}
        throw ApiError('安装包校验失败，已取消更新，请重试');
      }
    }
    return savePath;
  }

  /// 执行安装（商户在弹窗里点「安装」才走到这里）
  /// Windows：静默安装 Inno Setup 包（不弹向导、保留用户数据），装完自动启动新版，本进程退出
  /// macOS：打开 DMG 镜像，用户把 App 拖进 Applications 即完成（macOS 系统限制无法全静默）
  static Future<void> install(String path) async {
    if (Platform.isWindows) {
      await Process.start(
        path,
        const ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'],
        mode: ProcessStartMode.detached,
      );
      // 给安装器拉起的时间，再退出本应用（Inno 装完会自动启动新版）
      await Future.delayed(const Duration(milliseconds: 600));
      exit(0);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    }
  }
}
