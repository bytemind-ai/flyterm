import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_partition.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

ToolCall _c(String name, Map<String, dynamic> args) =>
    ToolCall(id: 'x', name: name, args: args);

void main() {
  // 用 defaultAllowRules 而不是空规则集 —— 「命中 allowlist」这件事本身
  // 就依赖 `cat *` / `ls *` 这些默认规则存在，空规则集下任何命令都判不出
  // allow，会让下面几条名字里写着「命中 allowlist」的用例名不副实。
  //
  // 这里顺带修正了任务描述里 `PermissionRuleSet(rules: [])` 的笔误：这个
  // 类的构造函数是位置参数（`const PermissionRuleSet(this.rules);`，见
  // permission_rules.dart），命名参数写法本身就编译不过。
  final rules = PermissionRuleSet(defaultAllowRules);

  bool spec(ToolCall c, {PermissionMode mode = PermissionMode.ask}) =>
      canSpeculate(c, rules: rules, mode: mode);

  test('只读且命中 allowlist 的 bash 可以抢跑', () {
    expect(spec(_c('bash', const {'command': 'ls -la /var/log'})), isTrue);
  });

  test('read_file / glob / grep 可以抢跑', () {
    // 三者都复用 checkReadFile → checkCommand('cat <path>', ...)，
    // defaultAllowRules 里的 `cat *` 覆盖了这三种调用（glob/grep 缺省
    // path 时判的是 `cat .`），实测确实都落在并行桶，断言按实际行为写。
    expect(spec(_c('read_file', const {'path': '/etc/hostname'})), isTrue);
    expect(spec(_c('glob', const {'pattern': '*.log'})), isTrue);
    expect(spec(_c('grep', const {'pattern': 'error'})), isTrue);
  });

  test('需审批的绝不抢跑', () {
    expect(spec(_c('bash', const {'command': 'rm -rf /tmp/x'})), isFalse);
  });

  test('写文件工具绝不抢跑——bypass 下也不行', () {
    for (final mode in PermissionMode.values) {
      expect(
          spec(_c('write_file', const {'path': '/a', 'content': 'x'}),
              mode: mode),
          isFalse,
          reason: 'write_file 在 $mode 下也不该抢跑');
      expect(
          spec(
              _c('edit_file', const {
                'path': '/a',
                'old_string': 'a',
                'new_string': 'b',
              }),
              mode: mode),
          isFalse,
          reason: 'edit_file 在 $mode 下也不该抢跑');
    }
  });

  test('本地工具不抢跑——它们本来就零成本，抢跑只会打乱事件顺序', () {
    expect(
        spec(_c('set_plan', const {
          'steps': ['a']
        })),
        isFalse);
    expect(spec(_c('read_terminal', const {})), isFalse);
    expect(spec(_c('load_skill', const {'name': 'x'})), isFalse);
    expect(spec(_c('list_servers', const {})), isFalse);
  });

  test('参数非法的不抢跑', () {
    expect(spec(_c('bash', const {})), isFalse);
    expect(spec(_c('bash', const {'command': '   '})), isFalse);
  });

  test('未知工具名不抢跑', () {
    expect(spec(_c('teleport', const {'x': 1})), isFalse);
  });

  // ---------------------------------------------------------------------
  // 下面几条是端到端测试：跑完整的 AgentLoop，验证 `_maybeSpeculate` /
  // `_takeSpeculation` / `_flushStreamedTextSoFar` 这几条真正接了线，
  // 不只是 `canSpeculate` 这个纯函数本身对（那已经在上面测过了）。
  // ---------------------------------------------------------------------

  test('抢跑命中：命令只执行一次', () async {
    final runner = FakeRunner();
    const call = ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'});
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[
        const TextDelta('先看看目录。'),
        const ToolCallReady(call),
        const StreamDone(AIResponse(text: '先看看目录。', toolCalls: [call])),
      ],
      <AgentChunk>[
        const StreamDone(AIResponse(text: '')),
      ],
    ]);
    final loop = makeLoop(provider: provider, runner: runner);

    await loop.send('go');

    expect(runner.ran.where((c) => c == 'ls').length, 1,
        reason: '抢跑命中之后不该在 StreamDone 之后再跑第二遍');
    final tm = loop.metrics.turns.first.tools.single;
    expect(tm.speculative, isTrue);
    expect(tm.speculativeHit, isTrue);
  });

  test('抢跑命中时事件顺序是 文字 → 工具卡 → 文字，且文本不重不漏', () async {
    final runner = FakeRunner();
    const call = ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'});
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[
        const TextDelta('前半段'),
        const ToolCallReady(call),
        const TextDelta('后半段'),
        const StreamDone(AIResponse(text: '前半段后半段', toolCalls: [call])),
      ],
      <AgentChunk>[
        const StreamDone(AIResponse(text: '')),
      ],
    ]);
    final loop = makeLoop(provider: provider, runner: runner);

    await loop.send('go');

    final kinds = loop.events
        .where((e) => e is AssistantTextEvent || e is ToolCallEvent)
        .map((e) => e.runtimeType)
        .toList();
    expect(kinds, [AssistantTextEvent, ToolCallEvent, AssistantTextEvent],
        reason: '卡片必须夹在两段文字中间，不能跑到文字前面去');

    final allText =
        loop.events.whereType<AssistantTextEvent>().map((e) => e.text).join();
    expect(allText, '前半段后半段', reason: '提前落一次、StreamDone 只落尾巴，拼起来不应重不应漏');
  });

  test('抢跑落空（cwd 变了）：重跑两次，旧卡被标记 superseded', () async {
    var cwd = '/tmp';
    // 抢跑真正发起执行（`FakeRunner.run` 被调用）的那一刻，模拟用户在这一
    // 瞬间 `cd` 到了别处——比在测试主体里随便找个时间点改更真实，因为它
    // 精确对应「判据快照之后、StreamDone 核对之前」这个窗口期。
    final runner = FakeRunner(onRun: (_) => cwd = '/other');
    const call = ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'});
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[
        const ToolCallReady(call),
        const StreamDone(AIResponse(toolCalls: [call])),
      ],
      <AgentChunk>[
        const StreamDone(AIResponse(text: '')),
      ],
    ]);
    final loop =
        makeLoop(provider: provider, runner: runner, cwdProvider: () => cwd);

    await loop.send('go');

    expect(runner.ran.where((c) => c == 'ls').length, 2,
        reason: '抢跑落空后命令要按正常路径重新跑一遍，加上抢跑那一次共两次');
    final superseded =
        loop.events.whereType<ToolCallEvent>().where((e) => e.superseded);
    expect(superseded, hasLength(1),
        reason: '只有抢跑那张卡是「作废」的，重跑产生的第二张卡是正常完成');
    final specTm =
        loop.metrics.turns.first.tools.where((t) => t.speculative).single;
    expect(specTm.speculativeHit, isFalse);
  });

  test('需审批的调用不抢跑', () async {
    final runner = FakeRunner();
    const call =
        ToolCall(id: 'c1', name: 'bash', args: {'command': 'rm -rf /tmp/x'});
    // 默认 ask 模式：`rm -rf` 不在 defaultAllowRules 里，必须弹审批——这条
    // 调用因此落在串行桶，`canSpeculate` 应该判 false。这里干脆不给
    // StreamDone：流式期间只要 `_maybeSpeculate` 没有真的调用 `_executeOne`，
    // 就不会创建 `ToolCallEvent`（`_executeCommandTool` 在触发审批等待
    // *之前* 就已经同步把卡片建好并塞进 `_events` 了——建卡本身不需要等审批
    // 结果）。
    //
    // 这条断言特意不查 `runner.ran`：`_executeCommandTool` 自己在触发审批
    // 之后、真正 `runner.run()` 之前还挡着一层 `_awaitApproval`，那层挡板
    // 本身就会让 runner 保持空——即使 `_maybeSpeculate` 里的 `canSpeculate`
    // 判断被错误地去掉了，`runner.ran` 依然是空的（这一点在做变异验证时
    // 实测确认过：注释掉判据那一行，这条测试原样通过，说明它测的不是
    // `_maybeSpeculate` 本身）。真正能分辨「有没有抢跑」的信号是「卡片
    // 建没建」——没有 `canSpeculate` 挡着，一张审批卡会在模型还没说完话时
    // 就凭空出现。
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[const ToolCallReady(call)],
    ]);
    final loop = makeLoop(provider: provider, runner: runner);

    await loop.send('go');

    expect(runner.ran, isEmpty, reason: '需审批的调用绝不能在 StreamDone 之前就执行');
    expect(loop.events.whereType<ToolCallEvent>(), isEmpty,
        reason: '需审批的调用连卡片都不该在 StreamDone 之前建出来——'
            '这才是真正区分「抢跑没发生」与「抢跑发生了但卡在审批上」的信号');
  });

  test('取消发生在抢跑之后不留未捕获异常', () async {
    late AgentLoop loop;
    // cancel() 在抢跑真正开始执行（`FakeRunner.run` 被调用）的那一刻触发，
    // 精确复现「抢跑已经飞出去、随后用户按了 Stop」这个时序。
    final runner = FakeRunner(onRun: (_) => loop.cancel());
    const call = ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'});
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[
        const ToolCallReady(call),
        const StreamDone(AIResponse(toolCalls: [call])),
      ],
    ]);
    loop = makeLoop(provider: provider, runner: runner);

    await loop.send('go').timeout(const Duration(seconds: 5),
        onTimeout: () => fail('loop 挂死：抢跑之后取消没有把 loop 唤醒'));

    // 再等一会儿，让抢跑那个 Future 真正落地——`_discardSpeculations` 必须
    // 已经在观察它，否则它的结果/错误会变成未被捕获的异常，使这条测试因为
    // 一个与断言无关的理由失败（或者在真机上炸出一个无法归因的红屏）。
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(loop.stopReason, AgentStopReason.userCancelled);
  });

  test('一轮里可抢跑的超过并发上限时，超出的不抢', () async {
    final runner = FakeRunner();
    const calls = [
      ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'}),
      ToolCall(id: 'c2', name: 'bash', args: {'command': 'ps aux'}),
      ToolCall(id: 'c3', name: 'bash', args: {'command': 'df -h'}),
      ToolCall(id: 'c4', name: 'bash', args: {'command': 'free -m'}),
    ];
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[
        for (final c in calls) ToolCallReady(c),
        const StreamDone(AIResponse(toolCalls: calls)),
      ],
      <AgentChunk>[
        const StreamDone(AIResponse(text: '')),
      ],
    ]);
    final loop = makeLoop(provider: provider, runner: runner);

    await loop.send('go');

    final specCount =
        loop.metrics.turns.first.tools.where((t) => t.speculative).length;
    expect(specCount, 3,
        reason: '_kMaxParallel 是 3——并发上限对抢跑同样生效，第 4 条只能老实等 StreamDone');
  });

  group('本机调用不去取服务器列表', () {
    // 这一组守的是「文字 → 工具卡 → 文字」那个事件顺序承诺**在生产延迟下**
    // 也成立。
    //
    // 起因：`_executeCommandTool` 原先第一行就 `await serverListProvider()`，
    // 而 `ToolCallEvent` 在它之后才创建并塞进 `_events`。生产实现要跑一次
    // SQLite + 逐台服务器读 keystore，所以只要它比「模型说完剩下那点话」更
    // 慢，抢跑的工具卡就排在 StreamDone 时同步追加的尾巴文字后面，渲染成
    // 「文字 → 文字 → 工具卡」，与设计目标正好相反。
    //
    // **为什么不直接测事件顺序**：那条测试已经存在，而且它在假时序下恒绿——
    // 测试里 `serverListProvider` 默认未设置（`await null` 只是一次微任务），
    // 根本复现不出生产的延迟量级。所以这里改成锁**机制**：断言本机调用压根
    // 不碰那个 provider。机制成立，顺序就不依赖时序运气。
    test('本机 bash 一次都不调 serverListProvider', () async {
      var calls = 0;
      final loop = makeLoop(
        serverListProvider: () async {
          calls++;
          return const <ServerListEntry>[];
        },
        runner: FakeRunner(),
        provider: FakeProvider([
          const AIResponse(toolCalls: [
            ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'}),
          ]),
          const AIResponse(text: 'done'),
        ]),
      );

      await loop.send('go');

      expect(calls, 0,
          reason: 'args[server] 为 null 时 resolveServerTarget 第一行就返回，'
              'servers 一个字节都用不上——这次 await 是纯浪费，且它让工具卡'
              '晚于尾巴文字落地');
    });

    test('跨机调用仍然会取服务器列表', () async {
      var calls = 0;
      final loop = makeLoop(
        serverListProvider: () async {
          calls++;
          return const [
            ServerListEntry(
                id: 's1', name: 'box', host: '10.0.0.9', credsOk: true),
          ];
        },
        runner: FakeRunner(),
        provider: FakeProvider([
          const AIResponse(toolCalls: [
            ToolCall(id: 'c1', name: 'bash', args: {
              'command': 'ls',
              'server': 'box',
            }),
          ]),
          const AIResponse(text: 'done'),
        ]),
      );

      await loop.send('go');

      expect(calls, greaterThan(0),
          reason: '跨机要靠名字解析出 serverId，这次 await 是必需的——'
              '上一条测试的优化不能把它一起砍掉');
    });
  });
}
