import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/ssh_key_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late SSHKeyRepository repo;
  late SecureStorageService store;
  late AppControlService svc;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    repo = SSHKeyRepository(db);
    store = SecureStorageService();
    svc = AppControlService(
      settings: TerminalSettings(SecureStorageService()),
      keys: repo,
      storage: store,
    );
  });

  tearDown(() async => db.close());

  group('generateSshKey', () {
    test('ed25519 生成并落库', () async {
      final r = await svc.generateSshKey(name: 'laptop');
      expect(r.ok, isTrue);

      final all = await repo.findAll();
      expect(all, hasLength(1));
      expect(all.single.name, 'laptop');
      expect(all.single.type, 'ed25519');
      expect(all.single.publicKey, startsWith('ssh-ed25519 '));
    });

    test('rsa 也能生成', () async {
      final r = await svc.generateSshKey(name: 'old-server', type: 'rsa');
      expect(r.ok, isTrue);
      expect((await repo.findAll()).single.type, 'rsa');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('私钥进了 keystore', () async {
      await svc.generateSshKey(name: 'laptop');
      final id = (await repo.findAll()).single.id;
      final pem = await store.loadPrivateKey(id);
      expect(pem, isNotNull);
      expect(pem, contains('PRIVATE KEY'));
    });

    // 这是整个工具存在的前提：私钥不能出现在任何会流向模型的地方。
    test('私钥不出现在 AppChange 里', () async {
      final r = await svc.generateSshKey(name: 'laptop');
      final c = r.change!;
      for (final v in [c.oldValue, c.newValue, c.field, c.toolName]) {
        expect('$v', isNot(contains('PRIVATE KEY')),
            reason: '私钥泄漏进了变更记录，它会被渲染进卡片');
        expect('$v', isNot(contains('BEGIN OPENSSH')));
      }
    });

    test('重名被拒且不生成', () async {
      await svc.generateSshKey(name: 'laptop');
      final r = await svc.generateSshKey(name: 'laptop');
      expect(r.ok, isFalse);
      expect(r.error, contains('already exists'));
      expect(await repo.findAll(), hasLength(1));
    });

    test('非法类型被拒', () async {
      final r = await svc.generateSshKey(name: 'x', type: 'dsa');
      expect(r.ok, isFalse);
      expect(await repo.findAll(), isEmpty);
    });

    test('空名字被拒', () async {
      final r = await svc.generateSshKey(name: '  ');
      expect(r.ok, isFalse);
    });

    test('撤销把密钥和私钥一起删掉', () async {
      await svc.generateSshKey(name: 'laptop');
      final id = (await repo.findAll()).single.id;

      await svc.changeLog.undoAll();

      expect(await repo.findAll(), isEmpty);
      expect(await store.loadPrivateKey(id), isNull,
          reason: '撤销只删了条目，私钥留在 keystore 里成了孤儿');
    });
  });

  group('listSshKeys', () {
    test('只给名字/类型/公钥', () async {
      await svc.generateSshKey(name: 'laptop');
      final rows = (await svc.listSshKeys())!;
      expect(rows.single.keys.toSet(), {'name', 'type', 'public_key'});
    });

    test('结果里没有私钥 —— 没有任何读取路径', () async {
      await svc.generateSshKey(name: 'laptop');
      final rows = (await svc.listSshKeys())!;
      expect('$rows', isNot(contains('PRIVATE KEY')));
    });

    test('没注入 repo 时回 null 而不是空列表', () async {
      final bare = AppControlService(
        settings: TerminalSettings(SecureStorageService()),
      );
      expect(await bare.listSshKeys(), isNull);
    });
  });
}
