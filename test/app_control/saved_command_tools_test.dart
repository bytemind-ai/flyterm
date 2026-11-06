import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/ai_command_manager.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/favorite_command_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late FavoriteCommandRepository repo;
  late AiCommandManager mgr;
  late AppControlService svc;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    repo = FavoriteCommandRepository(db);
    mgr = AiCommandManager(repo);
    await mgr.reload();
    svc = AppControlService(
      settings: TerminalSettings(SecureStorageService()),
      commands: repo,
      commandManager: mgr,
    );
  });

  tearDown(() async => db.close());

  test('存一条并能列出', () async {
    final r = await svc.saveCommand(name: 'logs', command: 'tail -f a.log');
    expect(r.ok, isTrue);

    final rows = svc.listCommands()!;
    expect(rows.single['name'], 'logs');
    expect(rows.single['command'], 'tail -f a.log');
  });

  test('存完立刻能被 run_saved_command 找到 —— reload 没漏', () async {
    await svc.saveCommand(name: 'logs', command: 'tail -f a.log');
    expect(mgr.byName('logs'), isNotNull,
        reason: '存了但 manager 没 reload，run_saved_command 会说找不到');
  });

  test('重名被拒', () async {
    await svc.saveCommand(name: 'logs', command: 'a');
    final r = await svc.saveCommand(name: 'logs', command: 'b');
    expect(r.ok, isFalse);
    expect(svc.listCommands(), hasLength(1));
  });

  test('空字段被拒', () async {
    final r = await svc.saveCommand(name: 'x', command: '  ');
    expect(r.ok, isFalse);
    expect(svc.listCommands(), isEmpty);
  });

  test('撤销把新存的删掉', () async {
    await svc.saveCommand(name: 'logs', command: 'a');
    await svc.changeLog.undoAll();
    expect(svc.listCommands(), isEmpty);
    expect(mgr.byName('logs'), isNull);
  });

  test('删掉并可撤销 —— 命令原样回来', () async {
    await svc.saveCommand(name: 'logs', command: 'tail -f a.log');
    svc.changeLog.clear();

    final r = await svc.deleteCommand('logs');
    expect(r.ok, isTrue);
    expect(svc.listCommands(), isEmpty);

    await svc.changeLog.undoAll();
    expect(svc.listCommands()!.single['command'], 'tail -f a.log');
  });

  test('删不存在的回明确错误', () async {
    final r = await svc.deleteCommand('nope');
    expect(r.ok, isFalse);
    expect(r.error, contains('No saved command named'));
  });

  test('没注入依赖时回 null 而不是空列表', () async {
    final bare =
        AppControlService(settings: TerminalSettings(SecureStorageService()));
    expect(bare.listCommands(), isNull);
  });
}
