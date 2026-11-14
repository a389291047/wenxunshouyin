import 'dart:io';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/theme.dart';
import '../core/updater.dart';

/// 在线更新弹窗（v3.3.79）：展示新版信息 → 商户点「立即更新」下载（进度条）→ 校验 → 安装
/// 全程商户主动确认，不点不更新；更新只替换程序文件，不影响本地配置与业务数据。
class UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const UpdateDialog({super.key, required this.info});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  // 0 确认页 / 1 下载中 / 2 待安装 / 3 安装中 / 4 mac 安装指引
  int _phase = 0;
  double _progress = 0;
  String _savedPath = '';
  String? _error;

  bool get _isMac => Platform.isMacOS;

  /// macOS 更新走 App Store（v3.3.203）：直接跳商店，不下载 DMG
  Future<void> _openStore() async {
    try {
      await AppStore.open();
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  Future<void> _startDownload() async {
    setState(() { _phase = 1; _error = null; _progress = 0; });
    try {
      final path = await Updater.download(widget.info, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() { _savedPath = path; _phase = _isMac ? 4 : 2; });
    } on ApiError catch (e) {
      if (mounted) setState(() { _phase = 0; _error = e.message; });
    } catch (e) {
      if (mounted) setState(() { _phase = 0; _error = '下载失败，请检查网络后重试'; });
    }
  }

  Future<void> _install() async {
    setState(() { _phase = 3; _error = null; });
    try {
      await Updater.install(_savedPath);
      if (!mounted) return;
      // mac 打开 DMG 后提示拖拽；Windows 会自动退出由安装器拉起新版
      if (_isMac) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() { _phase = 2; _error = '启动安装失败：$e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 42, height: 42,
                decoration: BoxDecoration(color: PosTheme.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(11)),
                child: const Icon(Icons.system_update_alt, color: PosTheme.accent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_phase >= 1 ? '正在更新' : '发现新版本',
                    style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('v${Updater.curVersion} → v${i.version}',
                    style: const TextStyle(fontSize: 12.5, color: PosTheme.textSub)),
              ])),
            ]),
            const SizedBox(height: 16),
            if (_phase == 0) ...[
              if (i.notes.trim().isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(10)),
                  child: Text(i.notes.trim(), style: const TextStyle(fontSize: 13, height: 1.55, color: PosTheme.textMain)),
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(fontSize: 12.5, color: PosTheme.red)),
              ],
              const SizedBox(height: 10),
              Row(children: [
                const Icon(Icons.shield_outlined, size: 14, color: PosTheme.textHint),
                const SizedBox(width: 4),
                Expanded(child: Text(_isMac
                    ? 'macOS 版已上架 App Store，点击下方按钮在应用商店完成更新'
                    : '更新仅替换程序文件，不影响本地配置与业务数据（数据在服务器）',
                    style: const TextStyle(fontSize: 11.5, color: PosTheme.textHint))),
              ]),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(foregroundColor: PosTheme.textSub, side: const BorderSide(color: PosTheme.line), padding: const EdgeInsets.symmetric(vertical: 12)),
                  child: const Text('暂不更新'),
                )),
                const SizedBox(width: 12),
                Expanded(child: FilledButton(
                  onPressed: _isMac ? _openStore : _startDownload,
                  style: FilledButton.styleFrom(backgroundColor: PosTheme.accent, padding: const EdgeInsets.symmetric(vertical: 12)),
                  child: Text(_isMac ? '前往 App Store' : '立即更新', style: const TextStyle(fontWeight: FontWeight.w600)),
                )),
              ]),
            ] else if (_phase == 1) ...[
              Text('正在下载安装包… ${(_progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 13, color: PosTheme.textSub)),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(value: _progress > 0 ? _progress : null, minHeight: 8, backgroundColor: const Color(0xFFEDEFF2), color: PosTheme.accent),
              ),
              const SizedBox(height: 18),
              SizedBox(width: double.infinity, child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(foregroundColor: PosTheme.textSub, side: const BorderSide(color: PosTheme.line), padding: const EdgeInsets.symmetric(vertical: 12)),
                child: const Text('取消'),
              )),
            ] else if (_phase == 2) ...[
              const Text('下载完成，安装包已通过完整性校验。', style: TextStyle(fontSize: 13.5)),
              const SizedBox(height: 6),
              const Text('点击下方按钮后应用将自动退出并完成安装，安装完成后会自动启动新版本。',
                  style: TextStyle(fontSize: 12.5, color: PosTheme.textHint, height: 1.5)),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(fontSize: 12.5, color: PosTheme.red)),
              ],
              const SizedBox(height: 18),
              Row(children: [
                Expanded(child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(foregroundColor: PosTheme.textSub, side: const BorderSide(color: PosTheme.line), padding: const EdgeInsets.symmetric(vertical: 12)),
                  child: const Text('稍后安装'),
                )),
                const SizedBox(width: 12),
                Expanded(child: FilledButton(
                  onPressed: _install,
                  style: FilledButton.styleFrom(backgroundColor: PosTheme.accent, padding: const EdgeInsets.symmetric(vertical: 12)),
                  child: const Text('开始安装', style: TextStyle(fontWeight: FontWeight.w600)),
                )),
              ]),
            ] else if (_phase == 3) ...[
              const Text('正在启动安装…', style: TextStyle(fontSize: 13.5, color: PosTheme.textSub)),
              const SizedBox(height: 14),
              const Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.6, color: PosTheme.accent))),
              const SizedBox(height: 6),
            ] else ...[
              const Text('安装镜像已打开，请将「稳讯收银」拖入右侧 Applications 文件夹完成安装，然后重新打开应用。',
                  style: TextStyle(fontSize: 13.5, height: 1.6)),
              const SizedBox(height: 18),
              SizedBox(width: double.infinity, child: FilledButton(
                onPressed: () => Navigator.pop(context),
                style: FilledButton.styleFrom(backgroundColor: PosTheme.accent, padding: const EdgeInsets.symmetric(vertical: 12)),
                child: const Text('知道了'),
              )),
            ],
          ]),
        ),
      ),
    );
  }
}
