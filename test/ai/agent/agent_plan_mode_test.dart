import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

AIResponse writeCall(String id, String path, String content) =>
    AIResponse(toolCalls: [
      ToolCall(id: id, name: 'write_file', args: {
        'path': path,
        'content': content,
        'description': 'write it',
      })
    ]);

void main() {
  group('plan 模式：写文件进队列', () {
    test('write_file 不执行、进队列、回填 deferred', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/app.conf', 'x=1'),
        const AIResponse(text: 'done investigating'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('fix the config');

      // 一条命令都没跑
      expect(r.ran, isEmpty);
      expect(loop.planQueue, hasLength(1));
      expect(loop.planQueue.single.name, equals('write_file'));

      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.status, equals(ToolCallStatus.deferred));

      // 回填的措辞两件事都要说到
      final tool = p.seen.last.lastWhere((m) => m.role == 'tool');
      final content = tool.toolResults!.single.content;
      expect(content, contains('deferred'));
      expect(content, contains('NOT modified yet'));
    });

    test('每个被推迟的 tool_use 恰好有一个 tool_result', () async {
      // wire protocol 的硬约束：悬空的 tool_use 会让下一轮请求被服务端
      // 直接拒绝。断言历史里的配对完整性，而不只看回填内容。
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'a'),
        writeCall('c2', '/etc/b.conf', 'b'),
        const AIResponse(text: 'done'),
      ]);
      final loop = makeLoop(
        provider: p,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('fix both');

      final calls = <String>[];
      final results = <String>[];
      for (final m in loop.debugHistory) {
        for (final c in m.toolCalls ?? const <ToolCall>[]) {
          calls.add(c.id);
        }
        for (final r in m.toolResults ?? const <ToolResult>[]) {
          results.add(r.callId);
        }
      }
      expect(calls, equals(['c1', 'c2']));
      expect(results, equals(['c1', 'c2']));
    });

    test('重复 defer 同一次写入被去重', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/app.conf', 'same'),
        writeCall('c2', '/etc/app.conf', 'same'),
        const AIResponse(text: 'done'),
      ]);
      final loop = makeLoop(
        provider: p,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('fix it twice');

      // 队列里只有一份
      expect(loop.planQueue, hasLength(1));
      final last = p.seen.last.lastWhere((m) => m.role == 'tool');
      expect(last.toolResults!.single.content, contains('already queued'));
    });

    test('不同路径不会被误去重', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'x'),
        writeCall('c2', '/etc/b.conf', 'x'),
        const AIResponse(text: 'done'),
      ]);
      final loop = makeLoop(
        provider: p,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('fix both');

      expect(loop.planQueue, hasLength(2));
    });

    test('readOnly 模式下写文件照旧弹审批，不进队列', () async {
      // 这是「严格的」那一档：写文件弹审批卡。旧命名下这档叫 `ask`，
      // 2026-10-13 改名后叫 `readOnly`（`ask` 则继承了旧 `plan` 的攒批语义）。
      final p = FakeProvider([writeCall('c1', '/etc/app.conf', 'x')]);
      final loop = makeLoop(
        provider: p,
        mode: PermissionMode.readOnly,
        toolSpecs: () => fullToolSpecs,
      );

      final f = loop.send('fix');
      await Future.delayed(Duration.zero);

      expect(loop.state, equals(AgentLoopState.awaitingApproval));
      expect(loop.planQueue, isEmpty);

      loop.cancel();
      await f;
    });

    test('bypass 模式下写文件直接执行，不进队列', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/app.conf', 'x'),
        const AIResponse(text: 'done'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.bypass,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('fix');

      expect(r.ran, hasLength(1));
      expect(loop.planQueue, isEmpty);
    });
  });

  group('plan 模式：bash 命令由用户选择', () {
    test('用户点「加入方案」时命令进队列而不执行', () async {
      final p = FakeProvider([
        bashCall('c1', 'systemctl restart nginx'),
        const AIResponse(text: 'proposed'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
      );

      final f = loop.send('restart it');
      await Future.delayed(Duration.zero);

      // 非白名单命令仍然弹卡（探查不能断流）
      expect(loop.state, equals(AgentLoopState.awaitingApproval));
      final ev = loop.events.whereType<ToolCallEvent>().single;

      loop.respondApproval(ev.seq, ApprovalDecision.addToPlan);
      await f;

      expect(r.ran, isEmpty);
      expect(loop.planQueue, hasLength(1));
      expect(ev.status, equals(ToolCallStatus.deferred));

      final tool = p.seen.last.lastWhere((m) => m.role == 'tool');
      expect(tool.toolResults!.single.content, contains('has NOT run yet'));
    });

    test('用户点「允许一次」时照常执行', () async {
      final p = FakeProvider([
        bashCall('c1', 'systemctl restart nginx'),
        const AIResponse(text: 'done'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
      );

      final f = loop.send('restart it');
      await Future.delayed(Duration.zero);
      final ev = loop.events.whereType<ToolCallEvent>().single;
      loop.respondApproval(ev.seq, ApprovalDecision.allowOnce);
      await f;

      expect(r.ran, equals(['systemctl restart nginx']));
      expect(loop.planQueue, isEmpty);
    });

    test('命中白名单的命令在 plan 模式下静默执行', () async {
      final p = FakeProvider([
        bashCall('c1', 'systemctl status nginx'),
        const AIResponse(text: 'it is down'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
      );

      await loop.send('why 502?');

      expect(r.ran, equals(['systemctl status nginx']));
      expect(loop.planQueue, isEmpty);
    });
  });

  group('提案事件与归档', () {
    test('模型停下时队列非空 → 发提案事件而不是 StoppedEvent', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'a'),
        const AIResponse(text: 'here is what I would change'),
      ]);
      final loop = makeLoop(
        provider: p,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('fix it');

      expect(loop.events.last, isA<PlanProposalEvent>());
      expect(loop.events.whereType<StoppedEvent>(), isEmpty);
      expect((loop.events.last as PlanProposalEvent).calls, hasLength(1));
      expect(loop.stopReason, equals(AgentStopReason.completed));
      // 模型的结论文本仍然要在事件流里——提案不该把它顶掉
      expect(
        loop.events.whereType<AssistantTextEvent>().last.text,
        equals('here is what I would change'),
      );
    });

    test('队列为空时照旧发 StoppedEvent', () async {
      final p = FakeProvider([const AIResponse(text: 'all good')]);
      final loop = makeLoop(provider: p, mode: PermissionMode.ask);

      await loop.send('status?');

      expect(loop.events.last, isA<StoppedEvent>());
      expect(loop.events.whereType<PlanProposalEvent>(), isEmpty);
    });

    test('队列进归档，恢复后还在——否则重开面板批准按钮就没东西可执行', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'a'),
        const AIResponse(text: 'proposal'),
      ]);
      final loop = makeLoop(
        provider: p,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );
      await loop.send('fix it');

      final archive = loop.toArchive();
      final restored = makeLoop(
        provider: FakeProvider([]),
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
        restoreFrom: archive,
      );

      expect(restored.planQueue, hasLength(1));
      expect(restored.planQueue.single.args['path'], equals('/etc/a.conf'));
      expect(restored.events.last, isA<PlanProposalEvent>());
      expect(
        (restored.events.last as PlanProposalEvent).calls.single.name,
        equals('write_file'),
      );
    });

    test('恢复后去重仍然生效——不能因为换了实例就允许重复', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'a'),
        const AIResponse(text: 'proposal'),
      ]);
      final loop = makeLoop(
        provider: p,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );
      await loop.send('fix it');

      final restored = makeLoop(
        provider: FakeProvider([
          writeCall('c9', '/etc/a.conf', 'a'),
          const AIResponse(text: 'again'),
        ]),
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
        restoreFrom: loop.toArchive(),
      );
      await restored.send('same fix again');

      // 同一条编辑不该因为换了实例就能再入队一次
      expect(restored.planQueue, hasLength(1));
    });

    test('归档里的坏队列记录不该毁掉整次恢复', () async {
      final archive = {
        'events': <dynamic>[],
        'history': <dynamic>[],
        'planQueue': <dynamic>[
          {'name': 'write_file'}, // 缺 id，ToolCall.fromJson 会抛
          {'id': 'ok', 'name': 'write_file', 'args': {'path': '/etc/x'}},
        ],
      };
      final loop = makeLoop(
        provider: FakeProvider([]),
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
        restoreFrom: archive,
      );

      // 坏的那条被跳过，好的那条还在
      expect(loop.planQueue, hasLength(1));
      expect(loop.planQueue.single.id, equals('ok'));
    });
  });

  group('批准与丢弃', () {
    test('批准后逐条执行，结果以 user 消息注入而不是 tool_result', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'a=1'),
        const AIResponse(text: 'proposal'),
        const AIResponse(text: 'all applied'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );
      await loop.send('fix it');
      expect(r.ran, isEmpty);

      await loop.approvePlan();

      // 真的跑了
      expect(r.ran, hasLength(1));
      expect(loop.planQueue, isEmpty);

      // 结果以 user 消息进历史
      final userMsgs =
          loop.debugHistory.where((m) => m.role == 'user').toList();
      expect(userMsgs.last.content, contains('approved the plan'));

      // 关键：没有给已用掉的 c1 再发第二个 tool_result
      final resultIds = <String>[];
      for (final m in loop.debugHistory) {
        for (final tr in m.toolResults ?? const <ToolResult>[]) {
          resultIds.add(tr.callId);
        }
      }
      expect(resultIds.where((id) => id == 'c1'), hasLength(1));
    });

    test('批准后 loop 继续跑，模型能看到结果并给结论', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'a=1'),
        const AIResponse(text: 'proposal'),
        const AIResponse(text: 'verified, all good'),
      ]);
      final loop = makeLoop(
        provider: p,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );
      await loop.send('fix it');
      await loop.approvePlan();

      expect(loop.stopReason, equals(AgentStopReason.completed));
      expect(
        loop.events.whereType<AssistantTextEvent>().last.text,
        equals('verified, all good'),
      );
    });

    test('批准执行时不再弹审批、不再回队列', () async {
      // 若执行时又走一遍判定，write_file 会再次被 deferToPlan 拦回队列，
      // 变成无限循环。
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'a=1'),
        const AIResponse(text: 'proposal'),
        const AIResponse(text: 'done'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );
      await loop.send('fix it');

      await loop.approvePlan();

      expect(r.ran, hasLength(1));
      expect(loop.planQueue, isEmpty);
      expect(loop.state, isNot(equals(AgentLoopState.awaitingApproval)));
    });

    test('执行中途失败 → 停在那条，剩余留在队列', () async {
      final p = FakeProvider([
        AIResponse(toolCalls: [
          const ToolCall(id: 'c1', name: 'write_file', args: {
            'path': '/etc/a.conf',
            'content': 'a',
            'description': 'first',
          }),
          const ToolCall(id: 'c2', name: 'write_file', args: {
            'path': '/etc/b.conf',
            'content': 'b',
            'description': 'second',
          }),
        ]),
        const AIResponse(text: 'proposal'),
        const AIResponse(text: 'reported'),
      ]);
      // 写就失败
      final r = FakeRunner(
        result: const CommandOutput(
          stdout: '',
          stderr: 'Permission denied',
          exitCode: 1,
        ),
      );
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );
      await loop.send('fix both');
      expect(loop.planQueue, hasLength(2));

      await loop.approvePlan();

      // 只跑了第一条，第二条还在队列里
      expect(r.ran, hasLength(1));
      expect(loop.planQueue, hasLength(1));
      expect(loop.planQueue.single.args['path'], equals('/etc/b.conf'));
      final userMsgs =
          loop.debugHistory.where((m) => m.role == 'user').toList();
      expect(userMsgs.last.content, contains('FAILED'));
    });

    test('丢弃清空队列并收掉提案卡', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'a'),
        const AIResponse(text: 'proposal'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );
      await loop.send('fix it');

      loop.discardPlan();

      expect(loop.planQueue, isEmpty);
      expect(loop.events.whereType<PlanProposalEvent>(), isEmpty);
      expect(loop.events.last, isA<StoppedEvent>());
      expect(r.ran, isEmpty);
    });

    test('丢弃后去重键也清了——同一条编辑可以重新提', () async {
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'a'),
        const AIResponse(text: 'proposal'),
      ]);
      final loop = makeLoop(
        provider: p,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );
      await loop.send('fix it');
      loop.discardPlan();

      // 换个新 loop 不算，就用这个：再问一次同样的事
      final p2 = FakeProvider([
        writeCall('c9', '/etc/a.conf', 'a'),
        const AIResponse(text: 'proposal again'),
      ]);
      final loop2 = makeLoop(
        provider: p2,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
        restoreFrom: loop.toArchive(),
      );
      await loop2.send('fix it again');

      expect(loop2.planQueue, hasLength(1));
    });

    test('队列为空时 approvePlan 是空操作', () async {
      final p = FakeProvider([const AIResponse(text: 'ok')]);
      final loop = makeLoop(provider: p, mode: PermissionMode.ask);
      await loop.send('hi');

      await loop.approvePlan();

      expect(loop.planQueue, isEmpty);
    });

    test('运行中调 approvePlan 是空操作，不会插队', () async {
      final p = FakeProvider([bashCall('c1', 'systemctl restart nginx')]);
      final loop = makeLoop(provider: p, mode: PermissionMode.ask);

      final f = loop.send('restart');
      await Future.delayed(Duration.zero);
      // 此刻卡在等审批
      await loop.approvePlan(); // 应当什么都不做

      expect(loop.state, equals(AgentLoopState.awaitingApproval));
      loop.cancel();
      await f;
    });

    test('中途切到 bypass 不会让队列自动执行——切模式不等于批准', () async {
      // 队列只由 approvePlan 消费，modeProvider 变化碰不到它。这条测试把那个
      // 结构性保证钉成行为契约。
      var mode = PermissionMode.ask;
      final p = FakeProvider([
        writeCall('c1', '/etc/a.conf', 'a'),
        const AIResponse(text: 'proposal'),
      ]);
      final r = FakeRunner();
      final loop = AgentLoop(
        providerProvider: () => p,
        runnerProvider: (_) => r,
        rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
        modeProvider: () => mode,
        toolSpecsProvider: () => fullToolSpecs,
        onRuleAdded: (_) {},
        systemPromptProvider: (_) => 'test prompt',
        cwdProvider: () => '/tmp',
      );
      await loop.send('fix it');
      expect(loop.planQueue, hasLength(1));
      expect(r.ran, isEmpty);

      mode = PermissionMode.bypass;

      // 没有任何调用，队列原样不动
      expect(loop.planQueue, hasLength(1));
      expect(r.ran, isEmpty);
    });
  });

  // 这一组补的是三条「落穿」——`addToPlan` 曾经只在 bash 路径被消费，写文件
  // 和 edit_file 的审批点都只判 reject，于是用户点「加入方案」会**立刻执行**。
  // 触发条件恰好是全系统风险最高的那一格：plan 模式下写文件只在**凭据边界
  // 命中**时才会弹卡（其余情况走 deferToPlan 不弹卡）。
  group('addToPlan 在每条审批路径上都不能落穿', () {
    test('write_file 命中凭据边界 + 加入方案 → 不执行、不入队', () async {
      final p = FakeProvider([
        writeCall('c1', '/root/.aws/credentials', 'x=1'),
        const AIResponse(text: 'reported'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );

      final f = loop.send('rotate the key');
      await Future.delayed(Duration.zero);

      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.check.denyHit, isTrue, reason: '这条路径的前提是凭据命中');
      loop.respondApproval(ev.seq, ApprovalDecision.addToPlan);
      await f;

      // 最要紧的一条：一个字节都不能写出去
      expect(r.ran, isEmpty, reason: '用户说的是「别现在做」，不是「现在做」');
      // 凭据类操作也不进队列——那道警示不能稀释成提案卡里的一行
      expect(loop.planQueue, isEmpty);
      expect(ev.status, equals(ToolCallStatus.rejected));

      final tool = p.seen.last.lastWhere((m) => m.role == 'tool');
      expect(tool.toolResults!.single.content, contains('cannot go into'));
    });

    test('bash 命中凭据边界 + 加入方案 → 同样不执行、不入队', () async {
      final p = FakeProvider([
        bashCall('c1', 'cat /home/u/.ssh/id_rsa'),
        const AIResponse(text: 'reported'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(provider: p, runner: r, mode: PermissionMode.ask);

      final f = loop.send('check the key');
      await Future.delayed(Duration.zero);
      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.check.denyHit, isTrue);
      loop.respondApproval(ev.seq, ApprovalDecision.addToPlan);
      await f;

      expect(r.ran, isEmpty);
      expect(loop.planQueue, isEmpty);
    });

    test('edit_file 读阶段 + 加入方案 → 不读，文件内容不出境', () async {
      // 「把一次读加入方案」语义是空的（读是为了算 diff），所以按拒绝处理。
      // 更实际的是：读会把文件内容发给模型厂商，落穿等于用户点了「稍后再说」
      // 却把凭据文件读了出去。
      final p = FakeProvider([
        AIResponse(toolCalls: [
          const ToolCall(id: 'c1', name: 'edit_file', args: {
            'path': '/root/.ssh/id_rsa',
            'old_string': 'a',
            'new_string': 'b',
            'description': 'rotate',
          })
        ]),
        const AIResponse(text: 'reported'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );

      final f = loop.send('rotate it');
      await Future.delayed(Duration.zero);
      final ev = loop.events.whereType<ToolCallEvent>().first;
      loop.respondApproval(ev.seq, ApprovalDecision.addToPlan);
      await f;

      expect(r.ran, isEmpty, reason: '连读都不该发生');
      expect(loop.planQueue, isEmpty);
    });

    test('非凭据的 edit_file 读阶段 + 加入方案 → 照常读，不是拒绝', () async {
      // 读卡在非凭据情形下照样会弹：这里模拟「用户在规则页关掉了默认放行组」
      // （规则页有 setBuiltinGroupEnabled 这个开关）。此时 `cat <path>` 不再
      // 命中 allowlist → readCheck 是 noMatchingRule、denyHit=false。
      //
      // 曾经这里无条件拒绝，于是按钮写着「加入方案」、点下去却得到
      // rejected + 「User rejected this command.」——按钮和行为相反，而且
      // 这个配置下 plan 模式的 edit_file 整条路走不通。
      //
      // 正确行为是放过这次读：写阶段必然命中 deferToPlan，用户想要的入队
      // 会在那里自动发生。
      final p = FakeProvider([
        AIResponse(toolCalls: [
          const ToolCall(id: 'c1', name: 'edit_file', args: {
            'path': '/etc/app.conf',
            'old_string': 'old',
            'new_string': 'new',
            'description': '改配置',
          })
        ]),
        const AIResponse(text: 'proposed'),
      ]);
      // 读会成功但内容对不上 old_string，阶段二会报错——不影响本测试的
      // 断言目标（读到底有没有发生）。
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
        // 空规则集 = 用户把默认放行组全关了
        rules: const PermissionRuleSet([]),
        toolSpecs: () => fullToolSpecs,
      );

      final f = loop.send('fix it');
      await Future.delayed(Duration.zero);
      final readEv = loop.events.whereType<ToolCallEvent>().first;
      expect(readEv.check.denyHit, isFalse, reason: '这条路径的前提是非凭据');
      loop.respondApproval(readEv.seq, ApprovalDecision.addToPlan);
      await f;

      // 关键：读真的发生了，不是被当成拒绝
      expect(r.ran, isNotEmpty, reason: '非凭据的读不该被拒绝');
      expect(readEv.status, isNot(equals(ToolCallStatus.rejected)));
    });

    test('非凭据的写文件 + 加入方案 → 正常入队（这条路才该 defer）', () async {
      // 注意：这条路径**通过界面到不了**——UI 的 planMode 只在 mode==plan 时
      // 为 true，而 plan 档下写文件走 deferToPlan 根本不弹卡。留着它是给 loop
      // 自己钉不变量：loop 不该依赖 UI 是否藏了按钮。
      //
      // ask 档下写文件走 needApproval 且不是凭据命中，此时「加入方案」应当
      // 真的入队。用来确认上面几条修的是「落穿」，不是把 defer 一并堵死。
      final p = FakeProvider([
        writeCall('c1', '/etc/app.conf', 'x=1'),
        const AIResponse(text: 'proposed'),
      ]);
      final r = FakeRunner();
      final loop = makeLoop(
        provider: p,
        runner: r,
        mode: PermissionMode.ask,
        toolSpecs: () => fullToolSpecs,
      );

      final f = loop.send('fix it');
      await Future.delayed(Duration.zero);
      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.check.denyHit, isFalse);
      loop.respondApproval(ev.seq, ApprovalDecision.addToPlan);
      await f;

      expect(r.ran, isEmpty);
      expect(loop.planQueue, hasLength(1));
      expect(ev.status, equals(ToolCallStatus.deferred));
      final tool = p.seen.last.lastWhere((m) => m.role == 'tool');
      expect(tool.toolResults!.single.content, contains('NOT modified yet'));
    });
  });

  test('提案卡还在时用户追问 → 只留一张活卡，不留死键', () async {
    // 旧那张卡的「批准」会是个静默死键：队列已被新卡接管，点它命中
    // approvePlan 的 _planQueue.isEmpty 早退，什么都不发生——比界面上有
    // 两张卡更容易让人以为 app 坏了。
    final p = FakeProvider([
      writeCall('c1', '/etc/a.conf', 'a'),
      const AIResponse(text: 'proposal 1'),
      const AIResponse(text: 'proposal 2'),
    ]);
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.ask,
      toolSpecs: () => fullToolSpecs,
    );
    await loop.send('fix it');
    expect(loop.events.whereType<PlanProposalEvent>(), hasLength(1));

    // 提案卡还挂着，用户又问了一句
    await loop.send('and check the logs too');

    expect(loop.events.whereType<PlanProposalEvent>(), hasLength(1),
        reason: '同一时刻只能有一张活的提案卡');
    // 队列本身不动——「追问时该不该自动丢弃已攒的队列」是产品语义，
    // 这里不预判
    expect(loop.planQueue, hasLength(1));
  });
}
