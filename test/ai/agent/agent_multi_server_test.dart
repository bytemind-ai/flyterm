import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

void main() {
  test('targetServerName 进归档 —— 恢复出来的卡片要知道打的哪台机器', () {
    final ev = ToolCallEvent(
      seq: 2,
      callId: 'c1',
      toolName: 'bash',
      displayCommand: '[web-1] uptime',
      description: '看负载',
      check: const CheckResult(decision: ToolDecision.allow),
      targetServerName: 'web-1',
    )
      ..status = ToolCallStatus.done
      ..output = 'up 3 days';

    final back =
        agentEventsFromJson([agentEventToJson(ev)]).single as ToolCallEvent;
    expect(back.targetServerName, equals('web-1'));
    expect(back.displayCommand, equals('[web-1] uptime'));
  });

  test('本机调用的 targetServerName 为 null，且不写进归档体积', () {
    final ev = ToolCallEvent(
      seq: 0,
      callId: 'c0',
      toolName: 'bash',
      displayCommand: 'uptime',
      description: 'x',
      check: const CheckResult(decision: ToolDecision.allow),
    );
    final json = agentEventToJson(ev);
    expect(json.containsKey('targetServerName'), isFalse);
    final back = agentEventsFromJson([json]).single as ToolCallEvent;
    expect(back.targetServerName, isNull);
  });

  final fleet = [
    const ServerListEntry(
        id: 'id-1', name: 'web-1', groupName: 'prod', host: '10.0.1.11',
        credsOk: true),
    const ServerListEntry(
        id: 'id-2', name: 'web-2', groupName: 'prod', host: '10.0.1.12',
        credsOk: true),
  ];

  AIResponse bashOn(String cmd, String? server) => AIResponse(toolCalls: [
        ToolCall(id: 'b1', name: 'bash', args: {
          'command': cmd,
          'description': '查一下',
          if (server != null) 'server': server,
        })
      ]);

  group('bash 的 server 参数', () {
    test('不给 server → 打当前会话那台（现有行为零回归）', () async {
      final local = FakeRunner();
      final remote = FakeRunner();
      final loop = makeLoop(
        provider: FakeProvider([bashOn('uptime', null),
            const AIResponse(text: 'ok')]),
        runner: local,
        runnersByServerId: {'id-1': remote},
        servers: fleet,
        mode: PermissionMode.bypass,
      );

      await loop.send('q');

      expect(local.ran, contains('uptime'));
      expect(remote.ran, isEmpty);
      expect(loop.events.whereType<ToolCallEvent>().single.targetServerName,
          isNull);
    });

    test('给了 server → 打那台，事件与展示都带机器名', () async {
      final local = FakeRunner();
      final remote = FakeRunner();
      final loop = makeLoop(
        provider: FakeProvider([bashOn('uptime', 'web-1'),
            const AIResponse(text: 'ok')]),
        runner: local,
        runnersByServerId: {'id-1': remote},
        servers: fleet,
        mode: PermissionMode.bypass,
      );

      await loop.send('q');

      expect(remote.ran, contains('uptime'));
      expect(local.ran, isEmpty, reason: '不能打到当前会话那台');
      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.targetServerName, equals('web-1'));
      expect(ev.displayCommand, startsWith('[web-1]'));
    });

    test('未知机器名 → 不执行，错误里附可用列表', () async {
      final local = FakeRunner();
      final provider = FakeProvider(
          [bashOn('uptime', 'nope'), const AIResponse(text: 'ok')]);
      final loop = makeLoop(
        provider: provider,
        runner: local,
        servers: fleet,
        mode: PermissionMode.bypass,
      );

      await loop.send('q');

      expect(local.ran, isEmpty);
      final toolMsg = provider.seen[1].lastWhere((m) => m.role == 'tool');
      expect(toolMsg.toolResults!.single.isError, isTrue);
      expect(toolMsg.toolResults!.single.content, contains('web-1'));
    });

    test('跨机调用不调用 cwdProvider —— 不是「调了再丢」', () async {
      var cwdCalls = 0;
      final remote = FakeRunner();
      final provider = FakeProvider(
          [bashOn('uptime', 'web-1'), const AIResponse(text: 'ok')]);
      final loop = AgentLoop(
        providerProvider: () => provider,
        runnerProvider: (id) => id == null ? FakeRunner() : remote,
        rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
        modeProvider: () => PermissionMode.bypass,
        onRuleAdded: (_) {},
        systemPromptProvider: (_) => 'test prompt',
        cwdProvider: () {
          cwdCalls++;
          return '/home/u';
        },
        toolSpecsProvider: () => fullToolSpecs,
        serverListProvider: () async => fleet,
      );

      await loop.send('q');

      expect(remote.cwds, equals([null]),
          reason: '跨机执行必须用 null cwd');
      expect(cwdCalls, equals(0),
          reason: '跨机执行不读本机 cwd，cwdProvider 一次都不该被调用');
    });
  });

  group('list_servers', () {
    AIResponse listCall() => AIResponse(toolCalls: [
          ToolCall(id: 'l1', name: 'list_servers', args: {})
        ]);

    test('只进 full 档', () {
      expect(fullToolSpecs.map((t) => t.name), contains('list_servers'));
      expect(leanToolSpecs.map((t) => t.name), isNot(contains('list_servers')));
    });

    test('返回名字/组/主机/凭据可用性，不含内部 id', () async {
      final provider =
          FakeProvider([listCall(), const AIResponse(text: 'ok')]);
      final loop = makeLoop(
        provider: provider,
        servers: [
          ...fleet,
          const ServerListEntry(
              id: 'id-db', name: 'db', host: '10.0.2.9', credsOk: false),
        ],
        mode: PermissionMode.bypass,
        // list_servers 只在 full 档声明；makeLoop 默认 lean，这里显式切到
        // full，否则调用会先撞上「Unknown tool」的档位闸门。
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('有哪些机器');

      final content =
          provider.seen[1].lastWhere((m) => m.role == 'tool')
              .toolResults!.single.content;
      expect(content, contains('web-1'));
      expect(content, contains('prod'));
      expect(content, contains('10.0.1.11'));
      expect(content, contains('db'));
      expect(content, contains('false'), reason: 'db 的 creds_ok 是 false');
      expect(content, isNot(contains('id-1')), reason: '内部 id 不该发出去');
    });

    test('不走审批也不产生 ToolCallEvent —— 它什么都不执行', () async {
      final loop = makeLoop(
        provider: FakeProvider([listCall(), const AIResponse(text: 'ok')]),
        servers: fleet,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('有哪些机器');

      expect(loop.pendingApprovals, isEmpty);
      expect(loop.events.whereType<ToolCallEvent>(), isEmpty);
    });

    test('没有 serverListProvider 时返回空列表而不是崩', () async {
      final provider =
          FakeProvider([listCall(), const AIResponse(text: 'ok')]);
      final loop = makeLoop(
        provider: provider,
        mode: PermissionMode.bypass,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('有哪些机器');

      final r = provider.seen[1].lastWhere((m) => m.role == 'tool')
          .toolResults!.single;
      expect(r.isError, isFalse);
      expect(r.content, contains('[]'));
    });
  });

  group('写文件工具的 server 参数', () {
    test('write_file 跨机：命令打到目标机，事件记下机器名', () async {
      final local = FakeRunner();
      final remote = FakeRunner();
      final loop = makeLoop(
        provider: FakeProvider([
          AIResponse(toolCalls: [
            ToolCall(id: 'w1', name: 'write_file', args: {
              'path': '/etc/motd',
              'content': 'hi',
              'description': '改欢迎语',
              'server': 'web-2',
            })
          ]),
          const AIResponse(text: 'ok'),
        ]),
        runner: local,
        runnersByServerId: {'id-2': remote},
        servers: fleet,
        mode: PermissionMode.bypass,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('q');

      expect(remote.ran, isNotEmpty, reason: '写入必须发到 web-2');
      expect(local.ran, isEmpty);
      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.targetServerName, equals('web-2'));
      expect(ev.displayCommand, startsWith('[web-2]'));
    });

    test('write_file 未知机器名 → 不写，回错误', () async {
      final local = FakeRunner();
      final provider = FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'w1', name: 'write_file', args: {
            'path': '/etc/motd',
            'content': 'hi',
            'description': 'x',
            'server': 'ghost',
          })
        ]),
        const AIResponse(text: 'ok'),
      ]);
      final loop = makeLoop(
        provider: provider,
        runner: local,
        servers: fleet,
        mode: PermissionMode.bypass,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('q');

      expect(local.ran, isEmpty);
      expect(
          provider.seen[1].lastWhere((m) => m.role == 'tool')
              .toolResults!.single.isError,
          isTrue);
    });
  });

  test('撤销跨机写入时，拷回命令发到当初那台机器', () async {
    final local = FakeRunner();
    final remote = FakeRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'w1', name: 'write_file', args: {
            'path': '/etc/motd',
            'content': 'hi',
            'description': 'x',
            'server': 'web-2',
          })
        ]),
        const AIResponse(text: 'ok'),
      ]),
      runner: local,
      runnersByServerId: {'id-2': remote},
      servers: fleet,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
    );

    await loop.send('q');
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.backupPath, isNotNull, reason: '前提：写入成功并记了备份');

    remote.ran.clear();
    local.ran.clear();
    final ok = await loop.undoEdit(ev.seq);

    expect(ok, isTrue);
    expect(remote.ran, isNotEmpty, reason: '拷回命令必须发到 web-2');
    expect(local.ran, isEmpty, reason: '不能在当前会话那台上拷回');
  });
}
