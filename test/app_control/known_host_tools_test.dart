import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/app_permission.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/known_host.dart';
import 'package:flyterm/data/repositories/known_host_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late KnownHostRepository repo;
  late AppControlService svc;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    repo = KnownHostRepository(db);
    svc = AppControlService(
      settings: TerminalSettings(SecureStorageService()),
      knownHosts: repo,
    );
  });

  tearDown(() async => db.close());

  Future<void> seed({String host = 'prod.example.com'}) => repo.insert(
        KnownHost(
          host: host,
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprintMd5: 'aa:bb:cc',
          firstSeen: DateTime(2026, 1, 1),
          lastSeen: DateTime(2026, 1, 2),
        ),
      );

  test('列出主机与指纹 —— 这是「为什么连不上」的判断依据', () async {
    await seed();
    final rows = (await svc.listKnownHosts())!;
    expect(rows.single['host'], 'prod.example.com');
    expect(rows.single['fingerprint'], 'aa:bb:cc');
    expect(rows.single['key_type'], 'ssh-ed25519');
  });

  test('忘记一台主机', () async {
    await seed();
    final r = await svc.forgetKnownHost(
        host: 'prod.example.com', keyType: 'ssh-ed25519');
    expect(r.ok, isTrue);
    expect(await svc.listKnownHosts(), isEmpty);
  });

  test('忘记不存在的回明确错误', () async {
    final r = await svc.forgetKnownHost(host: 'nope', keyType: 'ssh-rsa');
    expect(r.ok, isFalse);
    expect(r.error, contains('No trusted key'));
  });

  // 撤销意味着把一个指纹重新标成「可信」，而那条信任本该由用户在看到
  // 指纹之后亲自给出。
  test('不可撤销 —— undo 为 null', () async {
    await seed();
    final r = await svc.forgetKnownHost(
        host: 'prod.example.com', keyType: 'ssh-ed25519');
    expect(r.change!.undo, isNull,
        reason: '自动恢复信任等于替用户做了信任决定');
  });

  test('在硬清单里 —— bypass 档也要审批', () {
    expect(kAppHardApproval, contains('known_host_forget'));
    final r =
        checkAppControl('known_host_forget', mode: PermissionMode.bypass);
    expect(r.decision, ToolDecision.needApproval);
  });

  test('没注入 repo 时回 null 而不是空列表', () async {
    final bare =
        AppControlService(settings: TerminalSettings(SecureStorageService()));
    expect(await bare.listKnownHosts(), isNull);
  });
}
