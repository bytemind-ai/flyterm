import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_exec_channel.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/approval_notification.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/models/agent_session.dart';
import 'package:flyterm/data/repositories/agent_session_repository.dart';
import 'package:flyterm/data/secure_storage.dart';

import '_fakes.dart' show FakeProvider, FakeRunner, makeLoop;

/// 只返回一句纯文本、不带 tool call —— 够把 loop 跑到终态，不需要
/// runner 参与。
class _FakeProvider extends AIProvider {
  @override
  String get displayName => 'fake';
  @override
  String get providerType => 'fake';
  @override
  bool get supportsTools => true;
  @override
  Future<String> complete(List<AIMessage> messages) async => '';
  @override
  Future<AIResponse> completeWithTools(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    String? sessionKey,
  }) async => const AIResponse(text: 'nginx was down, restarted it');
}

class _FakeRunner implements CommandRunner {
  @override
  Future<CommandOutput> run(String command,
          {String? cwd,
          Duration? timeout,
          bool denoise = false,
          int? maxBytes,

          TruncateMode truncate = TruncateMode.head}) async =>
      const CommandOutput(stdout: '', stderr: '', exitCode: 0);
  @override
  Future<void> dispose() async {}
}

Server _fakeServer(String id) => Server(
  id: id,
  name: id,
  host: 'localhost',
  port: 22,
  username: 'user',
  authType: 'password',
);

/// 除「历史会话归档」组之外，其余分组不关心 agent_sessions 表本身的内容，
/// 只是构造 [AgentSessionManager] 时必须给一个 repo —— 这里全文件共用一份
/// in-memory db，各组用的 serverId 互不相同，不会串味。
late Database _sharedDb;
late AgentSessionRepository _sharedRepo;

/// 构造一个全新的 [AgentSessionManager]，每次都拿一份新的 mock prefs 实例
/// （由外层 `setUp` 里的 `setMockInitialValues({})` 保证互不串味）。
Future<AgentSessionManager> _mgr() async =>
    AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);

/// 轮询等待条件成立，超时即 fail。与同文件里 edit_file 回归用例内联的那份
/// 同义，抽出来供新增用例复用。
Future<void> _waitUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for condition');
    }
    await Future.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUpAll(() async {
    _sharedDb = await AppDatabase.open(inMemory: true);
    _sharedRepo = AgentSessionRepository(_sharedDb);
  });
  tearDownAll(() => _sharedDb.close());

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('规则持久化（全局）', () {
    test('首次读取返回默认规则集', () async {
      final prefs = await SharedPreferences.getInstance();
      final m = AgentSessionManager(prefs, _sharedRepo);
      expect(m.rules.allows('systemctl status nginx'), isTrue);
      expect(m.rules.rules.every((r) => r.builtin), isTrue);
    });

    test('规则是全局的——所有服务器共用同一份', () async {
      // 与改动之前相反：那时按 serverId 隔离。规则表达的主要是「这类命令
      // 我信任」，更接近对命令的判断而非对机器的判断；真正随机器变的只有
      // 「这台我敢让它做多少」，那件事由权限模式两级承担。
      final prefs = await SharedPreferences.getInstance();
      final m = AgentSessionManager(prefs, _sharedRepo);
      m.addRule(const PermissionRule(pattern: 'systemctl restart *'));

      expect(m.rules.allows('systemctl restart nginx'), isTrue);
      expect(
        AgentSessionManager(prefs, _sharedRepo).rules.allows('systemctl restart nginx'),
        isTrue,
      );
    });

    test('禁用内置规则后不再放行', () async {
      final prefs = await SharedPreferences.getInstance();
      final m = AgentSessionManager(prefs, _sharedRepo);
      m.setRuleEnabled('cat *', false);
      expect(m.rules.allows('cat /etc/hosts'), isFalse);
      expect(m.rules.allows('ls /etc'), isTrue);
    });

    test('删除用户规则', () async {
      final prefs = await SharedPreferences.getInstance();
      final m = AgentSessionManager(prefs, _sharedRepo);
      m.addRule(const PermissionRule(pattern: 'foo *'));
      expect(m.rules.allows('foo bar'), isTrue);
      m.removeRule('foo *');
      expect(m.rules.allows('foo bar'), isFalse);
    });

    test('重复添加同一 pattern 不产生副本', () async {
      final prefs = await SharedPreferences.getInstance();
      final m = AgentSessionManager(prefs, _sharedRepo);
      m.addRule(const PermissionRule(pattern: 'foo *'));
      m.addRule(const PermissionRule(pattern: 'foo *'));
      final count = m.rules.rules.where((r) => r.pattern == 'foo *').length;
      expect(count, equals(1));
    });

    test('整组开关仍然可用', () async {
      final prefs = await SharedPreferences.getInstance();
      final m = AgentSessionManager(prefs, _sharedRepo);
      m.setBuiltinGroupEnabled(false);
      expect(m.rules.rules.where((r) => r.builtin).every((r) => !r.enabled),
          isTrue);
    });

    test('旧的 per-server 规则不迁移——全局初值是默认清单', () async {
      // 合并多台服务器的规则没有清晰语义（内置分组的开关状态该取交集还是
      // 并集？用户自定义规则取并集会把「只在测试机放行的 docker exec」带到
      // 生产机上，那是危险的默认）。
      SharedPreferences.setMockInitialValues({
        'agent_rules_s1': jsonEncode(
          PermissionRuleSet(const [PermissionRule(pattern: 'legacy *')])
              .toJson(),
        ),
      });
      final m = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      expect(m.rules.allows('legacy thing'), isFalse);
      expect(m.rules.allows('systemctl status nginx'), isTrue,
          reason: '全局初值应当是默认清单');
    });
  });

  group('首次过目标记（全局）', () {
    test('初始未过目', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(AgentSessionManager(prefs, _sharedRepo).hasReviewedRules, isFalse);
    });

    test('标记后持久化，且对所有服务器生效', () async {
      // 规则变全局之后，「第一次用 agent 前强制过目放行清单」也只该发生
      // 一次，不是每台服务器一次。
      final prefs = await SharedPreferences.getInstance();
      final m = AgentSessionManager(prefs, _sharedRepo);
      m.markRulesReviewed();
      expect(AgentSessionManager(prefs, _sharedRepo).hasReviewedRules, isTrue);
    });

    test('旧的 per-server 标记不迁移——会再过目一次', () async {
      // 全局键是新的，读不到旧的 per-server 标记。老用户会再看一次那份
      // 清单：一次而已，且那份清单正是「无感排查」的全部来源。
      SharedPreferences.setMockInitialValues({
        'agent_rules_reviewed_s1': true,
      });
      final m = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      expect(m.hasReviewedRules, isFalse);
    });
  });

  // 回归 —— 生产代码里唯一构造 AgentLoop 的地方
  // （terminal_screen.dart 的 `_agentLoopFor`）曾经从没传过 `restoreFrom`，
  // 导致 archiveFor()/restoreFrom 这条持久化链完整实现却是死代码，没有
  // 任何测试覆盖那处「装配漏了一行」。这里按 `_agentLoopFor` 的真实装配
  // 顺序重演一遍：register → 跑完一轮 → 显式归档 → 换新 manager 实例
  // （模拟进程被杀重启）→ 用 takeMostRecent() 的结果传 restoreFrom。
  //
  // 归档不再在终态自动发生，所以「落盘」这一步从「等 register()
  // 的监听器自动触发」改成显式调用 archiveCurrent；archiveFor 也已被
  // repository 化的 takeMostRecent 取代。
  group('存档装配（回归）', () {
    test('归档过的会话重开后事件流不为空', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, _sharedRepo);
      const serverId = 'srv-archive';

      final loop = AgentLoop(
        providerProvider: () => _FakeProvider(),
        runnerProvider: (_) => _FakeRunner(),
        rulesProvider: () => mgr.rules,
        modeProvider: () => mgr.modeFor(serverId),
        onRuleAdded: (r) => mgr.addRule(r),
        systemPromptProvider: (_) => 'p1',
        toolSpecsProvider: () => leanToolSpecs,
        // 首次装配：还没有存档，这里应当（也确实）是 null。
        restoreFrom: await mgr.takeMostRecent(serverId),
      );
      mgr.register(serverId, loop);

      await loop.send('why is nginx down?');
      expect(loop.stopReason, equals(AgentStopReason.completed));

      // 归档不再自动发生 —— 显式落盘（对应「打开另一段/新建会话」前的
      // 收尾动作）。
      await mgr.archiveCurrent(serverId);

      // 换一个全新的 manager 实例模拟「进程被杀，重启 app」——唯一延续
      // 下来的只有 SQLite 里的那一行。
      final mgr2 = AgentSessionManager(prefs, _sharedRepo);
      final archive = await mgr2.takeMostRecent(serverId);
      expect(archive, isNotNull);

      final restored = AgentLoop(
        providerProvider: () => _FakeProvider(),
        runnerProvider: (_) => _FakeRunner(),
        rulesProvider: () => mgr2.rules,
        modeProvider: () => mgr2.modeFor(serverId),
        onRuleAdded: (r) => mgr2.addRule(r),
        systemPromptProvider: (_) => 'p2 (new session, new prompt)',
        toolSpecsProvider: () => leanToolSpecs,
        restoreFrom: archive,
      );

      expect(restored.events, isNotEmpty);
      expect(
        restored.events.whereType<UserTurnEvent>().first.text,
        equals('why is nginx down?'),
      );
      expect(
        restored.events.whereType<AssistantTextEvent>().first.text,
        equals('nginx was down, restarted it'),
      );
    });

    test('archiveCurrent + closeLoop 之后当前 loop 清空，但历史没有丢', () async {
      // 替换了原来的「clearArchive + closeLoop → 重开是干净会话」回归——
      // clearArchive 已经不存在：「清空对话」的语义从「删除」
      // 变成「归档」（见 ai_panel.dart `_clear()`），所以重开不再保证是
      // 空白会话，而是保证数据没有被静默丢弃。
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, _sharedRepo);
      const serverId = 'srv-clear';

      final loop = AgentLoop(
        providerProvider: () => _FakeProvider(),
        runnerProvider: (_) => _FakeRunner(),
        rulesProvider: () => mgr.rules,
        modeProvider: () => mgr.modeFor(serverId),
        onRuleAdded: (r) => mgr.addRule(r),
        systemPromptProvider: (_) => 'p1',
        toolSpecsProvider: () => leanToolSpecs,
      );
      mgr.register(serverId, loop);
      await loop.send('hello');

      // 面板「清空对话」按钮在 agent 模式下的动作：归档当前段，关掉 loop。
      await mgr.archiveCurrent(serverId);
      mgr.closeLoop(serverId);

      expect(mgr.loopFor(serverId), isNull);
      expect(await mgr.sessionsFor(serverId), isNotEmpty,
          reason: '归档不是删除，数据必须还在表里');
    });
  });

  // 回归 —— exec channel 从 `_TerminalScreenState` 移到
  // 这里，生命周期要与 loop 一致：同一 serverId 的 channel 只建一次，
  // 跨多次面板打开（多次 `channelFor` 调用）复用同一个实例。
  group('exec channel 同生命周期（回归）', () {
    test('channelFor 按 serverId 复用同一个实例', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, _sharedRepo);
      final storage = SecureStorageService();
      var createCount = 0;

      AgentExecChannel create(String id) {
        createCount++;
        return AgentExecChannel(server: _fakeServer(id), storage: storage);
      }

      final c1 = mgr.channelFor('srv1', () => create('srv1'));
      final c2 = mgr.channelFor('srv1', () => create('srv1'));
      final c3 = mgr.channelFor('srv2', () => create('srv2'));

      expect(identical(c1, c2), isTrue);
      expect(identical(c1, c3), isFalse);
      expect(createCount, equals(2)); // 一次 srv1，一次 srv2
    });
  });

  group('工具分档偏好', () {
    test('默认是自动（null）', () async {
      final mgr = await _mgr();
      expect(mgr.toolTierOverride, isNull);
    });

    test('设置后可读回', () async {
      final mgr = await _mgr();
      mgr.toolTierOverride = AgentToolTier.lean;
      expect(mgr.toolTierOverride, equals(AgentToolTier.lean));
    });

    test('设回 null 表示恢复自动', () async {
      final mgr = await _mgr();
      mgr.toolTierOverride = AgentToolTier.full;
      mgr.toolTierOverride = null;
      expect(mgr.toolTierOverride, isNull);
    });

    test('存的是坏值时按自动处理，不抛', () async {
      SharedPreferences.setMockInitialValues({'agent_tool_tier': 'bogus'});
      final mgr = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      expect(mgr.toolTierOverride, isNull);
    });
  });

  // 审批通知去重回归 —— edit_file 的读、写两个阶段共用同一个 callId
  // （见 agent_loop.dart `_executeEditFile` 的说明），而 `_notified` 是按
  // (serverId, callId) 去重的只增集合。读审批推送通知、消费掉去重键之后，
  // 写审批（真正带 diff、真正会改文件的那张卡）就再也推不出通知。
  //
  // 触发条件与线上一致：路径落在凭据清单里（这里用 `~/.env`），于是
  // **读**也要审批，两次审批的通知缺一不可。
  group('审批通知去重（edit_file 双阶段回归）', () {
    CommandOutput readOut(String content) {
      final bytes = utf8.encode(content);
      return CommandOutput(
        stdout: '${sha256.convert(bytes)}\n${bytes.length}\n'
            '${base64.encode(bytes)}',
        stderr: '',
        exitCode: 0,
      );
    }

    Future<void> waitUntil(bool Function() cond) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!cond()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for condition');
        }
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    test('读审批与写审批各自推一次通知', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, _sharedRepo);
      const serverId = 'srv-edit';

      final notifiedKeys = <String>[];
      mgr.onApprovalPending = (id, ev) =>
          notifiedKeys.add(approvalDedupKey(id, ev.callId, ev.seq));

      final runner = FakeRunner(results: [
        readOut('password=old\n'),
        const CommandOutput(stdout: '', stderr: '', exitCode: 0),
      ]);
      // provider 必须是单一实例：`providerProvider` 每次调用若各建一个新
      // FakeProvider，`_i` 都会从 0 重新数起，round 2 会重放 round 1 的
      // 脚本项（又一次 edit_file），而不是本该收到的 'done'。
      final provider = FakeProvider([
        const AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'edit_file', args: {
            'path': '~/.env',
            'old_string': 'password=old',
            'new_string': 'password=new',
          }),
        ]),
        const AIResponse(text: 'done'),
      ]);
      final loop = AgentLoop(
        providerProvider: () => provider,
        runnerProvider: (_) => runner,
        rulesProvider: () => mgr.rules,
        modeProvider: () => mgr.modeFor(serverId),
        onRuleAdded: (r) => mgr.addRule(r),
        systemPromptProvider: (_) => 'p',
        cwdProvider: () => '/home/u',
        toolSpecsProvider: () => fullToolSpecs,
      );
      mgr.register(serverId, loop);

      final f = loop.send('update env');

      // 阶段一：读审批（凭据路径，即使是只读也要审批）。
      await waitUntil(() => loop.pendingApprovals.isNotEmpty);
      expect(loop.pendingApprovals.single.check.reason,
          equals(ApprovalReason.credentialDeny));
      final firstSeq = loop.pendingApprovals.single.seq;
      loop.respondApproval(firstSeq, ApprovalDecision.allowOnce);

      // 阶段二：写审批。同一个 callId = 'c1'，但 seq 不同——路径本身也命中
      // 凭据清单，所以 reason 同样是 credentialDeny（这两张卡都该显示红色
      // 警示，不冲突），真正要断言的是它是**另一个事件**（不同 seq）。
      await waitUntil(() =>
          loop.pendingApprovals.isNotEmpty &&
          loop.pendingApprovals.single.seq != firstSeq);
      loop.respondApproval(
          loop.pendingApprovals.single.seq, ApprovalDecision.allowOnce);

      await f;
      expect(loop.stopReason, equals(AgentStopReason.completed));

      expect(notifiedKeys, hasLength(2),
          reason: '读、写两张卡都要推通知，写的那张尤其不能被静默');
      expect(notifiedKeys.toSet(), hasLength(2),
          reason: '两个键必须不同，否则第二次会被去重集合吃掉');
    });
  });

  // `_notified` 的对账回归 —— 它曾经是个只增集合，被应答掉的审批的 key 留在
  // 里面永远不删。后果不只是内存只涨不落，还有语义错位：同一张卡（同
  // serverId / callId / seq）在应答后如果再次进入待审批，**应该**重新通知，
  // 而不是被一条陈旧记录永久压住。
  group('审批去重集合对账（应答后重新通知）', () {
    test('同一条审批被应答后再次出现，会重新推通知', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, _sharedRepo);
      const serverId = 'srv-reconcile';
      // 显式钉死 ask 档，不依赖默认值 —— 默认档改了不该让这条回归测试
      // 变成「有时审批、有时不审批」。
      mgr.defaultMode = PermissionMode.ask;

      var notified = 0;
      mgr.onApprovalPending = (_, __) => notified++;

      final runner = FakeRunner(results: [
        const CommandOutput(stdout: 'x', stderr: '', exitCode: 0),
        const CommandOutput(stdout: 'x', stderr: '', exitCode: 0),
      ]);
      final provider = FakeProvider([
        const AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'bash', args: {'command': 'echo x'}),
        ]),
        const AIResponse(text: 'done'),
      ]);
      final loop = AgentLoop(
        providerProvider: () => provider,
        runnerProvider: (_) => runner,
        rulesProvider: () => mgr.rules,
        modeProvider: () => mgr.modeFor(serverId),
        onRuleAdded: (r) => mgr.addRule(r),
        systemPromptProvider: (_) => 'p',
        cwdProvider: () => '/home/u',
        toolSpecsProvider: () => fullToolSpecs,
      );
      mgr.register(serverId, loop);

      // 第一次审批（ask 档下 run_command 要批准）。
      final f = loop.send('run');
      await _waitUntil(() => loop.pendingApprovals.isNotEmpty);
      expect(notified, equals(1), reason: '第一张卡要通知');

      // 应答 → 这一轮结束，审批不再 pending，对账应把 key 清掉。
      loop.respondApproval(
        loop.pendingApprovals.single.seq,
        ApprovalDecision.allowOnce,
      );
      await f;

      // 直接查对账后的集合大小：key 必须已经被清掉，否则下一段会话里同
      // (serverId, callId, seq) 的审批会被永久压住。
      expect(mgr.notifiedApprovalCountForTesting, equals(0),
          reason: '应答后该 key 必须从去重集合里消失');
    });
  });

  group('自定义指令', () {
    test('默认为空', () async {
      SharedPreferences.setMockInitialValues({});
      final mgr = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      expect(mgr.instructions, isNull);
    });

    test('本地指令是全局的——所有服务器共用同一份', () async {
      // 这一份放的是跟机器无关的偏好（简洁、中文、先说结论）。机器级差异
      // 归 ServerNotesManager，按 serverId 存在 app 端的 server_notes 表里。
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, _sharedRepo);
      mgr.instructions = '回答简洁点';
      expect(mgr.instructions, equals('回答简洁点'));
      // 换一个 manager 实例模拟重启，仍是同一份
      expect(AgentSessionManager(prefs, _sharedRepo).instructions, equals('回答简洁点'));
    });

    test('写空串等于清空——不留一个空字符串在盘上', () async {
      SharedPreferences.setMockInitialValues({});
      final mgr = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      mgr.instructions = '回答简洁点';
      mgr.instructions = '   ';
      expect(mgr.instructions, isNull);
    });
  });

  // 落盘条件是 `!isRunning && stopReason != null`（只在终态写盘）。恢复出来
  // 的 loop 若不把 stopReason 一起还原，就永远不满足这个条件——于是用户在
  // 「关面板再打开」之后的丢弃/撤销动作全部只改内存、不落盘，再关再开就复活。
  // 归档不再在终态自动发生：以下两条都改成先显式
  // `archiveCurrent`，再用 `takeMostRecent` / 直接查 `_sharedRepo` 取回，
  // 取代原来的同步、非消费式 `archiveFor`。
  group('恢复出来的会话仍能落盘', () {
    test('从 archive 重建的 loop 带着终态，不是 null', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, _sharedRepo);
      const serverId = 'srv-restore-terminal';

      final loop = AgentLoop(
        providerProvider: () => _FakeProvider(),
        runnerProvider: (_) => _FakeRunner(),
        rulesProvider: () => mgr.rules,
        modeProvider: () => mgr.modeFor(serverId),
        onRuleAdded: (_) {},
        systemPromptProvider: (_) => 'p1',
        toolSpecsProvider: () => leanToolSpecs,
      );
      mgr.register(serverId, loop);
      await loop.send('status?');
      expect(loop.stopReason, equals(AgentStopReason.completed));

      await mgr.archiveCurrent(serverId);
      final restoreData = await mgr.takeMostRecent(serverId);

      final restored = AgentLoop(
        providerProvider: () => _FakeProvider(),
        runnerProvider: (_) => _FakeRunner(),
        rulesProvider: () => mgr.rules,
        modeProvider: () => mgr.modeFor(serverId),
        onRuleAdded: (_) {},
        systemPromptProvider: (_) => 'p2',
        toolSpecsProvider: () => leanToolSpecs,
        restoreFrom: restoreData,
      );

      // 这是整条链的关键：null 的话 manager 永远不会为它落盘
      expect(restored.stopReason, isNotNull);
      expect(restored.isRunning, isFalse);
    });

    test('恢复后丢弃方案会真的落盘——不会再关再开就复活', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, _sharedRepo);
      const serverId = 'srv-discard-persist';

      // 第一段会话：攒出一个提案然后结束
      final loop = AgentLoop(
        providerProvider: () => FakeProvider([
          AIResponse(toolCalls: [
            const ToolCall(id: 'c1', name: 'write_file', args: {
              'path': '/etc/a.conf',
              'content': 'x',
              'description': '写配置',
            })
          ]),
          const AIResponse(text: 'proposal'),
        ]),
        runnerProvider: (_) => FakeRunner(),
        rulesProvider: () => mgr.rules,
        modeProvider: () => PermissionMode.ask,
        onRuleAdded: (_) {},
        systemPromptProvider: (_) => 'p1',
        toolSpecsProvider: () => fullToolSpecs,
      );
      mgr.register(serverId, loop);
      await loop.send('fix it');
      expect(loop.planQueue, hasLength(1));

      // 归档不再自动发生 —— 显式落盘（对应「关面板」之前的收尾动作）。
      await mgr.archiveCurrent(serverId);
      var row = await _sharedRepo.mostRecent(serverId);
      expect((jsonDecode(row!.archive) as Map)['planQueue'], hasLength(1));

      // 第二段：关面板再打开（loop 从存档重建，取走这一行）
      final restoreData = await mgr.takeMostRecent(serverId);
      final restored = AgentLoop(
        providerProvider: () => FakeProvider([]),
        runnerProvider: (_) => FakeRunner(),
        rulesProvider: () => mgr.rules,
        modeProvider: () => PermissionMode.ask,
        onRuleAdded: (_) {},
        systemPromptProvider: (_) => 'p2',
        toolSpecsProvider: () => fullToolSpecs,
        restoreFrom: restoreData,
      );
      mgr.register(serverId, restored);
      expect(restored.planQueue, hasLength(1));

      restored.discardPlan();
      await mgr.archiveCurrent(serverId);

      // 盘上那份也必须跟着清空，否则第三次打开方案会原样复活
      row = await _sharedRepo.mostRecent(serverId);
      expect((jsonDecode(row!.archive) as Map)['planQueue'], isEmpty);
    });
  });

  group('权限模式两级', () {
    test('没有覆盖时 modeFor 返回全局默认', () async {
      SharedPreferences.setMockInitialValues({});
      final mgr = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      expect(mgr.defaultMode, equals(PermissionMode.ask));
      expect(mgr.modeOverrideFor('s1'), isNull);
      expect(mgr.modeFor('s1'), equals(PermissionMode.ask));
    });

    test('改全局默认，没有覆盖的服务器跟着变', () async {
      SharedPreferences.setMockInitialValues({});
      final mgr = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      mgr.defaultMode = PermissionMode.ask;
      expect(mgr.modeFor('s1'), equals(PermissionMode.ask));
      expect(mgr.modeFor('s2'), equals(PermissionMode.ask));
    });

    test('有覆盖时用覆盖值，且不受全局默认影响', () async {
      SharedPreferences.setMockInitialValues({});
      final mgr = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      mgr.setModeOverride('s1', PermissionMode.bypass);
      mgr.defaultMode = PermissionMode.ask;

      expect(mgr.modeFor('s1'), equals(PermissionMode.bypass));
      expect(mgr.modeFor('s2'), equals(PermissionMode.ask));
    });

    test('清除覆盖后重新跟随全局——改全局它会跟着变', () async {
      // 这是「选跟随全局」必须是**清除**而不是「写入当前全局值」的原因：
      // 若写入当前值，以后改全局默认这台服务器不会跟着变。
      SharedPreferences.setMockInitialValues({});
      final mgr = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      mgr.setModeOverride('s1', PermissionMode.bypass);
      mgr.setModeOverride('s1', null);

      expect(mgr.modeOverrideFor('s1'), isNull);
      mgr.defaultMode = PermissionMode.ask;
      expect(mgr.modeFor('s1'), equals(PermissionMode.ask));
    });

    test('迁移零成本：已存下的 agent_mode_<id> 直接成为覆盖', () async {
      SharedPreferences.setMockInitialValues({'agent_mode_s1': 'bypass'});
      final mgr = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      expect(mgr.modeOverrideFor('s1'), equals(PermissionMode.bypass));
      expect(mgr.modeFor('s1'), equals(PermissionMode.bypass));
      expect(mgr.modeFor('s2'), equals(PermissionMode.ask));
    });

    test('全局默认存坏值 → ask 兜底', () async {
      SharedPreferences.setMockInitialValues({'agent_mode_default': 'garbage'});
      final mgr = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      expect(mgr.defaultMode, equals(PermissionMode.ask));
    });

    test('覆盖存坏值 → 视为无覆盖，跟随全局，不崩', () async {
      SharedPreferences.setMockInitialValues({
        'agent_mode_s1': 'garbage',
        'agent_mode_default': 'ask',
      });
      final mgr = AgentSessionManager(await SharedPreferences.getInstance(), _sharedRepo);
      expect(mgr.modeOverrideFor('s1'), isNull);
      expect(mgr.modeFor('s1'), equals(PermissionMode.ask));
    });

    test('两级都持久化——换 manager 实例读回来还在', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, _sharedRepo);
      mgr.defaultMode = PermissionMode.ask;
      mgr.setModeOverride('s1', PermissionMode.bypass);

      final mgr2 = AgentSessionManager(prefs, _sharedRepo);
      expect(mgr2.defaultMode, equals(PermissionMode.ask));
      expect(mgr2.modeFor('s1'), equals(PermissionMode.bypass));
      expect(mgr2.modeFor('s2'), equals(PermissionMode.ask));
    });
  });

  group('历史会话归档', () {
    late Database db;
    late AgentSessionRepository repo;

    setUp(() async {
      db = await AppDatabase.open(inMemory: true);
      repo = AgentSessionRepository(db);
    });
    tearDown(() async => db.close());

    test('archiveCurrent 写入一行，标题取首条用户提问', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, repo);

      final loop = makeLoop(provider: FakeProvider([]));
      loop.debugAddEvent(UserTurnEvent('为什么 502'));
      loop.debugAddEvent(AssistantTextEvent('看一下 nginx'));
      mgr.register('s1', loop);

      await mgr.archiveCurrent('s1');

      final rows = await repo.listForServer('s1');
      expect(rows.length, equals(1));
      expect(rows.single.title, equals('为什么 502'));
      expect(rows.single.eventCount, equals(2));
    });

    test('没有用户提问时退回首条助手文本', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, repo);

      final loop = makeLoop(provider: FakeProvider([]));
      loop.debugAddEvent(AssistantTextEvent('我看到一条报错'));
      mgr.register('s1', loop);

      await mgr.archiveCurrent('s1');

      expect((await repo.listForServer('s1')).single.title,
          equals('我看到一条报错'));
    });

    test('空会话不写表', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, repo);
      mgr.register('s1', makeLoop(provider: FakeProvider([])));

      await mgr.archiveCurrent('s1');

      expect(await repo.listForServer('s1'), isEmpty);
    });

    test('旧 key 迁移一次且幂等 —— 跑两遍只产生一行', () async {
      SharedPreferences.setMockInitialValues({
        'agent_archive_s1': '{"events":[{"t":"user","text":"旧的一段"}],'
            '"history":[],"planQueue":[]}',
      });
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, repo);

      await mgr.migrateLegacyArchives(['s1']);
      await mgr.migrateLegacyArchives(['s1']);

      final rows = await repo.listForServer('s1');
      expect(rows.length, equals(1));
      expect(rows.single.title, equals('旧的一段'));
      expect(prefs.getString('agent_archive_s1'), isNull,
          reason: '搬完必须删 key，否则下次启动会再搬一次');
    });

    test('旧 key 是坏 JSON → 删掉 key、表里零行、不抛', () async {
      SharedPreferences.setMockInitialValues({
        'agent_archive_s1': 'not json at all',
      });
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, repo);

      await mgr.migrateLegacyArchives(['s1']);

      expect(await repo.listForServer('s1'), isEmpty);
      expect(prefs.getString('agent_archive_s1'), isNull);
    });

    test('归档后执行滚动删除', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs, repo);

      // 用常量而不是写死的数字：配额是可调的（2026-10-13 从 20 提到 50，
      // 全局 AI 100），写死会让这条测试在下次调额时莫名其妙地挂。
      final over = sessionQuotaFor('s1') + 2;
      for (var i = 0; i < over; i++) {
        final loop = makeLoop(provider: FakeProvider([]));
        loop.debugAddEvent(UserTurnEvent('q$i'));
        mgr.register('s1', loop);
        await mgr.archiveCurrent('s1');
        mgr.closeLoop('s1');
      }

      expect((await repo.listForServer('s1')).length,
          equals(sessionQuotaFor('s1')));
    });
  });

  // 进程被杀是移动端的常态而非例外（设计上明确否决「重启后一律给空
  // 会话」）。落盘曾经只发生在「新建会话」「打开另一段」两个显式动作里，
  // 于是当前活跃段全程只在内存 —— 杀掉 app 就是一次静默数据丢失，而且因为
  // takeMostRecent 会删走取到的那行，反复杀会一段段吃掉历史。
  //
  // 修法：活跃段有一个固定的行，每次终态 UPDATE 它；只在显式动作时封存那行
  // 并开新行。会话**边界**仍由显式动作划分（这点不变），变的只是**落盘
  // 时机**——那两件事此前被混为一谈了。
  group('进程被杀也不丢', () {
    late Database db;
    late AgentSessionRepository repo;

    setUp(() async {
      db = await AppDatabase.open(inMemory: true);
      repo = AgentSessionRepository(db);
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() async => db.close());

    Future<AgentSessionManager> mgrWith() async =>
        AgentSessionManager(await SharedPreferences.getInstance(), repo);

    /// 等到表里出现 [expected] 行，而不是赌一个固定延迟。
    ///
    /// 落盘由 loop 的 notifyListeners 触发，经 `unawaited(_enqueuePersist)`
    /// 发出，内部要 await 好几次 SQLite 写入 —— 一个 microtask 不够用。
    /// `await Future<void>.delayed(Duration.zero)` 在单文件跑时恰好赶得上，
    /// 全量并发跑时机器一忙就赶不上，于是测试会因为「这一批同时跑了几个
    /// 文件」这种与被测代码毫无关系的事情变红。
    ///
    /// **2026-10-13 后更不能赌 microtask 了**：落盘现在要穿过一层每服务器
    /// 队列（防重叠时重复 INSERT，见 `_enqueuePersist`），比之前多一个
    /// `.then()` 跳。`Duration.zero` 从「恰好赶得上」变成了「经常赶不上」。
    ///
    /// 轮询到条件成立才返回，所以机器越忙它只是越慢，不会越容易错。
    Future<List<AgentSession>> waitForRows(
      String serverId,
      int expected,
    ) async {
      for (var i = 0; i < 200; i++) {
        final rows = await repo.listForServer(serverId);
        if (rows.length >= expected) return rows;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final actual = (await repo.listForServer(serverId)).length;
      fail('等了 2 秒，$serverId 的表里仍只有 $actual 行（期望 $expected）');
    }

    /// 等到表里的行**更新**（内容变了）为止，而不是等一个 microtask。
    ///
    /// 给「同一行被 UPDATE」那类用例用 —— 那里行数不变，靠行数等不到
    /// 任何信号。条件用 [probe] 表达（比如 eventCount 变大）。
    Future<List<AgentSession>> waitForRowsUpdate(
      String serverId,
      bool Function(AgentSession row) probe,
    ) async {
      for (var i = 0; i < 200; i++) {
        final rows = await repo.listForServer(serverId);
        if (rows.length == 1 && probe(rows.single)) return rows;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final rows = await repo.listForServer(serverId);
      fail('等了 2 秒，$serverId 的那一行仍未满足条件（当前 ${rows.length} 行）');
    }

    test('连续多次提问并发落盘，只占一行 —— 不是每次 INSERT 新行',
        () async {
      // 回归：`_activeRowId[serverId] = await repo.insert(...)` 的赋值发生在
      // await **之后**。两次 `_persistActive` 重叠时（第一次还卡在 INSERT 的
      // await 里，`_activeRowId` 仍是空），第二次进来看到 `existing == null`，
      // 于是又 INSERT 一行 —— 同一段会话在历史列表里出现多条重复条目，各自
      // 只带部分内容。
      //
      // 而 `_persistActive` 是从同步回调里 `unawaited(...)` 起的，所以这个
      // 重叠在真实使用中就会发生：用户连续发几句话，每句都在终态触发一次
      // 落盘。
      final mgr = await mgrWith();
      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(text: 'r1'),
        const AIResponse(text: 'r2'),
        const AIResponse(text: 'r3'),
      ]));
      mgr.register('s1', loop);

      // 连续三次提问，**中间不等待落盘** —— 这正是竞态的触发条件。
      await loop.send('q1');
      await loop.send('q2');
      await loop.send('q3');

      // 等所有落盘都跑完：轮询到「第二次 persist 之后」。
      await waitForRows('s1', 1);
      // 再多等一会，让可能存在的第二次 INSERT 也落下去。
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final rows = await repo.listForServer('s1');
      expect(rows, hasLength(1),
          reason: '同一段会话只该占一行；多于一行说明落盘重叠时重复 INSERT 了');
      expect(mgr.activeRowIdFor('s1'), equals(rows.single.id));
    });

    test('archiveCurrent 期间排入的落盘不会重复 INSERT', () async {
      // `archiveCurrent` 把「松开 `_activeRowId`」也排进同一条队列，所以
      // 它与落盘之间没有窗口让别的落盘插进来。这里测的是并发下行数的
      // 稳定性 —— 若 remove 与落盘分开执行，另一条已排队的落盘会在
      // `_activeRowId` 仍有效时 UPDATE 刚封存的行（把下一段内容写进上一段），
      // 或在 remove 之后重复 INSERT。
      final mgr = await mgrWith();
      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(text: '第一段'),
        const AIResponse(text: '第二段'),
      ]));
      mgr.register('s1', loop);

      await loop.send('第一段的问题');
      // 封存（「新建会话」/「打开另一段」的动作），**不 await** ——
      // 紧跟着再发一轮，让它的落盘与封存并发。
      final archiving = mgr.archiveCurrent('s1');
      await loop.send('第二段的问题');
      await archiving;

      await waitForRows('s1', 1);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final rows = await repo.listForServer('s1');
      expect(rows.length, equals(2),
          reason: '两段会话 → 两行：封存后新起的那段落在一行新行上，'
              '而并发不该让它多插几行');
    });

    test('一轮跑完到终态就落盘，不必等用户点任何按钮', () async {
      final mgr = await mgrWith();
      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(text: 'nginx 挂了，已重启'),
      ]));
      mgr.register('s1', loop);

      await loop.send('为什么 502');
      // 落盘由 loop 的 notifyListeners 触发，轮询到它真的落下去。
      final rows = await waitForRows('s1', 1);
      expect(rows, hasLength(1), reason: '此刻杀掉 app，这一行就是唯一的延续');
      expect(rows.single.title, equals('为什么 502'));
    });

    test('第二轮终态是 UPDATE 同一行，不吃配额', () async {
      // 这是当初选择「少落盘」的理由：repository 只有 insert，每次落盘都新建
      // 一行，20 段配额几轮就用光。UPDATE 让一段会话永远只占一行。
      final mgr = await mgrWith();
      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(text: '第一轮'),
        const AIResponse(text: '第二轮'),
      ]));
      mgr.register('s1', loop);

      await loop.send('问题一');
      // 用 `waitForRows` 而不是 `Future.delayed(Duration.zero)`：落盘是从
      // 同步回调里 `unawaited` 起的，而它现在还要穿过一层每服务器落盘队列
      // （2026-10-13 加的，防重叠时重复 INSERT）—— 那多出来的 microtask
      // 跳让 `Duration.zero` 不再稳定够用。轮询到条件成立与调度无关。
      final afterFirst = await waitForRows('s1', 1);
      expect(afterFirst, hasLength(1));

      await loop.send('问题二');
      // 等“真的又写了一次”：第二轮的 eventCount 必须大于第一轮。
      // 行数不变（是 UPDATE），所以用 waitForRowsUpdate。
      final firstCount = afterFirst.single.eventCount;
      final afterSecond = await waitForRowsUpdate(
          's1', (row) => row.eventCount > firstCount);

      expect(afterSecond, hasLength(1), reason: '同一段会话只该占一行');
      expect(afterSecond.single.id, equals(afterFirst.single.id),
          reason: '必须是 UPDATE 同一行，不是删旧建新');
      expect(afterSecond.single.eventCount, greaterThan(firstCount),
          reason: '内容确实更新了');
    });

    test('点「新建会话」之后，下一段落到新行——边界仍由显式动作划分', () async {
      final mgr = await mgrWith();
      final loop1 = makeLoop(provider: FakeProvider([
        const AIResponse(text: '答一'),
      ]));
      mgr.register('s1', loop1);
      await loop1.send('第一段');
      // 必须等第一段**真的落盘**再封存，不能只让一个 microtask 过去。
      //
      // 竞态是这样的：archiveCurrent 自己会调一次 _persistActive。若此刻
      // 第一段的落盘还在飞（终态那次是 unawaited 发出的），两次都会看到
      // 「表里还没有这一段」于是各 INSERT 一行 —— 第一段占两行，断言看到 3。
      //
      // 单文件跑时 delayed(Duration.zero) 恰好赶得上，全量并发跑时赶不上。
      // 这条竞态与被测代码无关，纯粹是等待方式在赌调度。
      await waitForRows('s1', 1);

      // 「新建会话」：封存当前行，关掉 loop
      await mgr.archiveCurrent('s1');
      mgr.closeLoop('s1');

      final loop2 = makeLoop(provider: FakeProvider([
        const AIResponse(text: '答二'),
      ]));
      mgr.register('s1', loop2);
      await loop2.send('第二段');

      final rows = await waitForRows('s1', 2);
      expect(rows, hasLength(2), reason: '两段是两行');
      expect(rows.map((r) => r.title), containsAll(['第一段', '第二段']));
    });

    test('takeMostRecent 不再删掉那一行', () async {
      // 「取走」曾是刻意的（避免一段会话同时在表和内存两处），但它让反复
      // 杀 app 变成累积丢失。持续 UPDATE 之后那个顾虑自然消解：表里那份
      // 一直是最新的。
      final mgr = await mgrWith();
      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(text: '答'),
      ]));
      mgr.register('s1', loop);
      await loop.send('问');
      await waitForRows('s1', 1);
      mgr.closeLoop('s1');

      final restored = await mgr.takeMostRecent('s1');

      expect(restored, isNotNull);
      expect(await repo.listForServer('s1'), hasLength(1),
          reason: '取来恢复不等于从历史里消失');
    });

    test('恢复之后继续问，UPDATE 的还是那一行', () async {
      final mgr = await mgrWith();
      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(text: '答一'),
      ]));
      mgr.register('s1', loop);
      await loop.send('问一');
      final originalId = (await waitForRows('s1', 1)).single.id;
      mgr.closeLoop('s1');

      // 模拟 app 重启：新 manager 实例（内存里什么都没有），从表里恢复
      final mgr2 =
          AgentSessionManager(await SharedPreferences.getInstance(), repo);
      final archive = await mgr2.takeMostRecent('s1');
      final restored = makeLoop(
        provider: FakeProvider([const AIResponse(text: '答二')]),
        restoreFrom: archive,
      );
      mgr2.register('s1', restored);

      // 行数不变（UPDATE 同一行），等 eventCount 真的涨上去。
      final beforeCount =
          (await repo.listForServer('s1')).single.eventCount;
      await restored.send('问二');
      final rows = await waitForRowsUpdate(
          's1', (row) => row.eventCount > beforeCount);
      expect(rows, hasLength(1), reason: '恢复后继续问不该产生第二行');
      expect(rows.single.id, equals(originalId), reason: '还是原来那一行');
    });

    test('打开一段标星的历史继续问，标星不丢', () async {
      final mgr = await mgrWith();
      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(text: '答'),
      ]));
      mgr.register('s1', loop);
      await loop.send('要标星的那段');
      final id = (await waitForRows('s1', 1)).single.id!;
      await repo.setStarred(id, true);
      mgr.closeLoop('s1');

      final archive = await mgr.takeById(id);
      final reopened = makeLoop(
        provider: FakeProvider([const AIResponse(text: '接着答')]),
        restoreFrom: archive,
      );
      mgr.register('s1', reopened);
      final beforeStarred =
          (await repo.listForServer('s1')).single.eventCount;
      await reopened.send('接着问');
      final rows = await waitForRowsUpdate(
          's1', (row) => row.eventCount > beforeStarred);
      expect(rows, hasLength(1));
      expect(rows.single.starred, isTrue, reason: 'UPDATE 不该把标星刷掉');
    });

    test('空会话不落盘', () async {
      // 沿用既有语义：随手打开面板又关掉不该在列表里留碎片。
      final mgr = await mgrWith();
      final loop = makeLoop(provider: FakeProvider([]));
      mgr.register('s1', loop);
      // 这条**故意**给足时间（而不是等一个 microtask）：断言的是
      // 「什么都没写」，所以多等只会让它更严，不会假通过。
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(await repo.listForServer('s1'), isEmpty);
    });

    test('运行中连续 notify 只在节流窗口到点后落盘一次，不是每次都写',
        () async {
      final mgr = await mgrWith();
      final loop = makeLoop(provider: FakeProvider([]));
      mgr.register('srv-1', loop);
      loop.debugForceRunning();

      fakeAsync((async) {
        for (var i = 0; i < 10; i++) {
          loop.debugNotify();
        }
        // 尚未到 3 秒：不该提前落盘。
        async.elapse(const Duration(milliseconds: 2999));
        expect(mgr.debugPersistCount, equals(0),
            reason: '节流窗口内连续 10 次 notify 不该提前触发落盘');

        // 跨过 3 秒：该落盘恰好一次——这是「尾沿节流」而非「防抖」的关键
        // 断言：若实现改成每次 notify 都重置计时器（防抖），持续到达的
        // notify 会让计时器永远够不到触发条件，这里看到的会是 0 而不是 1。
        async.elapse(const Duration(milliseconds: 2));
        expect(mgr.debugPersistCount, equals(1));
      });
    });

    test('closeLoop 取消尚未到期的节流定时器，不会在会话关闭后补一次落盘',
        () async {
      final mgr = await mgrWith();
      final loop = makeLoop(provider: FakeProvider([]));
      mgr.register('srv-1', loop);
      loop.debugForceRunning();

      fakeAsync((async) {
        loop.debugNotify();
        mgr.closeLoop('srv-1');
        async.elapse(const Duration(seconds: 3));
        expect(mgr.debugPersistCount, equals(0),
            reason: '关闭时应取消未到期的定时器，否则关闭之后还会莫名其妙写一次库');
      });
    });
  });

  group('待投递 prompt', () {
    test('投递后取一次就没了——不能被第二个页面重复消费', () async {
      final m = await _mgr();
      m.stagePrompt('srv-1', '看看 job-1757000000000-aaaa');
      expect(m.takeStagedPrompt('srv-1'), '看看 job-1757000000000-aaaa');
      expect(m.takeStagedPrompt('srv-1'), isNull);
    });

    test('按 serverId 隔离', () async {
      final m = await _mgr();
      m.stagePrompt('srv-1', 'a');
      expect(m.takeStagedPrompt('srv-2'), isNull);
      expect(m.takeStagedPrompt('srv-1'), 'a');
    });

    test('不写进 prefs——一次崩溃不该在下次启动时凭空发出一句话', () async {
      final m = await _mgr();
      m.stagePrompt('srv-1', 'a');
      final reborn = await _mgr(); // 同一份 mock prefs，新的 manager
      expect(reborn.takeStagedPrompt('srv-1'), isNull);
    });

    test('hasStagedPrompt 只探测、不消费', () async {
      final m = await _mgr();
      m.stagePrompt('srv-1', 'a');
      expect(m.hasStagedPrompt('srv-1'), isTrue);
      // 多次调用不改变状态——不是 take 的别名。
      expect(m.hasStagedPrompt('srv-1'), isTrue);
      expect(m.takeStagedPrompt('srv-1'), 'a', reason: '真正取的时候还在');
      expect(m.hasStagedPrompt('srv-1'), isFalse);
    });

    test('没有 staged 时 hasStagedPrompt 为 false', () async {
      final m = await _mgr();
      expect(m.hasStagedPrompt('srv-1'), isFalse);
    });

    test(
        '调用方语义：initialQuery 非空时优先于槽，且槽必须被无条件清空——'
        '否则留着的话会滞留下来劫持下一次真正的空调用（见 '
        'terminal_screen._openAIPanel 的顺序：先 take，再 initialQuery ?? staged）',
        () async {
      final m = await _mgr();
      m.stagePrompt('srv-1', '后台任务 job-1 还在跑');
      const String? initialQuery = '请解释这条命令的作用和风险';

      // _openAIPanel 里的真实顺序：不管用不用得上，先无条件 take 掉。
      final staged = m.takeStagedPrompt('srv-1');
      final effectiveQuery = initialQuery ?? staged;

      expect(effectiveQuery, initialQuery, reason: '显式请求压过滞留的槽');
      expect(m.hasStagedPrompt('srv-1'), isFalse,
          reason: '槽已经被清空，不会留到下一次单纯点 AI 按钮的空调用里');
    });
  });
}
