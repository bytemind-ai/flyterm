// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ui/settings/config_backup_tile.dart
//
// 「配置备份」导出/导入行，原在 settings_screen.dart 内（`_ConfigBackupTile`），
// 2026-10-07 IA 重整时随「数据与隐私」子页拆出。改名去掉私有下划线以便跨文件引用；
// 同文件的 helper（`_ExportBottomSheet` / `_ImportPreviewDialog`）仍保持私有。
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../../data/config_backup_service.dart';
import '../../data/public_downloads.dart';
import '../../data/repositories/ai_provider_repository.dart';
import '../../data/repositories/favorite_command_repository.dart';
import '../../data/repositories/server_repository.dart';
import '../../data/repositories/ssh_key_repository.dart';
import '../../data/repositories/tunnel_repository.dart';
import '../../data/repositories/known_host_repository.dart';
import '../../data/repositories/agent_skill_repository.dart';
import '../../data/repositories/server_notes_repository.dart';
import '../../ai/agent/agent_skill_manager.dart';
import '../../ai/agent/server_notes_manager.dart';
import '../../data/keybar_settings.dart';
import '../../data/secure_storage.dart';
import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';

class ConfigBackupTile extends StatefulWidget {
  const ConfigBackupTile({super.key});

  @override
  State<ConfigBackupTile> createState() => _ConfigBackupTileState();
}

class _ConfigBackupTileState extends State<ConfigBackupTile> {
  bool _exporting = false;
  bool _importing = false;

  static const _kLastExportKey = 'config_last_export_at';

  Future<String?> _loadLastExportTimeAgo(AppLocalizations l) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLastExportKey);
    if (raw == null) return null;
    final dt = DateTime.tryParse(raw);
    if (dt == null) return null;
    final diff = DateTime.now().difference(dt);
    if (diff.inDays >= 1) return l.timeDaysAgo(diff.inDays);
    if (diff.inHours >= 1) return l.timeHoursAgo(diff.inHours);
    return l.timeJustNow;
  }

  Future<void> _saveLastExportTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastExportKey, DateTime.now().toIso8601String());
  }

  Future<void> _export() async {
    if (_exporting || _importing) return;
    final terminalSettings = context.read<TerminalSettings>();
    final serverRepo = context.read<ServerRepository>();
    final keyRepo = context.read<SSHKeyRepository>();
    final favCmdRepo = context.read<FavoriteCommandRepository>();
    final aiProviderRepo = context.read<AIProviderRepository>();
    final tunnelRepo = context.read<TunnelRepository>();
    final knownHostRepo = context.read<KnownHostRepository>();
    final notesRepo = context.read<ServerNotesRepository>();
    final skillRepo = context.read<AgentSkillRepository>();
    final keybarSettings = context.read<KeybarSettings>();

    setState(() => _exporting = true);
    try {
      final servers = await serverRepo.findAll();
      final keys = await keyRepo.findAll();
      final favCmds = await favCmdRepo.findAll();
      final aiProviders = await aiProviderRepo.findAll();
      final tunnels = await tunnelRepo.findAll();
      final knownHosts = await knownHostRepo.findAll();
      final notes = await notesRepo.all();
      final skills = await skillRepo.all();
      // AI API keys live in SecureStorage and are NOT exported — surface that
      // caveat when the backup contains any AI provider.
      final hasAiProviders = aiProviders.isNotEmpty;

      if (!mounted) return;

      final opts = await showModalBottomSheet<_ExportOptions>(
        context: context,
        builder: (ctx) => _ExportBottomSheet(
          serverCount: servers.length,
          keyCount: keys.length,
          favCommandCount: favCmds.length,
          aiProviderCount: aiProviders.length,
          tunnelCount: tunnels.length,
          knownHostCount: knownHosts.length,
          noteCount: notes.length,
          skillCount: skills.length,
          hasAiProviders: hasAiProviders,
        ),
      );

      if (opts == null || !mounted) return;

      final dir = await terminalSettings.resolveDownloadDir();
      final result = await ConfigBackupService.export(
        serverRepo: serverRepo,
        keyRepo: keyRepo,
        favCmdRepo: favCmdRepo,
        aiProviderRepo: aiProviderRepo,
        tunnelRepo: tunnelRepo,
        knownHostRepo: knownHostRepo,
        notesRepo: notesRepo,
        skillRepo: skillRepo,
        keybarSettings: keybarSettings,
        terminalSettings: terminalSettings,
        saveDir: dir,
        saveToCache: opts.choice == _ExportChoice.share,
        includeAiProviders: opts.includeAi,
        includeKnowledge: opts.includeKnowledge,
      );

      await _saveLastExportTime();

      if (!mounted) return;
      if (opts.choice == _ExportChoice.share && result.filePath != null) {
        await Share.shareXFiles(
          [XFile(result.filePath!)],
          subject: context.l10n.exportConfigSubject,
        );
      } else if (result.filePath != null) {
        // "Save to downloads": publish into the public Downloads collection so
        // the file is reachable from the system Files app (the local path is an
        // app-private sandbox on Android 11+).
        String message = context.l10n.exportConfigDone(result.filePath!);
        if (terminalSettings.downloadsToPublicStore) {
          try {
            final pub = await PublicDownloads.publish(
              source: File(result.filePath!),
              fileName: result.filePath!.split('/').last,
              mimeType: 'application/json',
            );
            if (pub != null) message = context.l10n.downloadSavedToPublic(pub.publicPath);
          } catch (_) {
            // Best-effort: fall back to reporting the local path.
          }
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message)),
          );
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.exportConfigFailed('$e'))),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _import() async {
    if (_exporting || _importing) return;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked == null || picked.files.single.path == null) return;
    final filePath = picked.files.single.path!;

    setState(() => _importing = true);
    try {
      final terminalSettings = context.read<TerminalSettings>();
      final serverRepo = context.read<ServerRepository>();
      final keyRepo = context.read<SSHKeyRepository>();
      final favCmdRepo = context.read<FavoriteCommandRepository>();
      final aiProviderRepo = context.read<AIProviderRepository>();
      final tunnelRepo = context.read<TunnelRepository>();
      final knownHostRepo = context.read<KnownHostRepository>();
      final notesRepo = context.read<ServerNotesRepository>();
      final skillRepo = context.read<AgentSkillRepository>();
      final keybarSettings = context.read<KeybarSettings>();
      final storage = context.read<SecureStorageService>();
      final db = context.read<Database>();

      final preview = await ConfigBackupService.previewImport(
        filePath: filePath,
        db: db,
        serverRepo: serverRepo,
        keyRepo: keyRepo,
        favCmdRepo: favCmdRepo,
        aiProviderRepo: aiProviderRepo,
        tunnelRepo: tunnelRepo,
        knownHostRepo: knownHostRepo,
        notesRepo: notesRepo,
        skillRepo: skillRepo,
      );

      if (!mounted) return;

      final confirm = await showDialog<_ImportConfirm>(
        context: context,
        builder: (ctx) => _ImportPreviewDialog(preview: preview),
      );
      if (confirm == null || !mounted) return;

      final result = await ConfigBackupService.importFromPath(
        filePath: filePath,
        db: db,
        serverRepo: serverRepo,
        keyRepo: keyRepo,
        favCmdRepo: favCmdRepo,
        aiProviderRepo: aiProviderRepo,
        tunnelRepo: tunnelRepo,
        knownHostRepo: knownHostRepo,
        notesRepo: notesRepo,
        skillRepo: skillRepo,
        keybarSettings: keybarSettings,
        storage: storage,
        terminalSettings: terminalSettings,
        overwriteAppearance: !confirm.keepAppearance,
        skillManager: context.read<AgentSkillManager>(),
        notesManager: context.read<ServerNotesManager>(),
      );

      if (mounted) {
        final l = context.l10n;
        final msg = result.totalSkip > 0
            ? l.importConfigSuccessWithSkip(result.totalNew, result.totalSkip)
            : l.importConfigDone(result.totalNew);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
                SnackBar(content: Text(context.l10n.importConfigFailed('$e'))));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      children: [
        FutureBuilder<String?>(
          future: _loadLastExportTimeAgo(l),
          builder: (ctx, snap) {
            final subtitle = snap.data == null
                ? l.exportConfigNeverBackedUp
                : l.exportConfigLastBackup(snap.data!);
            return ListTile(
              leading: const Icon(Icons.upload, size: 20),
              title: Text(l.exportConfig),
              subtitle: Text(subtitle,
                  style: const TextStyle(fontSize: 11.5)),
              trailing: _exporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right, size: 18),
              dense: true,
              visualDensity: VisualDensity.compact,
              onTap: (_exporting || _importing) ? null : _export,
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.download, size: 20),
          title: Text(l.importConfig),
          subtitle: Text(l.importConfigSubtitle,
              style: const TextStyle(fontSize: 11.5)),
          trailing: _importing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right, size: 18),
          dense: true,
          visualDensity: VisualDensity.compact,
          onTap: (_exporting || _importing) ? null : _import,
        ),
      ],
    );
  }
}

enum _ExportChoice { share, saveLocal }

/// 导出确认的结果：去向 + 两个内容开关。
class _ExportOptions {
  final _ExportChoice choice;
  final bool includeAi;
  final bool includeKnowledge;
  const _ExportOptions(this.choice, this.includeAi, this.includeKnowledge);
}

class _ExportBottomSheet extends StatefulWidget {
  final int serverCount,
      keyCount,
      favCommandCount,
      aiProviderCount,
      tunnelCount,
      knownHostCount,
      noteCount,
      skillCount;
  final bool hasAiProviders;

  const _ExportBottomSheet({
    required this.serverCount,
    required this.keyCount,
    required this.favCommandCount,
    required this.aiProviderCount,
    required this.tunnelCount,
    required this.knownHostCount,
    required this.noteCount,
    required this.skillCount,
    required this.hasAiProviders,
  });

  @override
  State<_ExportBottomSheet> createState() => _ExportBottomSheetState();
}

class _ExportBottomSheetState extends State<_ExportBottomSheet> {
  // 默认都带上 —— 关闭是例外，不是常规。
  bool _includeAi = true;
  bool _includeKnowledge = true;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final parts = <String>[];
    if (widget.serverCount > 0) {
      parts.add(l.exportConfigCountServers(widget.serverCount));
    }
    if (widget.keyCount > 0) {
      parts.add(l.exportConfigCountKeys(widget.keyCount));
    }
    if (widget.favCommandCount > 0) {
      parts.add(l.exportConfigCountFavCmds(widget.favCommandCount));
    }
    if (widget.tunnelCount > 0) {
      parts.add(l.exportConfigCountTunnels(widget.tunnelCount));
    }
    if (widget.knownHostCount > 0) {
      parts.add(l.exportConfigCountKnownHosts(widget.knownHostCount));
    }
    if (_includeAi && widget.aiProviderCount > 0) {
      parts.add(l.exportConfigCountAi(widget.aiProviderCount));
    }
    if (_includeKnowledge && widget.noteCount > 0) {
      parts.add(l.exportConfigCountNotes(widget.noteCount));
    }
    if (_includeKnowledge && widget.skillCount > 0) {
      parts.add(l.exportConfigCountSkills(widget.skillCount));
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              parts.isEmpty ? l.exportConfigEmpty : parts.join(' · '),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (widget.hasAiProviders && _includeAi) ...[
              const SizedBox(height: 6),
              Text(
                l.exportConfigHasAiKeys,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.orange[700]),
              ),
            ],
            const SizedBox(height: 8),
            // AI 知识与笔记体积可能很大（技能正文上限 8KB/条且无条数上限），
            // 而备份文件常经 IM / 邮件传递 —— 让用户可关。
            CheckboxListTile(
              value: _includeAi,
              onChanged: (v) => setState(() => _includeAi = v ?? true),
              title: Text(l.exportConfigIncludeAi),
              subtitle: Text(l.exportConfigIncludeAiDesc,
                  style: const TextStyle(fontSize: 11.5)),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            CheckboxListTile(
              value: _includeKnowledge,
              onChanged: (v) => setState(() => _includeKnowledge = v ?? true),
              title: Text(l.exportConfigIncludeKnowledge),
              subtitle: Text(l.exportConfigIncludeKnowledgeDesc,
                  style: const TextStyle(fontSize: 11.5)),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => Navigator.pop(
                  context,
                  _ExportOptions(_ExportChoice.share, _includeAi,
                      _includeKnowledge)),
              icon: const Icon(Icons.share),
              label: Text(l.exportConfigSendToDevice),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(
                  context,
                  _ExportOptions(_ExportChoice.saveLocal, _includeAi,
                      _includeKnowledge)),
              child: Text(l.exportConfigSaveLocal),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// 导入确认结果：是否保留当前外观。
class _ImportConfirm {
  final bool keepAppearance;
  const _ImportConfirm(this.keepAppearance);
}

class _ImportPreviewDialog extends StatefulWidget {
  final ConfigBackupPreview preview;

  const _ImportPreviewDialog({required this.preview});

  @override
  State<_ImportPreviewDialog> createState() => _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends State<_ImportPreviewDialog> {
  /// 默认 false = 保持现有行为（覆盖外观）。改变默认值会让既有用户意外。
  bool _keepAppearance = false;

  ConfigBackupPreview get preview => widget.preview;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(l.importConfigPreviewTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (preview.serverCount > 0)
              _previewRow(context, l.importConfigPreviewServers,
                  preview.serverCount, preview.serverSkip, l),
            if (preview.keyCount > 0)
              _previewRow(context, l.importConfigPreviewKeys,
                  preview.keyCount, preview.keySkip, l),
            if (preview.keyCount > 0) ...[
              const SizedBox(height: 8),
              // P1：私钥在 SecureStorage 从不导出，但这里原先只警告了 AI 密钥。
              // 用户看到「SSH 密钥 2 个（全部新增）」会以为密钥迁移成功，
              // 实际按它连接必然失败。
              Text(
                l.importConfigPreviewSshKeysNotIncluded,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.orange[700]),
              ),
            ],
            if (preview.favCommandCount > 0)
              _previewRow(context, l.importConfigPreviewFavCmds,
                  preview.favCommandCount, preview.favCommandSkip, l),
            if (preview.aiProviderCount > 0)
              _previewRow(context, l.importConfigPreviewAiProviders,
                  preview.aiProviderCount, preview.aiProviderSkip, l),
            if (preview.tunnelCount > 0)
              _previewRow(context, l.importConfigPreviewTunnels,
                  preview.tunnelCount, preview.tunnelSkip, l),
            if (preview.knownHostCount > 0)
              _previewRow(context, l.importConfigPreviewKnownHosts,
                  preview.knownHostCount, preview.knownHostSkip, l),
            // 技能的冲突语义是「覆盖」而非「跳过」—— 单列显示，否则文案自相矛盾。
            if (preview.skillCount > 0 && preview.skillOverwriteCount > 0)
              _previewRow(context, l.importConfigPreviewSkills,
                  preview.skillCount, preview.skillOverwriteCount, l),
            if (preview.hasKeybar) ...[
              const SizedBox(height: 12),
              Text(
                l.importConfigPreviewKeybarWarning,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.orange[700]),
              ),
            ],
            if (preview.hasSettings) ...[
              const SizedBox(height: 12),
              Text(
                l.importConfigPreviewSettingsWarning,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.orange[700]),
              ),
            ],
            if (preview.hasAiProviders) ...[
              const SizedBox(height: 8),
              Text(
                l.importConfigPreviewAiKeysNotIncluded,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.orange[700]),
              ),
            ],
            const SizedBox(height: 8),
            // 多设备场景：导入别人的备份不该无声抹掉自己的主题与 KeyBar 布局。
            CheckboxListTile(
              value: _keepAppearance,
              onChanged: (v) => setState(() => _keepAppearance = v ?? false),
              title: Text(l.importConfigKeepAppearance),
              subtitle: Text(l.importConfigKeepAppearanceDesc,
                  style: const TextStyle(fontSize: 11.5)),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, _ImportConfirm(_keepAppearance)),
          child: Text(l.importConfigConfirm),
        ),
      ],
    );
  }

  Widget _previewRow(BuildContext context, String label, int count, int skip,
      dynamic l) {
    final newCount = count - skip;
    final detail = skip > 0
        ? l.importConfigPreviewWithSkip(newCount, skip)
        : l.importConfigPreviewNew(count);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Expanded(child: Text(detail)),
        ],
      ),
    );
  }
}

