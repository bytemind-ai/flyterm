import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/app_permission.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/repositories/tab_session_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:flyterm/ssh/transport/composite_transport_factory.dart';
import 'package:flyterm/ui/terminal/split_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late SessionManager sessions;
  late SplitManager split;
  late AppControlService svc;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    final prefs = await SharedPreferences.getInstance();
    sessions = SessionManager(
      prefs: prefs,
      tabSessionRepo: TabSessionRepository(db),
      transportFactory: CompositeTransportFactory(),
    );
    split = SplitManager();
    svc = AppControlService(
      settings: TerminalSettings(SecureStorageService()),
      servers: ServerRepository(db),
      sessions: sessions,
      layout: split,
    );
  });

  // SessionManager._persist() 是 fire-and-forget 的异步写入。不先放掉它，
  // tearDown 关库之后那笔写入才落地，下一个测试会以 database_closed 挂掉
  // ——而且挂的是"下一个"测试，根因极难定位。
  tearDown(() async {
    await pumpEventQueue();
    await db.close();
  });

  Future<void> seedServer([String name = 'web']) =>
      svc.createServer(name: name, host: '10.0.0.5', username: 'root')
          .then((_) => svc.changeLog.clear());

  group('openSession —— 不抢焦点', () {
    test('开了新 tab 但 activeIndex 不变', () async {
      await seedServer('a');
      await seedServer('b');
      await svc.openSession(serverName: 'a');
      final before = sessions.activeIndex;

      await svc.openSession(serverName: 'b');

      expect(sessions.tabs, hasLength(2));
      expect(sessions.activeIndex, before,
          reason: 'session_open 把用户的焦点抢走了');
    });

    test('第一个 tab 也不激活 —— activeIndex 停在 0 且不随新增前移', () async {
      await seedServer();
      await svc.openSession(serverName: 'web');
      expect(sessions.tabs, hasLength(1));
      expect(sessions.activeIndex, 0);
    });

    test('服务器不存在时拒绝且不建 tab', () async {
      final r = await svc.openSession(serverName: 'nope');
      expect(r.ok, isFalse);
      expect(sessions.tabs, isEmpty);
    });

    test('command 只预填不执行 —— 进 staged 队列', () async {
      await seedServer();
      await svc.openSession(serverName: 'web', command: 'ls -la');
      final id = (await ServerRepository(db).findAll()).single.id;
      expect(sessions.takeStagedCommand(id), 'ls -la');
    });

    test('onSessionReady 被回调 —— UI 据此提示「已就绪」', () async {
      await seedServer();
      String? got;
      svc.onSessionReady = (tabId) => got = tabId;
      await svc.openSession(serverName: 'web');
      expect(got, isNotNull);
      expect(got, sessions.tabs.single.id);
    });

    test('撤销关掉新开的 tab', () async {
      await seedServer();
      await svc.openSession(serverName: 'web');
      await svc.changeLog.undoAll();
      expect(sessions.tabs, isEmpty);
    });
  });

  group('closeSession', () {
    test('索引越界时拒绝并说明实际数量', () async {
      final r = await svc.closeSession(5);
      expect(r.ok, isFalse);
      expect(r.error, contains('There are 0'));
    });

    test('关掉后不可撤销 —— undo 为 null', () async {
      await seedServer();
      await svc.openSession(serverName: 'web');
      svc.changeLog.clear();

      final r = await svc.closeSession(0);
      expect(r.ok, isTrue);
      expect(r.change!.undo, isNull, reason: '关掉的会话不该被标成可撤销');
      expect(sessions.tabs, isEmpty);
    });
  });

  // 这组是 session_close 的要点：不可逆性是**条件性**的。
  group('条件性硬清单', () {
    test('没活跃连接的 tab 走普通档位判定', () {
      final r = checkAppControl('session_close',
          mode: PermissionMode.bypass, hardApproval: false);
      expect(r.decision, ToolDecision.allow,
          reason: '没连上的 tab 关掉是可逆的，不该弹确认');
    });

    test('有活跃连接时即便 bypass 也要审批', () {
      final r = checkAppControl('session_close',
          mode: PermissionMode.bypass, hardApproval: true);
      expect(r.decision, ToolDecision.needApproval);
    });

    test('不传 hardApproval 时按静态名单判 —— 仍在硬清单里', () {
      final r =
          checkAppControl('session_close', mode: PermissionMode.bypass);
      expect(r.decision, ToolDecision.needApproval);
    });

    test('新开的 tab 还没连上 —— sessionHasLiveConnection 为 false', () async {
      await seedServer();
      await svc.openSession(serverName: 'web');
      expect(svc.sessionHasLiveConnection(0), isFalse);
    });
  });

  group('setLayout', () {
    test('切换并可撤销', () async {
      final r = svc.setLayout('horizontal');
      expect(r.ok, isTrue);
      expect(split.splitMode, SplitMode.horizontal);

      await svc.changeLog.undoAll();
      expect(split.splitMode, SplitMode.off);
    });

    test('非法模式被拒并列出可选值', () {
      final r = svc.setLayout('diagonal');
      expect(r.ok, isFalse);
      expect(r.error, contains('one of'));
    });

    test('已经是目标模式时回错误而不是静默成功', () {
      final r = svc.setLayout('off');
      expect(r.ok, isFalse);
      expect(r.error, contains('already'));
    });
  });
}
