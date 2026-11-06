import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_instructions.dart' show kMaxInstructionBytes;
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/knowledge_distiller.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

ToolCallEvent call(
  String tool, {
  required String cmd,
  String desc = 'd',
  String? output,
  ToolCallStatus status = ToolCallStatus.done,
  int seq = 0,
}) {
  final e = ToolCallEvent(
    seq: seq,
    callId: 'c$seq',
    toolName: tool,
    displayCommand: cmd,
    description: desc,
    check: const CheckResult(decision: ToolDecision.allow),
    status: status,
  );
  e.output = output;
  return e;
}

void main() {
  const index = [
    SkillIndexEntry(name: 'nginx-502', description: '排查 502'),
  ];

  test('抓第一条用户输入作为意图', () {
    final input = buildDistillInput(
      events: [
        UserTurnEvent('502 怎么回事'),
        AssistantTextEvent('查一下'),
        UserTurnEvent('还有别的吗'),
      ],
      existingSkills: index,
      currentMachineNotes: null,
    );
    expect(input.userGoal, equals('502 怎么回事'));
  });

  test('抓最后一条助手文本作为结论', () {
    final input = buildDistillInput(
      events: [
        UserTurnEvent('q'),
        AssistantTextEvent('中间过程'),
        AssistantTextEvent('最终结论'),
      ],
      existingSkills: index,
      currentMachineNotes: null,
    );
    expect(input.conclusion, equals('最终结论'));
  });

  // 命令输出是整个会话里最贵的部分，且对提炼几乎无用 —— 提炼要的是
  // 「做了什么、结论是什么」，不是 systemctl status 的 80 行原文。
  test('命令输出不进提炼输入', () {
    final input = buildDistillInput(
      events: [
        UserTurnEvent('q'),
        call('bash',
            cmd: 'systemctl status nginx',
            output: 'SECRET_OUTPUT_MARKER_12345',
            seq: 1),
      ],
      existingSkills: index,
      currentMachineNotes: null,
    );
    expect(input.actions.join('\n'), isNot(contains('SECRET_OUTPUT_MARKER')));
    expect(input.actions.join('\n'), contains('systemctl status nginx'));
  });

  test('只收成功的调用', () {
    final input = buildDistillInput(
      events: [
        UserTurnEvent('q'),
        call('bash', cmd: 'ok-cmd', seq: 1),
        call('bash', cmd: 'failed-cmd', status: ToolCallStatus.failed, seq: 2),
        call('bash', cmd: 'rejected-cmd', status: ToolCallStatus.rejected, seq: 3),
      ],
      existingSkills: index,
      currentMachineNotes: null,
    );
    final joined = input.actions.join('\n');
    expect(joined, contains('ok-cmd'));
    expect(joined, isNot(contains('failed-cmd')));
    expect(joined, isNot(contains('rejected-cmd')));
  });

  test('带上现有 skill 索引 —— 防重靠它', () {
    final input = buildDistillInput(
      events: [UserTurnEvent('q')],
      existingSkills: index,
      currentMachineNotes: null,
    );
    expect(input.existingSkills.single.name, equals('nginx-502'));
  });

  test('算出机器笔记的剩余字节', () {
    final input = buildDistillInput(
      events: [UserTurnEvent('q')],
      existingSkills: index,
      currentMachineNotes: 'x' * 1000,
    );
    expect(input.machineNotesRemainingBytes, equals(kMaxInstructionBytes - 1000));
  });

  test('机器笔记不存在时剩余字节是满额', () {
    final input = buildDistillInput(
      events: [UserTurnEvent('q')],
      existingSkills: index,
      currentMachineNotes: null,
    );
    expect(input.machineNotesRemainingBytes, equals(kMaxInstructionBytes));
  });

  test('机器笔记已超额时剩余字节不为负', () {
    final input = buildDistillInput(
      events: [UserTurnEvent('q')],
      existingSkills: index,
      currentMachineNotes: 'x' * (kMaxInstructionBytes + 500),
    );
    expect(input.machineNotesRemainingBytes, equals(0));
  });

  group('凭据打码', () {
    test('key-value 形式被打码', () {
      final input = buildDistillInput(
        events: [
          UserTurnEvent('q'),
          call('bash', cmd: 'mysql -u root --password=hunter2 -e "select 1"', seq: 1),
        ],
        existingSkills: index,
        currentMachineNotes: null,
      );
      expect(input.actions.join(), isNot(contains('hunter2')));
    });

    test('URL 里的凭据被打码', () {
      final input = buildDistillInput(
        events: [
          UserTurnEvent('连 postgres://admin:s3cr3t@db.internal/app 看看'),
        ],
        existingSkills: index,
        currentMachineNotes: null,
      );
      expect(input.userGoal, isNot(contains('s3cr3t')));
    });

    // 锁定**已知限制**，不是锁定期望行为。
    //
    // output_sanitizer.dart 的注释明确写了这种紧贴 flag 的形式由 deny 清单
    // 侧负责、redactSecrets 匹配不到。把它写成断言，是为了让日后读代码的人
    // 一眼看到这一道拦不住什么 —— 兜底是卡片展示正文全文那一道人工闸门。
    test('已知限制：-phunter2 这类紧贴 flag 的密码打不掉', () {
      final input = buildDistillInput(
        events: [
          UserTurnEvent('q'),
          call('bash', cmd: 'mysql -phunter2 -e "select 1"', seq: 1),
        ],
        existingSkills: index,
        currentMachineNotes: null,
      );
      expect(input.actions.join(), contains('hunter2'),
          reason: '这一道拦不住它；兜底是用户在卡片上看到正文全文');
    });
  });

  test('空事件流不抛', () {
    final input = buildDistillInput(
      events: const [],
      existingSkills: const [],
      currentMachineNotes: null,
    );
    expect(input.userGoal, isEmpty);
    expect(input.conclusion, isEmpty);
    expect(input.actions, isEmpty);
  });
}
