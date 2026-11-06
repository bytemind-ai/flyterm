import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/app_control/key_sequence_parser.dart';
import 'package:flyterm/data/keybar_config.dart';

void main() {
  group('parseKeySequence', () {
    test('纯文本', () {
      final t = parseKeySequence('git status');
      expect(t, hasLength(1));
      expect((t.single as TextToken).text, 'git status');
    });

    test('纯占位符', () {
      final t = parseKeySequence('[ctrl-c]');
      expect(t, hasLength(1));
      expect((t.single as SpecialToken).key, SpecialKey.ctrlC);
    });

    test('文本 + 占位符混合', () {
      final t = parseKeySequence('cd [tab]');
      expect(t, hasLength(2));
      expect((t[0] as TextToken).text, 'cd ');
      expect((t[1] as SpecialToken).key, SpecialKey.tab);
    });

    test('真实换行当作 enter', () {
      final t = parseKeySequence('ls\n');
      expect(t, hasLength(2));
      expect((t[1] as SpecialToken).key, SpecialKey.enter);
    });

    test('制表符当作 tab', () {
      final t = parseKeySequence('a\tb');
      expect(t, hasLength(3));
      expect((t[1] as SpecialToken).key, SpecialKey.tab);
    });

    test('原始 enum 名也认 —— 模型两种写法都可能用', () {
      final t = parseKeySequence('[ctrlC]');
      expect((t.single as SpecialToken).key, SpecialKey.ctrlC);
    });

    test('大小写无关', () {
      expect((parseKeySequence('[CTRL-C]').single as SpecialToken).key,
          SpecialKey.ctrlC);
      expect((parseKeySequence('[Page-Up]').single as SpecialToken).key,
          SpecialKey.pageUp);
    });

    test('[[ 是字面量左方括号', () {
      final t = parseKeySequence('a[[b');
      expect(t, hasLength(1));
      expect((t.single as TextToken).text, 'a[b');
    });

    test('多个占位符连写', () {
      final t = parseKeySequence('[ctrl-a][ctrl-k]');
      expect(t, hasLength(2));
      expect((t[0] as SpecialToken).key, SpecialKey.ctrlA);
      expect((t[1] as SpecialToken).key, SpecialKey.ctrlK);
    });
  });

  group('parseKeySequence —— 错误', () {
    test('空串被拒', () {
      expect(() => parseKeySequence(''), throwsA(isA<KeySequenceParseError>()));
    });

    test('未配对的括号被拒，错误里说清怎么写字面量', () {
      try {
        parseKeySequence('a[b');
        fail('应当抛出');
      } on KeySequenceParseError catch (e) {
        expect(e.message, contains('Unclosed'));
        expect(e.message, contains('[['));
      }
    });

    // 不做模糊匹配：猜错一个键名的代价是用户按下去发出错误的字节。
    test('未知键名被拒且列出可用名，不做模糊匹配', () {
      try {
        parseKeySequence('[ctrl-see]');
        fail('应当抛出');
      } on KeySequenceParseError catch (e) {
        expect(e.message, contains('Unknown special key'));
        expect(e.message, contains('ctrl-c'),
            reason: '错误里应列出可用名供模型改正');
      }
    });
  });

  group('kebab', () {
    test('驼峰转 kebab', () {
      expect(kebab(SpecialKey.ctrlC), 'ctrl-c');
      expect(kebab(SpecialKey.pageUp), 'page-up');
      expect(kebab(SpecialKey.shiftTab), 'shift-tab');
    });

    test('全小写的名字原样', () {
      expect(kebab(SpecialKey.esc), 'esc');
      expect(kebab(SpecialKey.f1), 'f1');
    });

    test('每个 SpecialKey 的 kebab 名都唯一 —— 否则查表会撞', () {
      final names = SpecialKey.values.map(kebab).toList();
      expect(names.toSet().length, names.length);
    });
  });
}
