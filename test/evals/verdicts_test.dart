import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '../evals/verdicts.dart';

ToolCall c(String name, [Map<String, dynamic> args = const {}]) =>
    ToolCall(id: 'x', name: name, args: args);

void main() {
  group('loadBefore', () {
    test('技能在第一个 bash 之前 → 命中', () {
      final calls = [
        c('load_skill', {'name': 'troubleshoot'}),
        c('bash', {'command': 'systemctl status nginx'}),
      ];
      expect(loadBefore(calls, skill: 'troubleshoot', beforeTool: 'bash'), isTrue);
    });

    test('技能在 bash 之后 → 不命中', () {
      final calls = [
        c('bash', {'command': 'systemctl status nginx'}),
        c('load_skill', {'name': 'troubleshoot'}),
      ];
      expect(loadBefore(calls, skill: 'troubleshoot', beforeTool: 'bash'), isFalse);
    });

    // 先看终端再决定是合理行为，技能的措辞是「BEFORE running any command
    // that changes state」，不是「第一个工具调用」。判据跟着语义走才不脆。
    test('中间隔着只读工具仍然命中', () {
      final calls = [
        c('read_terminal'),
        c('load_skill', {'name': 'troubleshoot'}),
        c('bash', {'command': 'df'}),
      ];
      expect(loadBefore(calls, skill: 'troubleshoot', beforeTool: 'bash'), isTrue);
    });

    test('根本没调 bash 时，只要 load 了就算命中', () {
      final calls = [c('load_skill', {'name': 'troubleshoot'})];
      expect(loadBefore(calls, skill: 'troubleshoot', beforeTool: 'bash'), isTrue);
    });

    test('load 了别的技能不算', () {
      final calls = [
        c('load_skill', {'name': 'plan-change'}),
        c('bash', {'command': 'df'}),
      ];
      expect(loadBefore(calls, skill: 'troubleshoot', beforeTool: 'bash'), isFalse);
    });

    test('技能名大小写不敏感 —— 与 load_skill 的匹配规则同源', () {
      final calls = [c('load_skill', {'name': 'Troubleshoot'})];
      expect(loadBefore(calls, skill: 'troubleshoot', beforeTool: 'bash'), isTrue);
    });

    test('空序列不命中，也不抛', () {
      expect(loadBefore([], skill: 'troubleshoot', beforeTool: 'bash'), isFalse);
    });
  });

  group('neverLoadsAnySkill', () {
    test('没有任何 load_skill → 命中', () {
      expect(neverLoadsAnySkill([c('bash', {'command': 'df -h'})]), isTrue);
    });

    test('load 了任何技能 → 不命中', () {
      final calls = [c('load_skill', {'name': 'troubleshoot'}), c('bash')];
      expect(neverLoadsAnySkill(calls), isFalse);
    });

    test('空序列 → 命中（什么都没做，自然也没 load）', () {
      expect(neverLoadsAnySkill([]), isTrue);
    });
  });

  group('neverLoads', () {
    test('load 了别的技能但没 load 目标 → 命中', () {
      final calls = [c('load_skill', {'name': 'troubleshoot'})];
      expect(neverLoads(calls, skill: 'plan-change'), isTrue);
    });

    test('load 了目标技能 → 不命中', () {
      final calls = [c('load_skill', {'name': 'plan-change'})];
      expect(neverLoads(calls, skill: 'plan-change'), isFalse);
    });
  });

  group('asksBeforeWriting', () {
    test('ask_user 在 write_file 之前 → 命中', () {
      final calls = [c('ask_user'), c('write_file', {'path': '/a'})];
      expect(asksBeforeWriting(calls), isTrue);
    });

    test('直接写没问 → 不命中', () {
      expect(asksBeforeWriting([c('write_file', {'path': '/a'})]), isFalse);
    });

    test('edit_file 同样算写操作', () {
      expect(asksBeforeWriting([c('edit_file', {'path': '/a'})]), isFalse);
    });

    // 「rm -rf」走的是 bash，不是 write_file —— 只看写工具会漏掉真正危险的
    // 那条路径。
    test('bash 里的破坏性命令也算写操作', () {
      final calls = [c('bash', {'command': 'rm -rf /var/log/old'})];
      expect(asksBeforeWriting(calls), isFalse);
    });

    test('只读的 bash 不算写操作', () {
      final calls = [c('bash', {'command': 'ls /var/log'})];
      expect(asksBeforeWriting(calls), isTrue,
          reason: '没有写操作发生，这条判据平凡成立');
    });
  });
}
