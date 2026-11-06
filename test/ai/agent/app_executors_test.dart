import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flyterm/ai/agent/agent_events.dart';
import 'package:flyterm/ai/agent/app_permission.dart';
import 'package:flyterm/ai/agent/tool_executors/app_executors.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import '_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TerminalSettings settings;
  late AppControlService svc;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    settings = TerminalSettings(SecureStorageService());
    svc = AppControlService(settings: settings);
  });

  /// 造一个带 app 控制的真实 loop。用真 loop 而不是 fake context：
  /// `AgentToolContext` 有五十多个成员，造 fake 的维护成本远高于复用
  /// 同目录几十个测试都在用的 `makeLoop`。
  /// app 工具现在读 **远端档**（`ctx.modeProvider()`）—— 两档已于
  /// 2026-10-13 合并，所以这里改传 `mode:` 而不是已删除的 `appPermissionMode:`。
  AppExecutors execsWith(PermissionMode mode) => AppExecutors(makeLoop(
        provider: FakeProvider([]),
        appControl: svc,
        mode: mode,
      ));

  group('app_state_read', () {
    test('读 settings 分区返回白名单键', () async {
      final r = await execsWith(PermissionMode.bypass).stateRead(
        const ToolCall(
          id: '1',
          name: 'app_state_read',
          args: {'section': 'settings'},
        ),
      );
      expect(r.isError, isFalse);
      expect(r.content, contains('fontSize'));
      expect(r.content, isNot(contains('dangerousCommandGuard')));
    });

    test('readOnly 档下只读直接放行，不弹审批', () async {
      final loop = makeLoop(
        provider: FakeProvider([]),
        appControl: svc,
        mode: PermissionMode.readOnly,
      );
      final r = await AppExecutors(loop).stateRead(const ToolCall(
        id: '1',
        name: 'app_state_read',
        args: {'section': 'settings'},
      ));
      expect(r.isError, isFalse);
      expect(loop.pendingApprovals, isEmpty);
    });

    test('依赖没注入的分区回「不可用」，不回空列表', () async {
      final r = await execsWith(PermissionMode.bypass).stateRead(
        const ToolCall(
          id: '1',
          name: 'app_state_read',
          args: {'section': 'servers'},
        ),
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('not available'));
      // 回空列表会让模型以为「真的一台服务器都没有」
      expect(r.content, isNot(contains('[]')));
    });

    test('未知 section 报错并列出可选项', () async {
      final r = await execsWith(PermissionMode.bypass).stateRead(
        const ToolCall(
          id: '1',
          name: 'app_state_read',
          args: {'section': 'nope'},
        ),
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('settings'));
    });

    test('off 档下只读也被拒', () async {
      final r = await execsWith(PermissionMode.ask).stateRead(
        const ToolCall(
          id: '1',
          name: 'app_state_read',
          args: {'section': 'settings'},
        ),
      );
      expect(r.isError, isTrue);
    });

    test('没注入 AppControlService 时明确报不可用', () async {
      final e = AppExecutors(makeLoop(provider: FakeProvider([])));
      final r = await e.stateRead(const ToolCall(
        id: '1',
        name: 'app_state_read',
        args: {'section': 'settings'},
      ));
      expect(r.isError, isTrue);
      expect(r.content, contains('not available'));
    });
  });

  group('app_settings_set', () {
    test('成功时回报新旧值', () async {
      await settings.setFontSize(13);
      final r = await execsWith(PermissionMode.bypass).settingsSet(
        const ToolCall(
          id: '1',
          name: 'app_settings_set',
          args: {'key': 'fontSize', 'value': 16},
        ),
      );
      expect(r.isError, isFalse);
      expect(r.content, contains('13'));
      expect(r.content, contains('16'));
      expect(settings.fontSize, 16.0);
    });

    test('被拒时 isError 且设置没动', () async {
      final before = settings.dangerousCommandGuard;
      final r = await execsWith(PermissionMode.bypass).settingsSet(
        ToolCall(
          id: '1',
          name: 'app_settings_set',
          args: {'key': 'dangerousCommandGuard', 'value': !before},
        ),
      );
      expect(r.isError, isTrue);
      expect(settings.dangerousCommandGuard, before);
    });

    test('缺 key 参数时报错而不是崩', () async {
      final r = await execsWith(PermissionMode.bypass).settingsSet(
        const ToolCall(
          id: '1',
          name: 'app_settings_set',
          args: {'value': 16},
        ),
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('key'));
    });

    test('缺 value 参数时报错', () async {
      final r = await execsWith(PermissionMode.bypass).settingsSet(
        const ToolCall(
          id: '1',
          name: 'app_settings_set',
          args: {'key': 'fontSize'},
        ),
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('value'));
    });
  });

  group('审批接入 —— 权限模型真的生效', () {
    test('ask 档下写操作挂起等审批，批准后生效', () async {
      final loop = makeLoop(
        provider: FakeProvider([]),
        appControl: svc,
        mode: PermissionMode.ask,
      );
      await settings.setFontSize(13);

      final f = AppExecutors(loop).settingsSet(const ToolCall(
        id: '1',
        name: 'app_settings_set',
        args: {'key': 'fontSize', 'value': 16},
      ));

      // 还没批准前不该已经改了
      await pumpEventQueue();
      expect(loop.pendingApprovals, hasLength(1),
          reason: 'ask 档没有弹审批 —— 权限模型没生效');
      expect(settings.fontSize, 13.0, reason: '审批还没批就先改了');

      loop.respondApproval(
          loop.pendingApprovals.single.seq, ApprovalDecision.allowOnce);

      final r = await f;
      expect(r.isError, isFalse);
      expect(settings.fontSize, 16.0);
    });

    test('ask 档下拒绝审批，设置不动且不进撤销栈', () async {
      final loop = makeLoop(
        provider: FakeProvider([]),
        appControl: svc,
        mode: PermissionMode.ask,
      );
      await settings.setFontSize(13);

      final f = AppExecutors(loop).settingsSet(const ToolCall(
        id: '1',
        name: 'app_settings_set',
        args: {'key': 'fontSize', 'value': 16},
      ));

      await pumpEventQueue();
      loop.respondApproval(
          loop.pendingApprovals.single.seq, ApprovalDecision.reject);

      final r = await f;
      expect(r.isError, isTrue);
      expect(settings.fontSize, 13.0, reason: '拒绝后设置仍被改了');
      expect(svc.changeLog.pending, isEmpty);
    });

    test('bypass 档下写操作不弹审批', () async {
      final loop = makeLoop(
        provider: FakeProvider([]),
        appControl: svc,
        mode: PermissionMode.bypass,
      );
      await AppExecutors(loop).settingsSet(const ToolCall(
        id: '1',
        name: 'app_settings_set',
        args: {'key': 'fontSize', 'value': 16},
      ));
      expect(loop.pendingApprovals, isEmpty);
      expect(settings.fontSize, 16.0);
    });

    test('preApproved 跳过审批 —— 走批量批准路径时不重复问', () async {
      final loop = makeLoop(
        provider: FakeProvider([]),
        appControl: svc,
        mode: PermissionMode.ask,
      );
      final r = await AppExecutors(loop).settingsSet(
        const ToolCall(
          id: '1',
          name: 'app_settings_set',
          args: {'key': 'fontSize', 'value': 16},
        ),
        preApproved: true,
      );
      expect(r.isError, isFalse);
      expect(loop.pendingApprovals, isEmpty);
    });
  });
}
