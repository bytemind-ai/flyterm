import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/data/config_backup_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/keybar_settings.dart';
import 'package:flyterm/data/keybar_config.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/models/ssh_key.dart';
import 'package:flyterm/data/models/favorite_command.dart';
import 'package:flyterm/data/models/ai_provider_config.dart';
import 'package:flyterm/data/models/tunnel_config.dart';
import 'package:flyterm/tunnel/tunnel_entry.dart' show TunnelDirection;
import 'package:flyterm/data/models/known_host.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/repositories/ssh_key_repository.dart';
import 'package:flyterm/data/repositories/favorite_command_repository.dart';
import 'package:flyterm/data/repositories/ai_provider_repository.dart';
import 'package:flyterm/data/repositories/tunnel_repository.dart';
import 'package:flyterm/data/repositories/known_host_repository.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';
import 'package:flyterm/ui/terminal/terminal_themes.dart';

/// Repos + settings backed by one in-memory DB. NOTE: sqflite opens `:memory:`
/// with singleInstance=true, so two open DBs with the same path alias the same
/// database — a fresh DB is only obtained after the previous one is closed.
class _Device {
  final Database db;
  final ServerRepository serverRepo;
  final SSHKeyRepository keyRepo;
  final FavoriteCommandRepository favCmdRepo;
  final AIProviderRepository aiRepo;
  final TunnelRepository tunnelRepo;
  final KnownHostRepository knownHostRepo;
  final AgentSkillRepository skillRepo;
  final ServerNotesRepository notesRepo;
  final KeybarSettings keybar;
  final TerminalSettings settings;
  final SecureStorageService storage;

  _Device._(this.db, this.serverRepo, this.keyRepo, this.favCmdRepo, this.aiRepo,
      this.tunnelRepo, this.knownHostRepo, this.skillRepo, this.notesRepo,
      this.keybar, this.settings, this.storage);

  static Future<_Device> create() async {
    final db = await AppDatabase.open(inMemory: true);
    final storage = SecureStorageService();
    final settings = TerminalSettings(storage);
    await settings.load();
    final keybar = KeybarSettings();
    await keybar.seedIfEmpty();
    return _Device._(
      db,
      ServerRepository(db),
      SSHKeyRepository(db),
      FavoriteCommandRepository(db),
      AIProviderRepository(db),
      TunnelRepository(db),
      KnownHostRepository(db),
      AgentSkillRepository(db),
      ServerNotesRepository(db),
      keybar,
      settings,
      storage,
    );
  }
}

Future<String> _exportOf(_Device d, Directory tmp) async {
  final res = await ConfigBackupService.export(
    serverRepo: d.serverRepo,
    keyRepo: d.keyRepo,
    favCmdRepo: d.favCmdRepo,
    aiProviderRepo: d.aiRepo,
    tunnelRepo: d.tunnelRepo,
    knownHostRepo: d.knownHostRepo,
    notesRepo: d.notesRepo,
    skillRepo: d.skillRepo,
    keybarSettings: d.keybar,
    terminalSettings: d.settings,
    saveDir: tmp,
  );
  return res.filePath!;
}

Future<void> _importInto(_Device d, String path) => ConfigBackupService.importFromPath(
      filePath: path,
      db: d.db,
      serverRepo: d.serverRepo,
      keyRepo: d.keyRepo,
      favCmdRepo: d.favCmdRepo,
      aiProviderRepo: d.aiRepo,
      tunnelRepo: d.tunnelRepo,
      knownHostRepo: d.knownHostRepo,
      notesRepo: d.notesRepo,
      skillRepo: d.skillRepo,
      keybarSettings: d.keybar,
      storage: d.storage,
      terminalSettings: d.settings,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('records round-trip across a fresh DB (all 6 sections)', () async {
    final tmp = await Directory.systemTemp.createTemp('flyterm_backup_a_');
    addTearDown(() => tmp.delete(recursive: true));

    // Source device: one record per section.
    final src = await _Device.create();
    await src.keyRepo.insert(const SSHKey(
        id: 'k1', name: 'MyKey', type: 'ed25519', publicKey: 'ssh-ed25519 AAAA'));
    await src.serverRepo.insert(const Server(
        id: 's1', name: 'Prod', host: 'example.com', port: 22, username: 'root',
        authType: 'key', keyId: 'k1'));
    await src.favCmdRepo
        .insert(FavoriteCommand.create(name: 'll', command: 'ls -la'));
    await src.aiRepo.insert(const AIProviderConfig(
        id: 'ai1', name: 'Claude', type: 'anthropic', model: 'claude-opus-4-8'));
    await src.tunnelRepo.insert(const TunnelConfig(
        id: 't1', serverId: 's1', direction: TunnelDirection.local,
        localPort: 8080, remoteHost: '127.0.0.1', remotePort: 80,
        label: 'web', autoStart: false));
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    await src.knownHostRepo.save(KnownHost(
        host: 'example.com', port: 22, keyType: 'ssh-ed25519',
        fingerprintMd5: 'aa:bb:cc', firstSeen: now, lastSeen: now));

    final path = await _exportOf(src, tmp);
    // Close src so the next :memory: open is a distinct, empty database.
    await src.db.close();

    // Destination device: fresh + empty.
    final dst = await _Device.create();
    addTearDown(dst.db.close);

    final preview = await ConfigBackupService.previewImport(
      filePath: path,
      db: dst.db,
      serverRepo: dst.serverRepo,
      keyRepo: dst.keyRepo,
      favCmdRepo: dst.favCmdRepo,
      aiProviderRepo: dst.aiRepo,
      tunnelRepo: dst.tunnelRepo,
      knownHostRepo: dst.knownHostRepo,
      notesRepo: dst.notesRepo,
      skillRepo: dst.skillRepo,
    );
    expect(preview.serverCount, 1);
    expect(preview.serverSkip, 0);
    expect(preview.knownHostCount, 1);
    expect(preview.hasKeybar, true);
    expect(preview.hasSettings, true);
    expect(preview.hasAiProviders, true);

    await _importInto(dst, path);

    expect((await dst.serverRepo.findAll()).map((s) => s.id), contains('s1'));
    expect((await dst.keyRepo.findAll()).map((k) => k.id), contains('k1'));
    expect((await dst.favCmdRepo.findAll()).length, 1);
    expect((await dst.aiRepo.findAll()).map((p) => p.id), contains('ai1'));
    expect((await dst.tunnelRepo.findAll()).map((t) => t.id), contains('t1'));
    expect((await dst.knownHostRepo.findAll()).length, 1);
  });

  test('settings + keybar round-trip (import overwrites current values)',
      () async {
    final tmp = await Directory.systemTemp.createTemp('flyterm_backup_b_');
    addTearDown(() => tmp.delete(recursive: true));

    final d = await _Device.create();
    addTearDown(d.db.close);

    // V1: the values we want to back up (cover every exported field).
    await d.settings.setFontSize(16.0);
    await d.settings.setTerminalTheme(AppTerminalTheme.dracula);
    await d.settings.setDangerousCommandGuard(false);
    await d.settings.setFontFamily('CourierPrime');
    await d.settings.setLineHeight(1.5);
    await d.settings.setCursorStyle(TerminalCursorStyle.underline);
    await d.settings.setKeyboardTrigger(KeyboardTriggerMode.doubleTap);
    await d.settings.setSshCompression(false);
    await d.settings.setFetEnabled(false);
    await d.settings.setFetOpacity(0.75);
    // iTerm2 对齐项：这两个只在 key 集合护栏里被验证过「存在」，
    // 值能不能真的往返要靠这条。
    await d.settings.setCursorBlink(false);
    await d.settings.setSelectionColor(const Color(0x80528BFF));
    await d.keybar.add(const KeyBarItem(
        id: 'custom1', label: 'GIT', sequence: [TextToken('git status')],
        sticky: false, repeatable: false));

    final path = await _exportOf(d, tmp);

    // V2: sentinel changes AFTER export — import must overwrite these back.
    await d.settings.setFontSize(9.0);
    await d.settings.setTerminalTheme(AppTerminalTheme.monokai);
    await d.settings.setFontFamily('JetBrainsMono');
    await d.settings.setKeyboardTrigger(KeyboardTriggerMode.singleTap);
    await d.settings.setSshCompression(true);
    await d.settings.setFetEnabled(true);
    // 归到默认值，这样 import 后能确实看出是被导入覆盖回来的。
    await d.settings.setCursorBlink(true);
    await d.settings.setSelectionColor(null);
    await d.keybar.restoreDefaults(); // drops custom1
    expect(d.keybar.items.any((i) => i.id == 'custom1'), false);

    await _importInto(d, path);

    // Back to V1.
    expect(d.settings.fontSize, 16.0);
    expect(d.settings.terminalTheme, AppTerminalTheme.dracula);
    expect(d.settings.dangerousCommandGuard, false);
    expect(d.settings.fontFamily, 'CourierPrime');
    expect(d.settings.lineHeight, 1.5);
    expect(d.settings.cursorStyle, TerminalCursorStyle.underline);
    expect(d.settings.keyboardTrigger, KeyboardTriggerMode.doubleTap);
    expect(d.settings.sshCompression, false);
    expect(d.settings.fetEnabled, false);
    expect(d.settings.fetOpacity, 0.75);
    // alpha 必须完整保留 —— 存成 6 位 hex 会在这里变不透明。
    expect(d.settings.cursorBlink, false);
    expect(d.settings.selectionColor, const Color(0x80528BFF));
    expect(d.keybar.items.any((i) => i.id == 'custom1'), true);
  });

  test('importing the same file twice skips everything the second time',
      () async {
    final tmp = await Directory.systemTemp.createTemp('flyterm_backup_c_');
    addTearDown(() => tmp.delete(recursive: true));

    final d = await _Device.create();
    addTearDown(d.db.close);
    await d.serverRepo.insert(const Server(
        id: 's1', name: 'A', host: 'h', port: 22, username: 'u',
        authType: 'password'));

    final path = await _exportOf(d, tmp);

    // Import into the same device — the server already exists → skipped.
    final preview = await ConfigBackupService.previewImport(
      filePath: path,
      db: d.db,
      serverRepo: d.serverRepo,
      keyRepo: d.keyRepo,
      favCmdRepo: d.favCmdRepo,
      aiProviderRepo: d.aiRepo,
      tunnelRepo: d.tunnelRepo,
      knownHostRepo: d.knownHostRepo,
      notesRepo: d.notesRepo,
      skillRepo: d.skillRepo,
    );
    expect(preview.serverCount, 1);
    expect(preview.serverSkip, 1);
    expect(preview.totalNew, 0);
  });

  test('a tampered backup fails the checksum guard', () async {
    final tmp = await Directory.systemTemp.createTemp('flyterm_backup_d_');
    addTearDown(() => tmp.delete(recursive: true));

    final d = await _Device.create();
    addTearDown(d.db.close);
    await d.serverRepo.insert(const Server(
        id: 's1', name: 'A', host: 'h', port: 22, username: 'u',
        authType: 'password'));
    final path = await _exportOf(d, tmp);

    // Tamper: flip a server field without recomputing the checksum.
    final file = File(path);
    final payload = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    (payload['servers'] as List)[0]['host'] = 'evil.com';
    await file.writeAsString(jsonEncode(payload));

    expect(
      () => ConfigBackupService.previewImport(
        filePath: path,
        db: d.db,
        serverRepo: d.serverRepo,
        keyRepo: d.keyRepo,
        favCmdRepo: d.favCmdRepo,
        aiProviderRepo: d.aiRepo,
        tunnelRepo: d.tunnelRepo,
        knownHostRepo: d.knownHostRepo,
        notesRepo: d.notesRepo,
        skillRepo: d.skillRepo,
      ),
      throwsA(isA<Exception>()),
    );
  });
}
