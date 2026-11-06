import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/server_notes_manager.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late ServerRepository repo;
  late AppControlService svc;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    repo = ServerRepository(db);
    svc = AppControlService(
      settings: TerminalSettings(SecureStorageService()),
      servers: repo,
    );
  });

  tearDown(() async => db.close());

  group('createServer', () {
    test('建一条并能读回', () async {
      final r = await svc.createServer(
          name: 'web', host: '10.0.0.5', username: 'root');
      expect(r.ok, isTrue);

      final all = await repo.findAll();
      expect(all, hasLength(1));
      expect(all.single.name, 'web');
      expect(all.single.port, 22, reason: '端口默认值应为 22');
    });

    test('authType 固定 password 且没有凭据 —— AI 不碰密钥', () async {
      await svc.createServer(name: 'web', host: '10.0.0.5', username: 'root');
      final s = (await repo.findAll()).single;
      expect(s.authType, 'password');
      expect(s.keyId, isNull);
    });

    test('重名被拒且不覆盖已有条目', () async {
      await svc.createServer(name: 'web', host: '10.0.0.5', username: 'root');
      final r = await svc.createServer(
          name: 'web', host: '1.2.3.4', username: 'admin');
      expect(r.ok, isFalse);
      expect(r.error, contains('already exists'));

      final all = await repo.findAll();
      expect(all, hasLength(1));
      expect(all.single.host, '10.0.0.5', reason: '已有条目被覆盖了');
    });

    test('端口越界被拒', () async {
      final r = await svc.createServer(
          name: 'web', host: '10.0.0.5', username: 'root', port: 99999);
      expect(r.ok, isFalse);
      expect(await repo.findAll(), isEmpty);
    });

    test('空字段被拒', () async {
      final r =
          await svc.createServer(name: 'web', host: '  ', username: 'root');
      expect(r.ok, isFalse);
      expect(await repo.findAll(), isEmpty);
    });

    test('撤销把新建的条目删掉', () async {
      await svc.createServer(name: 'web', host: '10.0.0.5', username: 'root');
      await svc.changeLog.undoAll();
      expect(await repo.findAll(), isEmpty);
    });
  });

  group('updateServer', () {
    test('改 host 并可撤销回原值', () async {
      await svc.createServer(name: 'web', host: '10.0.0.5', username: 'root');
      svc.changeLog.clear();

      final r = await svc.updateServer(name: 'web', host: '10.0.0.9');
      expect(r.ok, isTrue);
      expect((await repo.findAll()).single.host, '10.0.0.9');

      await svc.changeLog.undoAll();
      expect((await repo.findAll()).single.host, '10.0.0.5');
    });

    test('改不存在的服务器回明确错误', () async {
      final r = await svc.updateServer(name: 'nope', host: 'x');
      expect(r.ok, isFalse);
      expect(r.error, contains('No server named'));
    });

    test('端口越界被拒且不落库', () async {
      await svc.createServer(name: 'web', host: '10.0.0.5', username: 'root');
      final r = await svc.updateServer(name: 'web', port: 0);
      expect(r.ok, isFalse);
      expect((await repo.findAll()).single.port, 22);
    });
  });

  group('deleteServer', () {
    test('删掉并可撤销 —— 条目原样回来', () async {
      await svc.createServer(
          name: 'web', host: '10.0.0.5', username: 'root', groupName: 'prod');
      svc.changeLog.clear();

      final r = await svc.deleteServer('web');
      expect(r.ok, isTrue);
      expect(await repo.findAll(), isEmpty);

      await svc.changeLog.undoAll();
      final back = (await repo.findAll()).single;
      expect(back.name, 'web');
      expect(back.host, '10.0.0.5');
      expect(back.groupName, 'prod');
    });

    test('删不存在的回明确错误', () async {
      final r = await svc.deleteServer('nope');
      expect(r.ok, isFalse);
      expect(r.error, contains('No server named'));
    });

    // I2：deleteServer 的 doc 一直写着「完全可撤销」，但 repo.delete 在事务
    // 里连带删掉的 server_notes 行，undo 只 repo.insert 了服务器行，笔记就
    // 丢了——撤销之后标题正常、内容消失，比「撤销失败」更隐蔽。这两个测试
    // 锁住：(a) 删除时机器笔记缓存要跟着失效，不能留到冷启动才刷新；
    // (b) 撤销要把笔记也救回来，不能只救服务器行。
    group('I2：删除要带上机器笔记，撤销也要带上', () {
      late ServerNotesManager notes;

      setUp(() {
        notes = ServerNotesManager(ServerNotesRepository(db));
        svc = AppControlService(
          settings: TerminalSettings(SecureStorageService()),
          servers: repo,
          serverNotes: notes,
        );
      });

      test('删除服务器后，内存里的笔记缓存立刻失效', () async {
        await svc.createServer(name: 'web', host: '10.0.0.5', username: 'root');
        final id = (await repo.findAll()).single.id;
        await notes.replaceNote(serverId: id, body: '这是一条机器笔记');
        expect(notes.noteFor(id), '这是一条机器笔记');

        final r = await svc.deleteServer('web');
        expect(r.ok, isTrue);
        expect(notes.noteFor(id), isNull,
            reason: 'repo.delete 已经把 server_notes 行删了，'
                'Manager 的内存缓存不主动失效就会继续显示这条笔记');
      });

      test('撤销删除后，笔记内容也要原样回来，不能只剩服务器行', () async {
        await svc.createServer(name: 'web', host: '10.0.0.5', username: 'root');
        final id = (await repo.findAll()).single.id;
        await notes.replaceNote(serverId: id, body: '这是一条机器笔记');
        svc.changeLog.clear();

        await svc.deleteServer('web');
        expect(notes.noteFor(id), isNull);

        await svc.changeLog.undoAll();
        expect((await repo.findAll()).single.name, 'web');
        expect(notes.noteFor(id), '这是一条机器笔记',
            reason: 'undo 只 repo.insert(old) 救回服务器行的话，笔记永久丢失，'
                '与 deleteServer 文档里「完全可撤销」的承诺不符');
      });
    });
  });

  // 这组守的是 spec 层面的边界：凭据字段压根不出现在工具参数里。
  // 运行时判断可以被绕过或被将来的改动绕开，schema 里没有就是没有。
  group('凭据边界 —— schema 层面', () {
    test('server_entry_create 的参数不含任何凭据字段', () {
      final props =
          serverEntryCreateToolSpec.parameters['properties'] as Map;
      for (final forbidden in [
        'password',
        'passwd',
        'key',
        'key_id',
        'keyId',
        'private_key',
        'secret',
      ]) {
        expect(props.containsKey(forbidden), isFalse,
            reason: '$forbidden 出现在 server_entry_create 的参数里');
      }
    });

    test('server_entry_update 同样不含凭据字段', () {
      final props =
          serverEntryUpdateToolSpec.parameters['properties'] as Map;
      for (final forbidden in ['password', 'key', 'key_id', 'private_key']) {
        expect(props.containsKey(forbidden), isFalse,
            reason: '$forbidden 出现在 server_entry_update 的参数里');
      }
    });
  });
}
