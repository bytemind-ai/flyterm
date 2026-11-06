import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/data/config_backup_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/keybar_settings.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/data/repositories/ai_provider_repository.dart';
import 'package:flyterm/data/repositories/favorite_command_repository.dart';
import 'package:flyterm/data/repositories/known_host_repository.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/repositories/ssh_key_repository.dart';
import 'package:flyterm/data/repositories/tunnel_repository.dart';

/// 备份的 AI 知识资产（agent_skills / server_notes）往返测试。
///
/// 这两张表 2026-10-07 之前完全不在备份里：用户在 A 设备攒的技能与笔记，
/// 换设备全丢。它们比开关值重要得多 —— 是**内容**。
///
/// ⚠️ sqflite 以 `:memory:` 开库时 `singleInstance=true`，**两个未关闭的
/// 内存库会别名到同一个库**。需要「另一台干净设备」时必须先关掉前一个，
/// 否则会看到对方的行（本文件早期就在这上面踩过坑：孤儿笔记判定被误判成
/// 「已存在而跳过」）。
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

  _Device._(
      this.db,
      this.serverRepo,
      this.keyRepo,
      this.favCmdRepo,
      this.aiRepo,
      this.tunnelRepo,
      this.knownHostRepo,
      this.skillRepo,
      this.notesRepo,
      this.keybar,
      this.settings,
      this.storage);

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

Future<String> _exportOf(_Device d, Directory tmp,
    {bool includeKnowledge = true, bool includeAiProviders = true}) async {
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
    includeKnowledge: includeKnowledge,
    includeAiProviders: includeAiProviders,
  );
  return res.filePath!;
}

Future<ConfigBackupResult> _importInto(_Device d, String path) =>
    ConfigBackupService.importFromPath(
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

const _server = Server(
  id: 'srv-1',
  name: 'prod',
  host: 'h',
  port: 22,
  username: 'u',
  authType: 'password',
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

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flyterm_bk_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  // ── server_notes ──────────────────────────────────────────────────────────

  test('server_notes 往返：笔记随服务器一起迁移', () async {
    final a = await _Device.create();
    addTearDown(a.db.close);
    await a.serverRepo.insert(_server);
    await a.notesRepo.upsert(serverId: 'srv-1', body: '日志在 /data/logs');

    final path = await _exportOf(a, tmp);

    final b = await _Device.create();
    addTearDown(b.db.close);
    await _importInto(b, path);

    expect(await b.notesRepo.bodyOf('srv-1'), '日志在 /data/logs');
  });

  test('孤儿笔记被跳过并计入 orphanNoteCount', () async {
    // A 设备：server + 笔记 → 导出
    final a = await _Device.create();
    await a.serverRepo.insert(_server);
    await a.notesRepo.upsert(serverId: 'srv-1', body: 'note');
    final path = await _exportOf(a, tmp);
    await a.db.close(); // ⚠️ 必须先关，否则下一个内存库会别名到它

    // 造一个真孤儿：备份里有笔记但 server 不在里面。
    final raw =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    raw['servers'] = <dynamic>[];
    raw.remove('checksum');
    raw['checksum'] = ConfigBackupService.debugChecksum(raw);
    await File(path).writeAsString(jsonEncode(raw));

    final b = await _Device.create();
    addTearDown(b.db.close);
    final res = await _importInto(b, path);

    expect(res.orphanNoteCount, 1, reason: 'server 不存在 → 笔记应被跳过');
    expect(await b.notesRepo.bodyOf('srv-1'), isNull,
        reason: '孤儿笔记不该被插入');
  });

  test('includeKnowledge=false 时不导出 notes/skills', () async {
    final a = await _Device.create();
    addTearDown(a.db.close);
    await a.notesRepo.upsert(serverId: 's1', body: 'note');
    final path = await _exportOf(a, tmp, includeKnowledge: false);

    final raw =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    expect(raw.containsKey('server_notes'), isFalse);
    expect(raw.containsKey('agent_skills'), isFalse);
  });

  test('includeAiProviders=false 时不导出 ai_providers', () async {
    final a = await _Device.create();
    addTearDown(a.db.close);
    final path = await _exportOf(a, tmp, includeAiProviders: false);

    final raw =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    expect(raw.containsKey('ai_providers'), isFalse);
  });

  // ── agent_skills ──────────────────────────────────────────────────────────

  test('agent_skills 往返，body 完整', () async {
    final a = await _Device.create();
    addTearDown(a.db.close);
    await a.skillRepo.upsert(
      name: '重启服务',
      description: '重启 systemd 服务',
      body: 'systemctl restart <name>',
      source: SkillSource.manual,
    );
    final path = await _exportOf(a, tmp);

    final b = await _Device.create();
    addTearDown(b.db.close);
    await _importInto(b, path);

    final s = (await b.skillRepo.all()).firstWhere((e) => e.name == '重启服务');
    expect(s.body, 'systemctl restart <name>');
    expect(s.description, '重启 systemd 服务');
  });

  test('同名技能导入时覆盖（skillOverwriteCount 计数）', () async {
    final a = await _Device.create();
    addTearDown(a.db.close);
    await a.skillRepo.upsert(
        name: 'S',
        description: 'from A',
        body: 'A-body',
        source: SkillSource.manual);
    final path = await _exportOf(a, tmp);

    final b = await _Device.create();
    addTearDown(b.db.close);
    await b.skillRepo.upsert(
        name: 'S',
        description: 'from B',
        body: 'B-body',
        source: SkillSource.manual);

    final res = await _importInto(b, path);
    expect(res.skillOverwriteCount, 1,
        reason: '技能的冲突语义是覆盖，应单列计数而非计入 skips');

    final s = (await b.skillRepo.all()).firstWhere((e) => e.name == 'S');
    expect(s.body, 'A-body', reason: '导入应以备份为准（覆盖）');
  });

  test('last_used_at / hit_count / id 不被导出', () async {
    final a = await _Device.create();
    addTearDown(a.db.close);
    await a.skillRepo.upsert(
        name: 'S', description: 'd', body: 'b', source: SkillSource.manual);
    await a.skillRepo.markUsed('S');
    final path = await _exportOf(a, tmp);

    final raw =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    final rows = (raw['agent_skills'] as List).cast<Map<String, dynamic>>();
    expect(rows, isNotEmpty);
    expect(rows.first.containsKey('last_used_at'), isFalse,
        reason: '使用信号不该跨设备 —— 会污染索引名额竞争');
    expect(rows.first.containsKey('hit_count'), isFalse);
    expect(rows.first.containsKey('id'), isFalse,
        reason: '自增 id 跨设备无意义，去重判据用 name');
  });
}
