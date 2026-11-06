import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_partition.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// 抢跑的**恰好执行一次**保证。
///
/// `agent_speculative_test.dart` 测的是「这条能不能起飞」（纯函数
/// `canSpeculate`）与几条端到端时序。这个文件守的是另一件事：**一条命令在
/// 远端只会真的跑一次。**
///
/// 它对应一个真实故障 —— 一次「创建凌晨 3 点磁盘检查」的会话里，每一条
/// bash 都在远端执行了两遍，并在用户的 crontab 里留下两条一模一样的记录。
/// 两个缺陷叠加造成：
///
/// - **D1**：落地判据用 `identical(s.rules, rulesProvider())` 比较权限规则，
///   而生产的 `rulesProvider` 每次返回新对象 → 判据恒假 → 抢跑结果无条件
///   丢弃重跑。
/// - **D2**：`canSpeculate` 的判据是「免审批」而非「只读」，于是
///   `bypass` 档和用户自加规则放行的**写**命令也会被抢跑，丢弃重跑时就把
///   副作用做了两遍。
void main() {
  ToolCall bash(String id, String cmd) => ToolCall(id: id, name: 'bash', args: {
        'command': cmd,
        'description': '看一眼',
      });

  AIResponse one(ToolCall c) => AIResponse(toolCalls: [c]);

  /// 一轮「流式期间就报出调用 → StreamDone」的脚本。
  FakeProvider streamOnce(ToolCall call) => FakeProvider(
        const [AIResponse(text: 'done')],
        streamScript: [
          [ToolCallReady(call), StreamDone(one(call))],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      );

  group('D1：落地判据按值比较，不看对象身份', () {
    test('rulesProvider 每次返回新对象时，抢跑过的命令不在远端再跑一遍', () async {
      final call = bash('a', 'ls -la /var/log');
      final runner = FakeRunner();

      final loop = makeLoop(
        runner: runner,
        provider: streamOnce(call),
        // 生产接线 `() => mgr.rules` 的忠实复刻：内容恒等、对象身份每次都
        // 变。只要用户动过一次权限规则（点过「总是允许」、改过开关），
        // `AgentSessionManager.rules` 就走 `fromJson` 分支，每读一次 new
        // 一个。
        //
        // **这里绝不能加 `const`**，哪怕 analyzer 建议加。const 会被 Dart
        // 规范化成同一个实例，于是每次调用返回的身份相同 —— 这条测试要
        // 复现的恰恰是「身份每次都不同」，加上 const 它就永远通过，而且是
        // 因为错误的理由通过。
        // ignore: prefer_const_constructors
        rulesProvider: () => PermissionRuleSet(defaultAllowRules),
      );

      await loop.send('看下日志');

      expect(runner.ran, ['ls -la /var/log'],
          reason: '抢跑已经跑过一遍，落地时应复用结果而不是丢弃重跑');
    });

    test('对照组：rulesProvider 返回同一个对象时同样只跑一次', () async {
      final call = bash('a', 'ls -la /var/log');
      final runner = FakeRunner();
      const stable = PermissionRuleSet(defaultAllowRules);

      final loop = makeLoop(
        runner: runner,
        provider: streamOnce(call),
        rulesProvider: () => stable,
      );

      await loop.send('看下日志');

      expect(runner.ran, ['ls -la /var/log']);
    });

    test('规则内容真的变了，判据仍要判「变了」', () {
      const before = PermissionRuleSet(defaultAllowRules);
      const after = PermissionRuleSet(
        [...defaultAllowRules, PermissionRule(pattern: 'docker exec *')],
      );
      expect(before == after, isFalse, reason: '加了一条规则 = 判据变了');

      // 禁用一条也算变 —— `enabled` 必须参与比较。
      final disabled = PermissionRuleSet(
        defaultAllowRules.map((r) => r.copyWith(enabled: false)).toList(),
      );
      expect(before == disabled, isFalse);
    });
  });

  group('D2：抢跑要求「重跑安全」，不只是「免审批」', () {
    test('bypass 档下写命令免审批，但不抢跑', () {
      // bypass = 「全部放行不要问」，`checkCommand` 第二步就无条件 allow。
      final write = bash('a', 'crontab /tmp/new');
      const rules = PermissionRuleSet(defaultAllowRules);

      expect(
        partitionToolCalls([write], rules: rules, mode: PermissionMode.bypass)
            .parallel,
        isNotEmpty,
        reason: 'bypass 下它确实免审批、确实该并发 —— 前提条件成立',
      );
      expect(
        canSpeculate(write, rules: rules, mode: PermissionMode.bypass),
        isFalse,
        reason: '但它会写，丢弃重跑时副作用会做两遍',
      );
    });

    test('用户用「总是允许」加的写规则放行的命令，不抢跑', () {
      const rules = PermissionRuleSet(
        [...defaultAllowRules, PermissionRule(pattern: 'crontab *')],
      );
      final write = bash('a', 'crontab /tmp/new');

      expect(rules.allows('crontab /tmp/new'), isTrue, reason: '确实被放行了');
      expect(canSpeculate(write, rules: rules, mode: PermissionMode.ask),
          isFalse);
    });

    test('内置只读规则放行的照常抢跑 —— 收紧不能把收益一起砍掉', () {
      const rules = PermissionRuleSet(defaultAllowRules);
      for (final cmd in const [
        'ls -la /var/log',
        'ps aux',
        'df -h',
        'journalctl -u nginx -n 30',
        'docker ps -a',
        'git status --short',
      ]) {
        expect(
          canSpeculate(bash('a', cmd), rules: rules, mode: PermissionMode.ask),
          isTrue,
          reason: '$cmd 命中内置只读清单，应当仍可抢跑',
        );
      }
    });

    test('只读工具不受影响', () {
      const rules = PermissionRuleSet(defaultAllowRules);
      bool spec(String name, Map<String, dynamic> args) => canSpeculate(
          ToolCall(id: 'a', name: name, args: args),
          rules: rules,
          mode: PermissionMode.ask);

      expect(spec('read_file', const {'path': '/etc/hostname'}), isTrue);
      expect(spec('glob', const {'pattern': '*.log'}), isTrue);
      expect(spec('grep', const {'pattern': 'error'}), isTrue);
    });

    test('端到端：bypass 档 + 判据中途变化，写命令仍只执行一次', () async {
      var cwd = '/tmp';
      // 在抢跑真正发起执行的那一刻改 cwd —— 精确落在「判据快照之后、
      // StreamDone 核对之前」那个窗口，与 `agent_speculative_test.dart` 里
      // 那条 cwd 落空测试同一个手法。修复前：抢跑起飞 → 判据变 → 丢弃重跑
      // → crontab 被写两次。
      final runner = FakeRunner(onRun: (_) => cwd = '/other');
      final write = bash('a', 'crontab /tmp/new');

      final loop = makeLoop(
        runner: runner,
        provider: streamOnce(write),
        mode: PermissionMode.bypass,
        cwdProvider: () => cwd,
      );

      await loop.send('装一下定时任务');

      expect(runner.ran.where((c) => c == 'crontab /tmp/new').length, 1,
          reason: '写命令压根不该抢跑，因此判据怎么变都只会执行一次');
    });
  });
}
