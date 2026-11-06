// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'keybar_settings.dart';
import 'models/ai_provider_config.dart';
import 'models/favorite_command.dart';
import 'models/known_host.dart';
import '../ai/agent/agent_instructions.dart' show kMaxInstructionBytes;
import '../ai/agent/agent_skill_manager.dart';
import '../ai/agent/server_notes_manager.dart';
import '../ai/agent/skill.dart' show SkillSource;
import 'models/server.dart';
import 'models/ssh_key.dart';
import 'models/tunnel_config.dart';
import 'repositories/ai_provider_repository.dart';
import 'repositories/favorite_command_repository.dart';
import 'repositories/agent_skill_repository.dart';
import 'repositories/known_host_repository.dart';
import 'repositories/server_notes_repository.dart';
import 'repositories/server_repository.dart';
import 'repositories/ssh_key_repository.dart';
import 'repositories/tunnel_repository.dart';
import 'secure_storage.dart';
import 'terminal_settings.dart';
import '../ui/terminal/terminal_themes.dart';
import 'font_options.dart';

/// Current backup file-format version.
///
/// v2 added keybar, known_hosts, the expanded terminal-settings block, and the
/// integrity checksum. v3 (2026-10-07) added `command_completion` /
/// `background_keep_alive` to the settings block, plus the `agent_skills` and
/// `server_notes` sections. Older builds refuse files newer than the version
/// they understand; v1/v2 files remain importable.
const int _kBackupFormatVersion = 3;

/// 备份必须覆盖的 `TerminalSettings` 键（snake_case，与 payload 键名一致）。
///
/// 这是**手工维护**的清单 —— Dart 在 Flutter AOT 下没有 `dart:mirrors`，无法
/// 自动枚举 getter。它存在的唯一目的是让「新增设置项忘了改备份」在测试里
/// 暴露，而不是静默丢失（`commandCompletion` / `backgroundKeepAlive` 就是这么
/// 丢的，见 `test/data/config_backup_completeness_test.dart`）。
const Set<String> _kBackupSettingsKeys = {
  'font_size',
  'terminal_theme',
  'dangerous_command_guard',
  'sftp_download_dir',
  'sftp_custom_download_path',
  'font_family',
  'line_height',
  'cursor_style',
  'keyboard_trigger',
  'ssh_compression',
  'fet_y',
  'fet_hidden',
  'fet_opacity',
  'fet_auto_fade',
  'fet_enabled',
  'command_completion',
  'background_keep_alive',
  'cursor_blink',
  'selection_color',
};

/// 刻意不备份的 `TerminalSettings` 字段（camelCase）及其理由。
///
/// 与 [_kBackupSettingsKeys] **互补**：两者并集必须等于 `TerminalSettings` 的
/// 全部公开 getter，交集为空。护栏测试强制这一点。
const Map<String, String> _kExcludedSettingsFields = {
  'debugOverlay': '内存态 dev 开关，本就不持久化',
  'fetOnboardingShown': '每设备首运行提示，跨设备无意义',
  'downloadsToPublicStore': '派生 getter（_sftpDownloadDir == downloads），非独立设置',
};

/// One list-of-records section of the backup (servers, keys, favorites, AI
/// providers, tunnels, known hosts). Every section behaves identically —
/// export all rows, dedup on import by a stable identity — so they are driven
/// by a single registry instead of copy-pasted per-type loops. Settings and
/// the keybar are NOT rows and are handled separately.
class _Section {
  final String key;

  /// Rows already converted to JSON maps (and sanitized, e.g. mosh_pid removed).
  final Future<List<Map<String, dynamic>>> Function() exportRows;

  /// Identities of rows already present in the DB, for skip-on-import.
  ///
  /// Takes a `DatabaseExecutor` for the same reason as [insertRowTxn]: while a
  /// transaction is open, any query issued on the raw `Database` waits for that
  /// transaction to finish → deadlock. Import calls this with the transaction.
  final Future<Set<String>> Function(DatabaseExecutor) existingIds;

  /// Stable dedup identity for a raw row map.
  final String Function(Map<String, dynamic>) idOf;

  /// Deserialize a raw row map and insert it into the DB.
  ///
  /// Takes a `DatabaseExecutor` so the whole import can run inside one
  /// `Database.transaction()` — a mid-import failure must not leave a
  /// half-imported state behind.
  ///
  /// May throw [_NoteOrphan] / [_NoteRejected] to signal "skip this row for a
  /// known reason" — those are counted, not treated as failures.
  final Future<void> Function(DatabaseExecutor, Map<String, dynamic>)
      insertRowTxn;

  const _Section({
    required this.key,
    required this.exportRows,
    required this.existingIds,
    required this.idOf,
    required this.insertRowTxn,
  });
}

/// 导入时「按已知原因跳过这一行」的信号 —— 与真正的失败区分开。
///
/// 用异常而不是返回值：`_Section.insertRowTxn` 的签名要保持统一，让每个
/// section 都能自己决定「什么算跳过」。`importFromPath` 捕获它们并计数，
/// 不让它冒泡成「导入失败」。
class _NoteRejected {
  final int overflowBytes;
  const _NoteRejected(this.overflowBytes);
}

/// 笔记的 `server_id` 在导入后的库里不存在 —— 插进去就是一条 UI 上看不到的
/// 孤儿数据（笔记列表按 server 组织）。
class _NoteOrphan {
  final String serverId;
  const _NoteOrphan(this.serverId);
}

/// Builds the section registry bound to the given repositories. The order
/// matters for import: keys before servers (servers reference keyId).
List<_Section> _sections({
  required ServerRepository serverRepo,
  required SSHKeyRepository keyRepo,
  required FavoriteCommandRepository favCmdRepo,
  required AIProviderRepository aiProviderRepo,
  required TunnelRepository tunnelRepo,
  required KnownHostRepository knownHostRepo,
  required ServerNotesRepository notesRepo,
  required AgentSkillRepository skillRepo,
}) {
  String byId(Map<String, dynamic> m) => m['id'] as String? ?? '';
  return [
    _Section(
      key: 'keys',
      exportRows: () async =>
          (await keyRepo.findAll()).map((k) => k.toMap()).toList(),
      existingIds: (txn) async => {
        for (final r in await txn.query('ssh_keys')) r['id'] as String,
      },
      idOf: byId,
      insertRowTxn: (txn, m) => keyRepo.insertTxn(txn, SSHKey.fromMap(m)),
    ),
    _Section(
      key: 'servers',
      exportRows: () async => (await serverRepo.findAll()).map((s) {
        final m = Map<String, dynamic>.from(s.toMap());
        m.remove('mosh_pid'); // runtime-only PID, never portable
        return m;
      }).toList(),
      existingIds: (txn) async => {
        for (final r in await txn.query('servers')) r['id'] as String,
      },
      idOf: byId,
      insertRowTxn: (txn, m) => serverRepo.insertTxn(txn, Server.fromMap(m)),
    ),
    _Section(
      key: 'favorite_commands',
      exportRows: () async =>
          (await favCmdRepo.findAll()).map((c) => c.toMap()).toList(),
      existingIds: (txn) async => {
        for (final r in await txn.query('favorite_commands'))
          r['id'] as String,
      },
      idOf: byId,
      insertRowTxn: (txn, m) => favCmdRepo.insertTxn(txn, FavoriteCommand.fromMap(m)),
    ),
    _Section(
      key: 'ai_providers',
      exportRows: () async =>
          (await aiProviderRepo.findAll()).map((p) => p.toMap()).toList(),
      existingIds: (txn) async => {
        for (final r in await txn.query('ai_providers')) r['id'] as String,
      },
      idOf: byId,
      insertRowTxn: (txn, m) => aiProviderRepo.insertTxn(txn, AIProviderConfig.fromMap(m)),
    ),
    _Section(
      key: 'tunnels',
      exportRows: () async =>
          (await tunnelRepo.findAll()).map((t) => t.toMap()).toList(),
      existingIds: (txn) async => {
        for (final r in await txn.query('tunnels')) r['id'] as String,
      },
      idOf: byId,
      insertRowTxn: (txn, m) => tunnelRepo.insertTxn(txn, TunnelConfig.fromMap(m)),
    ),
    _Section(
      key: 'known_hosts',
      // known_hosts have no surrogate id — identity is (host, port).
      exportRows: () async => (await knownHostRepo.findAll())
          .map((h) => Map<String, dynamic>.from(h.toMap()))
          .toList(),
      existingIds: (txn) async => {
        for (final r in await txn.query('known_hosts'))
          '${r['host']}:${r['port']}',
      },
      idOf: (m) => '${m['host']}:${m['port']}',
      insertRowTxn: (txn, m) => knownHostRepo.saveTxn(txn, KnownHost.fromMap(m)),
    ),
    // ── AI 知识资产（2026-10-07 加入）────────────────────────────────────
    //
    // 这两张表此前完全不在备份里：用户在 A 设备攒的技能与笔记，换设备全丢。
    // 它们比开关值重要得多 —— 是**内容**（技能正文上限 8KB/条）。
    //
    // server_notes **必须排在 servers 之后**：它引用 servers.id，顺序错了
    // 孤儿判定会失真（server 还没插进去就被判成孤儿）。
    _Section(
      key: 'server_notes',
      exportRows: () async => (await notesRepo.all())
          .map((n) => {'server_id': n.serverId, 'body': n.body})
          .toList(),
      existingIds: (txn) async => {
        for (final r in await txn.query('server_notes'))
          r['server_id'] as String,
      },
      idOf: (m) => m['server_id'] as String,
      insertRowTxn: (txn, m) async {
        final id = m['server_id'] as String;
        final body = m['body'] as String;
        // 4 KiB 上限。备份里的笔记正常必然合规（导出时就是从库里读的、写入时
        // 已被限制），只有用户手工改过备份文件才会触发。
        final over = utf8.encode(body).length - kMaxInstructionBytes;
        if (over > 0) throw _NoteRejected(over);
        final exists = await txn.query('servers',
            columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
        if (exists.isEmpty) throw _NoteOrphan(id);
        await notesRepo.upsertTxn(txn, serverId: id, body: body);
      },
    ),
    // 去重判据用 name（COLLATE NOCASE）而非自增 id —— id 跨设备碰撞纯属偶然，
    // 而 name 有唯一索引且是技能的业务身份。
    //
    // 冲突时**覆盖**（upsert 的更新分支）：用户导入的意图是「恢复」，备份为准。
    // 注意这与其它 section 的「跳过」语义不同，所以 importFromPath 对它单列
    // skillOverwriteCount 而不计入 skips。
    //
    // last_used_at / hit_count **不导出**：它们是使用信号，跨设备会污染本机的
    // 索引名额竞争（kIndexFreshSlots 的冷启动饥饿判定）。
    _Section(
      key: 'agent_skills',
      exportRows: () async => (await skillRepo.all())
          .map((s) => {
                'name': s.name,
                'description': s.description,
                'body': s.body,
                'source': s.source.name,
              })
          .toList(),
      existingIds: (txn) async => {
        for (final r in await txn.query('agent_skills'))
          (r['name'] as String).toLowerCase(),
      },
      idOf: (m) => (m['name'] as String).toLowerCase(),
      insertRowTxn: (txn, m) async {
        final rawSource = m['source'] as String? ?? 'file';
        // 不认识的 source 回落 file —— 与 AgentSkillRepository._fromRow 的
        // orElse 一致，降级安装不会让整个技能列表打不开。
        final source = SkillSource.values.firstWhere(
          (e) => e.name == rawSource,
          orElse: () => SkillSource.file,
        );
        await skillRepo.upsertTxn(
          txn,
          name: m['name'] as String,
          description: (m['description'] as String?) ?? '',
          body: m['body'] as String,
          source: source,
        );
      },
    ),
  ];
}

/// Per-section counts keyed by section name (e.g. 'servers' → 3).
class ConfigBackupPreview {
  final Map<String, int> counts;
  final Map<String, int> skips;

  /// Backup contains AI providers. NOTE: their API keys are NOT included in the
  /// backup (they live in secure storage) — the user must re-enter them.
  final bool hasAiProviders;

  /// Backup contains a keybar block that will overwrite the current key bar.
  final bool hasKeybar;

  /// Backup contains a 'settings' block that will overwrite current values.
  final bool hasSettings;

  /// 导入时将被**覆盖**的同名技能数。与 [skips] 分开计：技能的冲突语义是
  /// 「覆盖」而非「跳过」，混在一起会让预览文案自相矛盾。
  final int skillOverwriteCount;

  const ConfigBackupPreview({
    required this.counts,
    required this.skips,
    required this.hasAiProviders,
    required this.hasKeybar,
    required this.hasSettings,
    this.skillOverwriteCount = 0,
  });

  int _c(String k) => counts[k] ?? 0;
  int _s(String k) => skips[k] ?? 0;

  int get serverCount => _c('servers');
  int get serverSkip => _s('servers');
  int get keyCount => _c('keys');
  int get keySkip => _s('keys');
  int get favCommandCount => _c('favorite_commands');
  int get favCommandSkip => _s('favorite_commands');
  int get aiProviderCount => _c('ai_providers');
  int get aiProviderSkip => _s('ai_providers');
  int get tunnelCount => _c('tunnels');
  int get tunnelSkip => _s('tunnels');
  int get knownHostCount => _c('known_hosts');
  int get knownHostSkip => _s('known_hosts');
  int get noteCount => _c('server_notes');
  int get skillCount => _c('agent_skills');

  int get totalNew =>
      counts.entries.fold(0, (a, e) => a + e.value) -
      skips.entries.fold(0, (a, e) => a + e.value);
  int get totalSkip => skips.entries.fold(0, (a, e) => a + e.value);
}

class ConfigBackupResult {
  final Map<String, int> counts;
  final Map<String, int> skips;
  final String? filePath;

  /// 因对应 server 不在导入后的库里而跳过的笔记数。
  final int orphanNoteCount;

  /// 因超出 4 KiB 上限而被拒的笔记数（只可能来自手工改过的备份文件）。
  final int rejectedNoteCount;

  /// 被覆盖的同名技能数（技能的冲突语义是「覆盖」不是「跳过」）。
  final int skillOverwriteCount;

  const ConfigBackupResult({
    this.counts = const {},
    this.skips = const {},
    this.filePath,
    this.orphanNoteCount = 0,
    this.rejectedNoteCount = 0,
    this.skillOverwriteCount = 0,
  });

  int _c(String k) => counts[k] ?? 0;
  int _s(String k) => skips[k] ?? 0;

  int get serverCount => _c('servers');
  int get keyCount => _c('keys');
  int get favCommandCount => _c('favorite_commands');
  int get aiProviderCount => _c('ai_providers');
  int get tunnelCount => _c('tunnels');
  int get knownHostCount => _c('known_hosts');
  int get serverSkip => _s('servers');
  int get keySkip => _s('keys');
  int get favCommandSkip => _s('favorite_commands');
  int get aiProviderSkip => _s('ai_providers');
  int get tunnelSkip => _s('tunnels');
  int get knownHostSkip => _s('known_hosts');
  int get noteCount => _c('server_notes');
  int get skillCount => _c('agent_skills');

  int get totalNew => counts.entries.fold(0, (a, e) => a + e.value);
  int get totalSkip => skips.entries.fold(0, (a, e) => a + e.value);
}

class ConfigBackupService {
  /// 见 [_kBackupSettingsKeys] 的文档。对外暴露供护栏测试引用。
  static const Set<String> backupSettingsKeys = _kBackupSettingsKeys;

  /// 见 [_kExcludedSettingsFields] 的文档。对外暴露供护栏测试引用。
  static const Map<String, String> excludedSettingsFields =
      _kExcludedSettingsFields;

  // ── Settings (de)serialization ───────────────────────────────────────────

  static Map<String, dynamic> _settingsToMap(TerminalSettings s) => {
        'font_size': s.fontSize,
        'terminal_theme': s.terminalTheme.name,
        'dangerous_command_guard': s.dangerousCommandGuard,
        'sftp_download_dir': s.sftpDownloadDir.name,
        'sftp_custom_download_path': s.sftpCustomDownloadPath,
        // 注：`biometric_lock` 自 2026-10-07 移除生物识别锁后不再导出。
        // 导入旧备份时该键会被静默忽略（不再读取），无需迁移。
        // Added in format v2:
        'font_family': s.fontFamily,
        'line_height': s.lineHeight,
        'cursor_style': s.cursorStyle.name,
        'keyboard_trigger': s.keyboardTrigger.name,
        'ssh_compression': s.sshCompression,
        'fet_y': s.fetY,
        'fet_hidden': s.fetHidden,
        'fet_opacity': s.fetOpacity,
        'fet_auto_fade': s.fetAutoFade,
        'fet_enabled': s.fetEnabled,
        // 2026-10-07：补上此前遗漏的两项 —— 它们有 UI、有持久化，却不在导出
        // 列表里，换设备后会静默回默认值。护栏见
        // `config_backup_completeness_test.dart`。
        'command_completion': s.commandCompletion,
        'background_keep_alive': s.backgroundKeepAlive,
        // iTerm2 对齐项（光标闪烁、选中态颜色）。两者都有 UI 与持久化，
        // 不导出就是换设备后静默回默认值 —— 与上一组同样的坑。
        'cursor_blink': s.cursorBlink,
        // null 表示「跟随主题」。用空串而不是省略键：省略与「没存过」
        // 在导入端不可区分，显式写空串才能表达「用户选的就是跟随」。
        'selection_color': s.selectionColor == null
            ? ''
            : s.selectionColor!.toARGB32().toRadixString(16).padLeft(8, '0'),
        // 不导出（理由见 [_kExcludedSettingsFields]）：debug_overlay（内存态 dev
        // 开关）、fet_onboarding_shown（每设备首运行提示）。
      };

  static Future<void> _applySettings(
      TerminalSettings ts, Map<String, dynamic> s) async {
    final fontSize = (s['font_size'] as num?)?.toDouble();
    if (fontSize != null) await ts.setFontSize(fontSize);

    final themeName = s['terminal_theme'] as String?;
    if (themeName != null) {
      await ts.setTerminalTheme(AppTerminalTheme.values.firstWhere(
        (t) => t.name == themeName,
        orElse: () => AppTerminalTheme.defaultDark,
      ));
    }

    final guard = s['dangerous_command_guard'] as bool?;
    if (guard != null) await ts.setDangerousCommandGuard(guard);

    final sftpDir = s['sftp_download_dir'] as String?;
    final sftpCustom = s['sftp_custom_download_path'] as String?;
    if (sftpDir != null) {
      final dir = SftpDownloadDir.values.firstWhere(
        (e) => e.name == sftpDir,
        orElse: () => SftpDownloadDir.downloads,
      );
      if (dir == SftpDownloadDir.custom && sftpCustom != null) {
        await ts.setSftpCustomDownloadPath(sftpCustom);
      } else {
        await ts.setSftpDownloadDir(dir);
      }
    }

    // ── v2 fields ──
    final fontFamily = s['font_family'] as String?;
    if (fontFamily != null && FontOptions.isBuiltInFamily(fontFamily)) {
      await ts.setFontFamily(fontFamily);
    }
    final lineHeight = (s['line_height'] as num?)?.toDouble();
    if (lineHeight != null) await ts.setLineHeight(lineHeight);

    final cursorStyle = s['cursor_style'] as String?;
    if (cursorStyle != null) {
      await ts.setCursorStyle(TerminalCursorStyle.values.firstWhere(
        (e) => e.name == cursorStyle,
        orElse: () => TerminalCursorStyle.defaultStyle,
      ));
    }

    final cursorBlink = s['cursor_blink'] as bool?;
    if (cursorBlink != null) await ts.setCursorBlink(cursorBlink);

    final selectionColor = s['selection_color'] as String?;
    if (selectionColor != null) {
      if (selectionColor.isEmpty) {
        await ts.setSelectionColor(null);
      } else {
        // 解析失败就保持默认（跟随主题），不拿脏值去渲染。
        final argb = int.tryParse(selectionColor, radix: 16);
        if (argb != null) await ts.setSelectionColor(Color(argb));
      }
    }

    final kbTrigger = s['keyboard_trigger'] as String?;
    if (kbTrigger != null) {
      await ts.setKeyboardTrigger(KeyboardTriggerMode.values.firstWhere(
        (e) => e.name == kbTrigger,
        orElse: () => KeyboardTriggerMode.singleTap,
      ));
    }

    final sshComp = s['ssh_compression'] as bool?;
    if (sshComp != null) await ts.setSshCompression(sshComp);

    final fetY = (s['fet_y'] as num?)?.toDouble();
    if (fetY != null) await ts.setFetY(fetY);
    final fetHidden = s['fet_hidden'] as bool?;
    if (fetHidden != null) await ts.setFetHidden(fetHidden);
    final fetOpacity = (s['fet_opacity'] as num?)?.toDouble();
    if (fetOpacity != null) await ts.setFetOpacity(fetOpacity);
    final fetAutoFade = s['fet_auto_fade'] as bool?;
    if (fetAutoFade != null) await ts.setFetAutoFade(fetAutoFade);
    final fetEnabled = s['fet_enabled'] as bool?;
    if (fetEnabled != null) await ts.setFetEnabled(fetEnabled);

    // 缺失即不改动 —— 旧备份（v2 及更早）没有这两个键，若强行写入默认值会把
    // 用户当前的设置重置掉，比不导入更糟。
    final cmdCompletion = s['command_completion'] as bool?;
    if (cmdCompletion != null) await ts.setCommandCompletion(cmdCompletion);

    final keepAlive = s['background_keep_alive'] as bool?;
    if (keepAlive != null) await ts.setBackgroundKeepAlive(keepAlive);
  }

  // ── Integrity checksum ─────────────────────────────────────────────────────

  /// SHA-256 (hex) over the compact JSON of [payload] with any existing
  /// 'checksum' key removed. Compact encoding is the canonical form so the
  /// value is independent of the pretty-printed file whitespace.
  /// 供测试构造合法备份文件用（例如造一个「有笔记但无 server」的孤儿场景）。
  /// 生产路径一律走 [_checksum]。
  @visibleForTesting
  static String debugChecksum(Map<String, dynamic> payload) =>
      _checksum(payload);

  static String _checksum(Map<String, dynamic> payload) {
    final copy = Map<String, dynamic>.from(payload)..remove('checksum');
    return sha256.convert(utf8.encode(jsonEncode(copy))).toString();
  }

  // ── Export ─────────────────────────────────────────────────────────────────

  /// Exports all user configuration to [saveDir]: servers, SSH key metadata,
  /// favorite commands, AI providers, tunnel configs, known hosts, the on-screen
  /// key bar, and terminal settings.
  ///
  /// Secrets are NEVER exported: SSH private keys, server passwords, and AI API
  /// keys all live in secure storage and stay on the device. After importing on
  /// another device the user must re-enter them.
  static Future<ConfigBackupResult> export({
    required ServerRepository serverRepo,
    required SSHKeyRepository keyRepo,
    required FavoriteCommandRepository favCmdRepo,
    required AIProviderRepository aiProviderRepo,
    required TunnelRepository tunnelRepo,
    required KnownHostRepository knownHostRepo,
    required ServerNotesRepository notesRepo,
    required AgentSkillRepository skillRepo,
    required KeybarSettings keybarSettings,
    required TerminalSettings terminalSettings,
    required Directory saveDir,
    bool saveToCache = false,
    /// 关掉则备份不含 ai_providers 段（用户可能不想让 provider 配置随文件外流）。
    bool includeAiProviders = true,
    /// 关掉则不含 agent_skills / server_notes。默认开启，但让用户可关 ——
    /// 技能正文上限 8KB/条且无条数上限，重度用户备份可达 ~1MB。
    bool includeKnowledge = true,
  }) async {
    final sections = _sections(
      serverRepo: serverRepo,
      keyRepo: keyRepo,
      favCmdRepo: favCmdRepo,
      aiProviderRepo: aiProviderRepo,
      tunnelRepo: tunnelRepo,
      knownHostRepo: knownHostRepo,
      notesRepo: notesRepo,
      skillRepo: skillRepo,
    ).where((sec) {
      if (!includeAiProviders && sec.key == 'ai_providers') return false;
      if (!includeKnowledge &&
          (sec.key == 'server_notes' || sec.key == 'agent_skills')) {
        return false;
      }
      return true;
    }).toList();

    final payload = <String, dynamic>{
      'version': _kBackupFormatVersion,
      'exported_at': DateTime.now().toIso8601String(),
    };
    final counts = <String, int>{};
    for (final sec in sections) {
      final rows = await sec.exportRows();
      payload[sec.key] = rows;
      counts[sec.key] = rows.length;
    }
    payload['keybar'] = keybarSettings.exportToMap();
    payload['settings'] = _settingsToMap(terminalSettings);
    payload['checksum'] = _checksum(payload);

    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .substring(0, 19);
    final fileName = 'flyterm_backup_$ts.json';
    final targetDir = saveToCache ? await getTemporaryDirectory() : saveDir;
    await targetDir.create(recursive: true);
    final file = File('${targetDir.path}/$fileName');
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(payload));

    return ConfigBackupResult(counts: counts, filePath: file.path);
  }

  // ── Parse + validate ────────────────────────────────────────────────────────

  static Map<String, dynamic> _parseAndValidate(String content) {
    final Map<String, dynamic> payload = jsonDecode(content);
    final version = payload['version'] as int? ?? 1;
    if (version > _kBackupFormatVersion) {
      throw Exception('备份文件版本过新，请升级 FlyTerm 后再导入');
    }
    // v2+ carries an integrity checksum; v1 files have none — skip the check.
    final stored = payload['checksum'] as String?;
    if (stored != null && stored != _checksum(payload)) {
      throw Exception('备份文件已损坏（完整性校验失败），请重新导出');
    }
    return payload;
  }

  // ── Preview ──────────────────────────────────────────────────────────────────

  /// Parses [filePath] and computes new/skip counts without writing to DB.
  static Future<ConfigBackupPreview> previewImport({
    required String filePath,
    required Database db,
    required ServerRepository serverRepo,
    required SSHKeyRepository keyRepo,
    required FavoriteCommandRepository favCmdRepo,
    required AIProviderRepository aiProviderRepo,
    required TunnelRepository tunnelRepo,
    required KnownHostRepository knownHostRepo,
    required ServerNotesRepository notesRepo,
    required AgentSkillRepository skillRepo,
  }) async {
    final payload = _parseAndValidate(await File(filePath).readAsString());
    final sections = _sections(
      serverRepo: serverRepo,
      keyRepo: keyRepo,
      favCmdRepo: favCmdRepo,
      aiProviderRepo: aiProviderRepo,
      tunnelRepo: tunnelRepo,
      knownHostRepo: knownHostRepo,
      notesRepo: notesRepo,
      skillRepo: skillRepo,
    );

    final counts = <String, int>{};
    final skips = <String, int>{};
    var skillOverwriteCount = 0;
    for (final sec in sections) {
      final rows =
          (payload[sec.key] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final existing = await sec.existingIds(db);
      counts[sec.key] = rows.length;
      final clashes = rows.where((m) => existing.contains(sec.idOf(m))).length;
      if (sec.key == 'agent_skills') {
        // 技能的冲突语义是「覆盖」而非「跳过」—— 混进 skips 会让预览文案
        // 自相矛盾（显示「跳过」实际却覆盖了）。
        skillOverwriteCount = clashes;
      } else {
        skips[sec.key] = clashes;
      }
    }

    return ConfigBackupPreview(
      counts: counts,
      skips: skips,
      skillOverwriteCount: skillOverwriteCount,
      hasAiProviders: (counts['ai_providers'] ?? 0) > 0,
      hasKeybar: payload.containsKey('keybar'),
      hasSettings: payload.containsKey('settings'),
    );
  }

  // ── Import ──────────────────────────────────────────────────────────────────

  /// Imports from [filePath]. Skips records that already exist by identity.
  /// The keybar and terminal settings are always overwritten.
  /// 测试注入：命中这些 section 名时抛错，用于验证事务回滚。
  /// 没有它就只能靠手工构造坏 JSON 来触发中途失败，太脆。
  @visibleForTesting
  static List<String>? debugFailAtSections;

  static Future<ConfigBackupResult> importFromPath({
    required String filePath,
    required Database db,
    required ServerRepository serverRepo,
    required SSHKeyRepository keyRepo,
    required FavoriteCommandRepository favCmdRepo,
    required AIProviderRepository aiProviderRepo,
    required TunnelRepository tunnelRepo,
    required KnownHostRepository knownHostRepo,
    required ServerNotesRepository notesRepo,
    required AgentSkillRepository skillRepo,
    required KeybarSettings keybarSettings,
    required SecureStorageService storage,
    required TerminalSettings terminalSettings,
    /// false = 不覆盖 keybar 与终端设置（多设备场景：导入别人的备份不该无声
    /// 抹掉自己的主题与 KeyBar 布局）。
    bool overwriteAppearance = true,
    /// 导入完成后刷新内存态，让 UI 与 agent 索引立刻看到新数据。可选。
    AgentSkillManager? skillManager,
    ServerNotesManager? notesManager,
  }) async {
    final payload = _parseAndValidate(await File(filePath).readAsString());
    final sections = _sections(
      serverRepo: serverRepo,
      keyRepo: keyRepo,
      favCmdRepo: favCmdRepo,
      aiProviderRepo: aiProviderRepo,
      tunnelRepo: tunnelRepo,
      knownHostRepo: knownHostRepo,
      notesRepo: notesRepo,
      skillRepo: skillRepo,
    );

    final counts = <String, int>{};
    final skips = <String, int>{};
    var skillOverwriteCount = 0;
    var orphanNoteCount = 0;
    var rejectedNoteCount = 0;

    // DB 部分整体原子：逐条插入无事务时，中途失败会留下半导入状态，重试时
    // 已插入的又会被「跳过」判据认成已存在 —— 用户得到静止的半成品。
    //
    // 注意 keybar / settings 写的是 SecureStorage，**不在事务内**（跨存储
    // 介质，无法回避）。它们在事务提交后才应用，见下方。
    await db.transaction((txn) async {
      for (final sec in sections) {
        if (debugFailAtSections?.contains(sec.key) == true) {
          throw Exception('injected failure at ${sec.key}');
        }
        final rows =
            (payload[sec.key] as List?)?.cast<Map<String, dynamic>>() ?? [];
        final existing = await sec.existingIds(txn);
        int inserted = 0, skipped = 0;
        for (final m in rows) {
          final isClash = existing.contains(sec.idOf(m));
          if (isClash && sec.key == 'agent_skills') {
            // 技能冲突 = 覆盖，不计入 skipped
            skillOverwriteCount++;
          } else if (isClash) {
            skipped++;
            continue;
          }
          try {
            await sec.insertRowTxn(txn, m);
            inserted++;
          } on _NoteOrphan {
            orphanNoteCount++;
          } on _NoteRejected {
            rejectedNoteCount++;
          }
        }
        counts[sec.key] = inserted;
        skips[sec.key] = skipped;
      }
    });

    // 事务已提交 —— 以下写 SecureStorage，失败不会回滚 DB。这是跨存储介质的
    // 固有限制，如实报告而不假装原子。
    if (overwriteAppearance) {
      final keybar = payload['keybar'] as Map<String, dynamic>?;
      if (keybar != null) await keybarSettings.importFromMap(keybar);

      final s = payload['settings'] as Map<String, dynamic>?;
      if (s != null) await _applySettings(terminalSettings, s);
    }

    // 导入进来的技能/笔记要让 UI 与 agent 索引立即可见。
    await skillManager?.reload();
    await notesManager?.load();

    return ConfigBackupResult(
      counts: counts,
      skips: skips,
      orphanNoteCount: orphanNoteCount,
      rejectedNoteCount: rejectedNoteCount,
      skillOverwriteCount: skillOverwriteCount,
    );
  }
}
