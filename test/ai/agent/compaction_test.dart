import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/compaction.dart';
import 'package:flyterm/ai/agent/session_facts.dart';
import 'package:flyterm/ai/agent/token_estimate.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

AIMessage sys() => const AIMessage(role: 'system', content: 'SYS');
AIMessage user(String t) => AIMessage(role: 'user', content: t);
AIMessage asst(String t) => AIMessage(role: 'assistant', content: t);

AIMessage asstCall(String id, String cmd) => AIMessage(
      role: 'assistant',
      content: '',
      toolCalls: [ToolCall(id: id, name: 'bash', args: {'command': cmd})],
    );

AIMessage toolRes(String id, String out) => AIMessage(
      role: 'tool',
      content: '',
      toolResults: [ToolResult(callId: id, content: out, exitCode: 0)],
    );

/// 一个完整轮次：assistant(tool_use) + tool(result)
List<AIMessage> round(String id, String cmd, String out) =>
    [asstCall(id, cmd), toolRes(id, out)];

/// 不关心事实块内容的调用点用这个占位。
const noFacts = SessionFacts(
  modifiedFiles: [],
  readFiles: [],
  commands: [],
  backgroundJobs: [],
  servers: [],
  omittedCommands: 0,
);

void main() {
  group('findCompactionCut', () {
    test('历史太短时返回 0——不值得花一次调用', () {
      final h = [sys(), user('hi'), asst('hello')];
      expect(findCompactionCut(h, keepTokens: 500), equals(0));
    });

    test('永不砍 system——切点至少是 1', () {
      final h = [sys()];
      for (var i = 0; i < 40; i++) {
        h.addAll(round('c$i', 'cmd $i', 'x' * 500));
      }
      final cut = findCompactionCut(h, keepTokens: 1000);
      // 这是真正验证行为的断言：若压缩把 cut 推到 0 或更小，说明 system
      // (history[0]) 落进了被砍范围 [1, cut) 之外的某种退化情形（或压缩
      // 干脆没发生），这里的历史规模保证它必然发生且 cut > 0。
      //
      // 注意：不要在此断言 `h[0].role == 'system'` —— h[0] 是测试自己用
      // `sys()` 构造出来的字面量，`findCompactionCut` 不修改入参，那条
      // 断言不管函数怎么实现都恒真，是纯重言式，测的是测试夹具而不是
      // 被测函数的行为。
      expect(cut, greaterThan(0));
    });

    test('切点绝不落在 tool 消息上——保留段的第一条不能是悬空的 tool_result',
        () {
      final h = [sys()];
      // 60 轮（而不是 40 轮）是刻意选的：评审用 40 轮实测过，keepTokens=6000
      // 时 findCompactionCut 会因为 gain < kMinCompactionGain 合法返回 0——
      // 旧测试用 `if (cut == 0) continue;` 跳过了这种情况，导致 5 个
      // keepTokens 值实际只覆盖了 4 个。60 轮让所有列出的 keepTokens 都产生
      // 非零切点，测试因此真正覆盖全部取值，而不是悄悄跳过一部分。
      for (var i = 0; i < 60; i++) {
        h.addAll(round('c$i', 'cmd $i', 'y' * 400));
      }
      for (final keep in [250, 750, 1500, 3000, 6000]) {
        final cut = findCompactionCut(h, keepTokens: keep);
        expect(cut, greaterThan(0),
            reason: 'keepTokens=$keep 时不该返回 0——历史规模足够大，'
                '返回 0 说明这条 keepTokens 的取值不再能覆盖它本该覆盖的场景');
        expect(h[cut].role, isNot(equals('tool')),
            reason: 'keepTokens=$keep 时切点落在了 tool 消息上');
      }
    });

    test('压缩后每个 tool_use 仍有配对的 tool_result', () {
      final h = [sys(), user('q')];
      for (var i = 0; i < 30; i++) {
        h.addAll(round('c$i', 'cmd $i', 'z' * 600));
      }
      final cut = findCompactionCut(h, keepTokens: 1500);
      // 若 cut 为 0，下面 h.sublist(0) 就是整段历史，这条测试要验的「压缩后
      // 配对仍完整」会退化成「压缩没发生时配对仍完整」，平凡通过而没测到
      // 真实的压缩路径。
      expect(cut, greaterThan(0));
      final kept = h.sublist(cut);

      final useIds = <String>[];
      final resIds = <String>[];
      for (final m in kept) {
        for (final t in m.toolCalls ?? const <ToolCall>[]) {
          useIds.add(t.id);
        }
        for (final r in m.toolResults ?? const <ToolResult>[]) {
          resIds.add(r.callId);
        }
      }
      // 每个保留下来的 tool_use 都要有 result；反过来更严格：不能有
      // result 找不到它的 use
      for (final id in resIds) {
        expect(useIds, contains(id));
      }
    });

    test('保留量至少达到 keepTokens（按尾部累计）', () {
      final h = [sys()];
      for (var i = 0; i < 30; i++) {
        h.addAll(round('c$i', 'c', 'w' * 1000));
      }
      final cut = findCompactionCut(h, keepTokens: 2500);
      // 同上：cut == 0 时 sublist(0) 是整段历史，「保留量 >= keepTokens」会
      // 对着未压缩的完整历史平凡成立，测不到压缩本身有没有守住这个下限。
      expect(cut, greaterThan(0));
      final keptTokens = h
          .sublist(cut)
          .fold<int>(0, (a, m) => a + estimateMessageTokens(m));
      expect(keptTokens, greaterThanOrEqualTo(2500));
    });

    test('砍掉的量太小时返回 0——省下这次调用', () {
      final h = [sys(), user('q'), ...round('c0', 'cmd', 'small')];
      expect(findCompactionCut(h, keepTokens: 5), equals(0));
    });
  });

  group('buildSummaryRequest', () {
    test('三段结构都出现在指令里', () {
      final msgs = buildSummaryRequest([user('q'), ...round('c', 'ls', 'out')]);
      // 小节标题在 prompt 里是全大写（`CONFIRMED FACTS` 等），断言统一降到
      // 小写再比 —— 否则改一次标题大小写就红一片，而那与这条测试想验证的
      // 「三段结构在不在」毫无关系。
      final instruction = msgs.last.content.toLowerCase();
      expect(instruction, contains('confirmed'));
      expect(instruction, contains('ruled out'));
      expect(instruction, contains('still'));
    });

    test('请求里不含 system 消息——摘要调用不该继承 agent 的人格与工具约束',
        () {
      final msgs = buildSummaryRequest([sys(), user('q')]);
      expect(msgs.where((m) => m.role == 'system'), isEmpty);
    });

    test('工具调用与结果被展开成可读文本，不是空 content', () {
      final msgs = buildSummaryRequest(round('c1', 'systemctl status x', 'active'));
      final transcript = msgs.first.content;
      expect(transcript, contains('systemctl status x'));
      expect(transcript, contains('active'));
    });

    test('并行调用时 TOOL_CALL/TOOL_RESULT 带 id，配对不用靠顺序猜', () {
      // 三个并行调用打包进同一条 assistant 消息，紧跟着三条独立的 tool
      // 消息——这正是并行工具调用在历史里的形状。没有 id 的话，摘要
      // transcript 里三个 TOOL_CALL 和三个 TOOL_RESULT 只能靠先后顺序
      // 对应，读的人（或下游模型）猜不准谁对谁。
      const parallelCall = AIMessage(
        role: 'assistant',
        content: '',
        toolCalls: [
          ToolCall(id: 'a1', name: 'bash', args: {'command': 'one'}),
          ToolCall(id: 'a2', name: 'bash', args: {'command': 'two'}),
        ],
      );
      final res1 = toolRes('a1', 'out-one');
      final res2 = toolRes('a2', 'out-two');
      final msgs = buildSummaryRequest([parallelCall, res1, res2]);
      final transcript = msgs.first.content;
      expect(transcript, contains('id=a1'));
      expect(transcript, contains('id=a2'));
      expect(transcript, contains('for a1'));
      expect(transcript, contains('for a2'));
    });

    test('工具参数用 jsonEncode，逗号和花括号不产生歧义', () {
      // Map.toString() 会把 {'command': 'echo a, b'} 写成
      // "{command: echo a, b}"——那个逗号看起来像第二个键值对的分隔符。
      // jsonEncode 给出 {"command":"echo a, b"}，逗号被引号困在字符串里，
      // 没有歧义。
      const call = AIMessage(
        role: 'assistant',
        content: '',
        toolCalls: [
          ToolCall(id: 'c', name: 'bash', args: {'command': 'echo a, b'}),
        ],
      );
      final msgs = buildSummaryRequest([call]);
      final transcript = msgs.first.content;
      expect(transcript, contains('{"command":"echo a, b"}'));
    });
  });

  group('buildSummaryMessage', () {
    test('以 user 角色注入，带明确的边界标记', () {
      final m = buildSummaryMessage('已确认：nginx 在跑', noFacts);
      expect(m.role, equals('user'));
      expect(m.content, contains('已确认：nginx 在跑'));
      expect(m.toolCalls, isNull);
      expect(m.toolResults, isNull);
    });

    test('摘要文本为空时也给出一条可用消息，不产出空 content', () {
      final m = buildSummaryMessage('   ', noFacts);
      expect(m.content.trim(), isNotEmpty);
    });
  });

  group('摘要 prompt', () {
    String instruction(List<AIMessage> req) => req.last.content;

    test('不再要求模型逐字抄标识符 —— 那件事现在由代码做', () {
      final req = buildSummaryRequest([user('hi')]);
      expect(instruction(req).toLowerCase(), isNot(contains('verbatim')));
      expect(instruction(req), isNot(contains('CHANGES MADE')));
    });

    // 这条与「删掉第 4 段」无关，是一条独立的回归防护，从被删掉的那条旧
    // 测试里救回来的：backup path 从未进入模型可见的内容（写入/编辑的回填
    // 只有 'Wrote N bytes to <path>.' / 'Edited <path> at line N.'），prompt
    // 曾经要求模型连它一起抄 —— 那是要求模型抄一个自己从没见过的标识符。
    //
    // 事实提取改造之后这句话更不该回来（路径由代码从 args 里取），但"不该
    // 回来"需要有人守着，否则下一个人加一句「连同备份路径一起记下」不会
    // 有任何测试变红。
    test('不要求模型抄 backup path —— 它从来就看不到那个值', () {
      final s = instruction(buildSummaryRequest([user('hi')]));
      expect(s.toLowerCase(), isNot(contains('backup')));
    });

    test('三段叙事仍在 —— 那些是代码提取不了的判断', () {
      final s = instruction(buildSummaryRequest([user('hi')]));
      expect(s, contains('CONFIRMED FACTS'));
      expect(s, contains('RULED OUT'));
      expect(s, contains('STILL OPEN'));
    });

    test('段数说明与实际段数一致', () {
      final s = instruction(buildSummaryRequest([user('hi')]));
      expect(s, contains('three sections'));
      expect(s, isNot(contains('four sections')));
    });
  });

  group('buildSummaryMessage 带事实块', () {
    const emptyFacts = SessionFacts(
      modifiedFiles: [],
      readFiles: [],
      commands: [],
      backgroundJobs: [],
      servers: [],
      omittedCommands: 0,
    );
    const someFacts = SessionFacts(
      modifiedFiles: ['/etc/nginx.conf'],
      readFiles: [],
      commands: [],
      backgroundJobs: ['job_7f3a'],
      servers: [],
      omittedCommands: 0,
    );

    test('事实块排在叙事之后 —— 按 recency，事实是硬约束', () {
      final m = buildSummaryMessage('NARRATIVE_MARK', someFacts);
      expect(m.content.indexOf('NARRATIVE_MARK'),
          lessThan(m.content.indexOf('<modified-files>')));
    });

    test('事实块在结束标记之前', () {
      final m = buildSummaryMessage('x', someFacts);
      expect(m.content.indexOf('<modified-files>'),
          lessThan(m.content.indexOf('end of summary')));
    });

    // 这是整个改造最大的收益点：摘要返回空字符串时（不抛异常，历史照常
    // 被替换），改过的文件和在跑的 job 原先会彻底消失，模型随后重复编辑。
    test('摘要为空时事实块仍然完整', () {
      final m = buildSummaryMessage('', someFacts);
      expect(m.content, contains('/etc/nginx.conf'));
      expect(m.content, contains('job_7f3a'));
    });

    test('摘要为空时说明叙事没生成，而不是谎称没有上下文', () {
      final m = buildSummaryMessage('', someFacts);
      expect(m.content.toLowerCase(), contains('summary'));
    });

    test('摘要与事实都为空时，退回原来的措辞', () {
      final m = buildSummaryMessage('', emptyFacts);
      expect(m.content, contains('came back empty'));
    });

    test('事实为空时不留空行或空标签', () {
      final m = buildSummaryMessage('NARRATIVE', emptyFacts);
      expect(m.content, isNot(contains('<')));
    });

    test('角色仍是 user', () {
      expect(buildSummaryMessage('x', someFacts).role, 'user');
    });
  });
}
