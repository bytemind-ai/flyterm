import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/agent_instructions.dart';

void main() {
  group('parseSkillMarkdown', () {
    test('完整 frontmatter 解析出三段', () {
      final r = parseSkillMarkdown('''
---
name: nginx-troubleshooting
description: 502/504、upstream 超时的排查流程
---
先看 error.log 的最后 50 行。
''', fallbackName: 'ignored');
      expect(r.name, equals('nginx-troubleshooting'));
      expect(r.description, equals('502/504、upstream 超时的排查流程'));
      expect(r.body, equals('先看 error.log 的最后 50 行。'));
      expect(r.error, isNull);
    });

    test('缺 name 时回落到文件名', () {
      final r = parseSkillMarkdown('''
---
description: 一句话
---
正文
''', fallbackName: 'deploy-cli');
      expect(r.name, equals('deploy-cli'));
    });

    test('缺 description 时留空且不报错 —— 由用户在预览页补', () {
      final r = parseSkillMarkdown('''
---
name: x
---
正文
''', fallbackName: 'f');
      expect(r.description, isEmpty);
      expect(r.error, isNull, reason: '缺 description 不是解析失败，是待补全');
    });

    test('完全没有 frontmatter 时报错并说明缺什么', () {
      final r = parseSkillMarkdown('就是一段普通文字', fallbackName: 'f');
      expect(r.error, isNotNull);
      expect(r.error, contains('frontmatter'));
    });

    test('正文为空时报错', () {
      final r = parseSkillMarkdown('''
---
name: x
description: y
---
''', fallbackName: 'f');
      expect(r.error, isNotNull);
    });

    test('description 超 200 字节被截断', () {
      final long = 'a' * 300;
      final r = parseSkillMarkdown('''
---
name: x
description: $long
---
正文
''', fallbackName: 'f');
      expect(utf8.encode(r.description).length,
          lessThanOrEqualTo(kMaxSkillDescriptionBytes));
    });

    test('正文超 8 KiB 被截断并留标记', () {
      final huge = '行\n' * 5000;
      final r = parseSkillMarkdown('''
---
name: x
description: y
---
$huge
''', fallbackName: 'f');
      expect(utf8.encode(r.body).length,
          lessThanOrEqualTo(kMaxSkillBodyBytes + 64));
      expect(r.body, contains('truncated'));
    });

    test('多字节字符正好卡在截断点时不留残缺字节', () {
      final huge = '中' * 4000;
      final r = parseSkillMarkdown('''
---
name: x
description: y
---
$huge
''', fallbackName: 'f');
      expect(r.body, isNot(contains('\u{FFFD}')));
    });
  });

  group('clipToBytes', () {
    test('未超长原样返回', () {
      expect(clipToBytes('短', 100), equals('短'));
    });

    test('超长按字节截断并加标记', () {
      final out = clipToBytes('a' * 100, 10);
      expect(out, startsWith('aaaaaaaaaa'));
      expect(out, contains('truncated'));
    });
  });
}
