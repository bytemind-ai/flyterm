import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/app_permission.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/tunnel/tunnel_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late AppControlService svc;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    svc = AppControlService(
      settings: TerminalSettings(SecureStorageService()),
      servers: ServerRepository(db),
      tunnels: TunnelManager(),
      storage: SecureStorageService(),
    );
  });

  tearDown(() async => db.close());

  group('createTunnel —— 参数校验（都在真的拨号之前）', () {
    test('服务器不存在时拒绝', () async {
      final r = await svc.createTunnel(
        serverName: 'nope',
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('No server named'));
    });

    test('端口越界时拒绝', () async {
      await svc.createServer(name: 'web', host: '10.0.0.5', username: 'root');
      final r = await svc.createTunnel(
        serverName: 'web',
        localPort: 70000,
        remoteHost: 'localhost',
        remotePort: 80,
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('1–65535'));
    });

    test('方向非法时拒绝并列出可选值', () async {
      await svc.createServer(name: 'web', host: '10.0.0.5', username: 'root');
      final r = await svc.createTunnel(
        serverName: 'web',
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
        direction: 'sideways',
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('one of'));
    });

    test('依赖没注入时明确回不可用', () async {
      final bare = AppControlService(
        settings: TerminalSettings(SecureStorageService()),
      );
      final r = await bare.createTunnel(
        serverName: 'web',
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('not available'));
    });

    test('参数校验失败不进撤销栈', () async {
      await svc.createTunnel(
        serverName: 'nope',
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
      );
      expect(svc.changeLog.pending, isEmpty);
    });
  });

  group('closeTunnel', () {
    test('id 不存在时拒绝', () async {
      final r = await svc.closeTunnel('no-such-id');
      expect(r.ok, isFalse);
      expect(r.error, contains('No tunnel with id'));
    });
  });

  // 这组是 tunnel 工具最重要的约束：两个方向都不可撤销。
  group('不可逆性', () {
    test('tunnel_create 在硬清单里 —— bypass 档也要审批', () {
      final r =
          checkAppControl('tunnel_create', mode: PermissionMode.bypass);
      expect(r.decision, ToolDecision.needApproval,
          reason: '端口暴露过就收不回，必须前置确认');
    });

    test('kAppHardApproval 含 tunnel_create', () {
      expect(kAppHardApproval, contains('tunnel_create'));
    });
  });
}
