import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

/// 导入原子性测试。
///
/// 此前 `importFromPath` 逐条 `insertRow` 无事务：中途失败会留下**半导入
/// 状态**（部分服务器进了库、部分没进），重试时已插入的又会被「跳过」判据
/// 认成已存在 —— 用户得到一个静止的半成品，且没有任何提示。
///
/// ⚠️ sqflite 的 `:memory:` 库带 `singleInstance=true`，两个未关闭的内存库会
/// 别名到同一个库。本文件每个设备用完即关。
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
    tmp = await Directory.systemTemp.createTemp('flyterm_atomic_');
  });
  tearDown(() async {
    ConfigBackupService.debugFailAtSections = null;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// 造一份含 2 台服务器的备份，返回文件路径。用完即关库。
  Future<String> seedBackup() async {
    final db = await AppDatabase.open(inMemory: true);
    final servers = ServerRepository(db);
    await servers.insert(const Server(
        id: 'a1',
        name: 'A1',
        host: 'h',
        port: 22,
        username: 'u',
        authType: 'password'));
    await servers.insert(const Server(
        id: 'a2',
        name: 'A2',
        host: 'h',
        port: 22,
        username: 'u',
        authType: 'password'));
    final path = (await ConfigBackupService.export(
      serverRepo: servers,
      keyRepo: SSHKeyRepository(db),
      favCmdRepo: FavoriteCommandRepository(db),
      aiProviderRepo: AIProviderRepository(db),
      tunnelRepo: TunnelRepository(db),
      knownHostRepo: KnownHostRepository(db),
      notesRepo: ServerNotesRepository(db),
      skillRepo: AgentSkillRepository(db),
      keybarSettings: KeybarSettings(),
      terminalSettings: TerminalSettings(SecureStorageService()),
      saveDir: tmp,
    ))
        .filePath!;
    await db.close();
    return path;
  }

  test('导入中途失败时 DB 无部分写入（servers 全回滚）', () async {
    final path = await seedBackup();

    final bDb = await AppDatabase.open(inMemory: true);
    addTearDown(bDb.close);
    final bServers = ServerRepository(bDb);

    // tunnels 排在 servers 之后 —— 若没有事务，servers 已经落库了。
    ConfigBackupService.debugFailAtSections = ['tunnels'];

    await expectLater(
      ConfigBackupService.importFromPath(
        filePath: path,
        db: bDb,
        serverRepo: bServers,
        keyRepo: SSHKeyRepository(bDb),
        favCmdRepo: FavoriteCommandRepository(bDb),
        aiProviderRepo: AIProviderRepository(bDb),
        tunnelRepo: TunnelRepository(bDb),
        knownHostRepo: KnownHostRepository(bDb),
        notesRepo: ServerNotesRepository(bDb),
        skillRepo: AgentSkillRepository(bDb),
        keybarSettings: KeybarSettings(),
        storage: SecureStorageService(),
        terminalSettings: TerminalSettings(SecureStorageService()),
      ),
      throwsException,
    );

    expect(await bServers.findAll(), isEmpty,
        reason: '事务必须回滚掉 servers 的部分写入');
  });

  test('失败后 keybar / settings 未被触碰', () async {
    final path = await seedBackup();

    final bDb = await AppDatabase.open(inMemory: true);
    addTearDown(bDb.close);
    final storage = SecureStorageService();
    final settings = TerminalSettings(storage);
    await settings.load();
    await settings.setFontSize(19);
    final keybar = KeybarSettings();
    await keybar.seedIfEmpty();
    final beforeSize = settings.fontSize;
    final beforeItems = keybar.items.length;

    ConfigBackupService.debugFailAtSections = ['tunnels'];

    await expectLater(
      ConfigBackupService.importFromPath(
        filePath: path,
        db: bDb,
        serverRepo: ServerRepository(bDb),
        keyRepo: SSHKeyRepository(bDb),
        favCmdRepo: FavoriteCommandRepository(bDb),
        aiProviderRepo: AIProviderRepository(bDb),
        tunnelRepo: TunnelRepository(bDb),
        knownHostRepo: KnownHostRepository(bDb),
        notesRepo: ServerNotesRepository(bDb),
        skillRepo: AgentSkillRepository(bDb),
        keybarSettings: keybar,
        storage: storage,
        terminalSettings: settings,
      ),
      throwsException,
    );

    // keybar/settings 写 SecureStorage，在事务提交后才应用 —— 事务失败就不该碰。
    expect(settings.fontSize, beforeSize);
    expect(keybar.items.length, beforeItems);
  });

  test('overwriteAppearance=false 时不覆盖外观设置', () async {
    final path = await seedBackup();

    final bDb = await AppDatabase.open(inMemory: true);
    addTearDown(bDb.close);
    final storage = SecureStorageService();
    final settings = TerminalSettings(storage);
    await settings.load();
    await settings.setFontSize(19);

    final res = await ConfigBackupService.importFromPath(
      filePath: path,
      db: bDb,
      serverRepo: ServerRepository(bDb),
      keyRepo: SSHKeyRepository(bDb),
      favCmdRepo: FavoriteCommandRepository(bDb),
      aiProviderRepo: AIProviderRepository(bDb),
      tunnelRepo: TunnelRepository(bDb),
      knownHostRepo: KnownHostRepository(bDb),
      notesRepo: ServerNotesRepository(bDb),
      skillRepo: AgentSkillRepository(bDb),
      keybarSettings: KeybarSettings(),
      storage: storage,
      terminalSettings: settings,
      overwriteAppearance: false,
    );

    expect(res.serverCount, 2, reason: '记录仍应导入');
    expect(settings.fontSize, 19, reason: '外观设置应保持用户当前值');
  });
}
