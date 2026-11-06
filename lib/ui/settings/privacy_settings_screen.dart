// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';
import '../legal/consent_settings_section.dart';
import 'config_backup_tile.dart';
import 'widgets/settings_section_header.dart';

/// 数据与隐私子页。
///
/// 首页此段原先直接摊开 8 项（SFTP目录/配置备份/遥测×2/文档×3/撤销同意/
/// 生物识别锁），四类东西混在一起。收进子页后内部再分「数据」与「隐私」：
/// 配置备份导出的内容含服务器/密钥/命令/AI/隧道/KeyBar —— 是全量数据管理，
/// 与隐私合规是两回事。生物识别锁已移入「安全」。
class PrivacySettingsScreen extends StatelessWidget {
  const PrivacySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        // 复用 sectionData，与首页导航行文案保持同一真相源
        title: Text(l.sectionData),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        children: const [
          SettingsSectionHeader('DATA'),
          _SftpDownloadDirTile(),
          ConfigBackupTile(),
          SettingsSectionHeader('PRIVACY'),
          ConsentSettingsSection(),
          SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _SftpDownloadDirTile extends StatelessWidget {
  const _SftpDownloadDirTile();

  String _subtitle(BuildContext context, TerminalSettings settings) {
    final l = context.l10n;
    switch (settings.sftpDownloadDir) {
      case SftpDownloadDir.downloads:
        return l.sftpDownloadDirDownloads;
      case SftpDownloadDir.documents:
        return l.sftpDownloadDirDocuments;
      case SftpDownloadDir.custom:
        return settings.sftpCustomDownloadPath ?? l.sftpDownloadDirCustom;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return ListTile(
      leading: const Icon(Icons.folder_open, size: 20),
      title: Text(l.sftpDownloadDir),
      subtitle: Text(
        _subtitle(context, settings),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      dense: true,
      visualDensity: VisualDensity.compact,
      onTap: () => _showSheet(context, settings),
    );
  }

  void _showSheet(BuildContext context, TerminalSettings settings) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SftpDownloadDirSheet(settings: settings),
    );
  }
}

class _SftpDownloadDirSheet extends StatefulWidget {
  const _SftpDownloadDirSheet({required this.settings});
  final TerminalSettings settings;

  @override
  State<_SftpDownloadDirSheet> createState() => _SftpDownloadDirSheetState();
}

class _SftpDownloadDirSheetState extends State<_SftpDownloadDirSheet> {
  late SftpDownloadDir _selected;
  late String? _customPath;

  @override
  void initState() {
    super.initState();
    _selected = widget.settings.sftpDownloadDir;
    _customPath = widget.settings.sftpCustomDownloadPath;
  }

  Future<void> _pickDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path != null && mounted) {
      setState(() => _customPath = path);
    }
  }

  void _confirm() {
    if (_selected == SftpDownloadDir.custom) {
      final path = _customPath;
      if (path != null && path.isNotEmpty) {
        widget.settings.setSftpCustomDownloadPath(path);
      }
    } else {
      widget.settings.setSftpDownloadDir(_selected);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(
              l.sftpDownloadDir,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          RadioListTile<SftpDownloadDir>(
            title: Text(l.sftpDownloadDirDownloads),
            value: SftpDownloadDir.downloads,
            groupValue: _selected,
            onChanged: (v) => setState(() => _selected = v!),
          ),
          RadioListTile<SftpDownloadDir>(
            title: Text(l.sftpDownloadDirDocuments),
            value: SftpDownloadDir.documents,
            groupValue: _selected,
            onChanged: (v) => setState(() => _selected = v!),
          ),
          RadioListTile<SftpDownloadDir>(
            title: Text(l.sftpDownloadDirCustom),
            value: SftpDownloadDir.custom,
            groupValue: _selected,
            onChanged: (v) => setState(() => _selected = v!),
          ),
          if (_selected == SftpDownloadDir.custom)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _customPath ?? l.sftpCustomPathHint,
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 13,
                        color:
                            _customPath != null
                                ? Theme.of(context).colorScheme.onSurface
                                : Theme.of(context).hintColor,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _pickDirectory,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(context.l10n.browseAction),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: FilledButton(onPressed: _confirm, child: Text(l.confirm)),
          ),
        ],
      ),
    );
  }
}

