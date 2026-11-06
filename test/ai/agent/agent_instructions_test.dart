import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_instructions.dart';

void main() {
  group('composeInstructions', () {
    test('两份都为空时返回 null', () {
      expect(composeInstructions(global: null, machine: null), isNull);
      expect(composeInstructions(global: '', machine: '   '), isNull);
    });

    test('只有全局那份时带 operator 标题', () {
      final out =
          composeInstructions(global: '用 podman 不用 docker', machine: null);
      expect(out, contains('用 podman 不用 docker'));
      expect(out, contains('operator instructions'));
      expect(out, isNot(contains('AGENTS.md')));
    });

    test('两份都有时全局在前、机器笔记在后', () {
      final out =
          composeInstructions(global: 'GLOBAL_MARK', machine: 'MACHINE_MARK')!;
      expect(out.indexOf('GLOBAL_MARK'), lessThan(out.indexOf('MACHINE_MARK')));
      expect(out, contains('--- Notes about this server ---'));
    });

    test('超长的一份被截断并标注', () {
      final huge = 'x' * (kMaxInstructionBytes + 500);
      final out = composeInstructions(global: huge, machine: null)!;
      expect(out, contains('[truncated at $kMaxInstructionBytes bytes]'));
      expect(utf8.encode(out).length, lessThan(kMaxInstructionBytes + 200));
    });

    test('截断不产生半个 UTF-8 字符', () {
      // 每个「中」是 3 字节，取一个会让边界正好落在字符中间的长度
      final huge = '中' * (kMaxInstructionBytes ~/ 2);
      final out = composeInstructions(global: huge, machine: null)!;
      expect(out, isNot(contains('�')));
    });

    test('两份各自独立截断，不是拼起来再截', () {
      final huge = 'y' * (kMaxInstructionBytes + 100);
      final out = composeInstructions(global: huge, machine: 'MACHINE_MARK')!;
      // 机器笔记那份必须还在——如果实现是「拼完再截」，它会被整段切掉
      expect(out, contains('MACHINE_MARK'));
    });

    test('两份都超长时各自都被截断，且都还在', () {
      final a = 'a' * (kMaxInstructionBytes + 100);
      final b = 'b' * (kMaxInstructionBytes + 100);
      final out = composeInstructions(global: a, machine: b)!;
      // 两个截断标注各出现一次——证明是两次独立 _clip，而不是拼完截一次
      expect(
        '[truncated at $kMaxInstructionBytes bytes]'
            .allMatches(out)
            .length,
        equals(2),
      );
      expect(out, contains('aaa'));
      expect(out, contains('bbb'));
    });

    test('两份各自独立截断 —— 全局那份超长不该把机器笔记挤掉', () {
      final out = composeInstructions(
        global: 'g' * (kMaxInstructionBytes + 100),
        machine: '这台用 podman',
      );

      expect(out, contains('这台用 podman'));
      expect(out, contains('[truncated at $kMaxInstructionBytes bytes]'));
    });
  });
}
