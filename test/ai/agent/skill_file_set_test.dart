import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/skill_file_import.dart';

/// `skillsFromFileSet`：目录/zip/远端目录三个导入路径共用的纯函数。
///
/// 它只认「相对路径 → 字节」，所以这里用 Map 直接喂，不碰文件系统、不碰
/// zip 库 —— 那两层各自只剩「把字节取出来」这一件事。
Map<String, List<int>> _fs(Map<String, String> files) =>
    {for (final e in files.entries) e.key: utf8.encode(e.value)};

String _md(String name, String desc, String body) =>
    '---\nname: $name\ndescription: $desc\n---\n\n$body\n';

void main() {
  group('目录形态', () {
    test('SKILL.md + 同目录附件', () {
      final out = skillsFromFileSet(
        _fs({
          'deploy/SKILL.md': _md('deploy', 'd', 'body'),
          'deploy/scripts/check.sh': '#!/bin/sh\necho hi',
          'deploy/templates/n.conf': 'server {}',
        }),
        source: SkillSource.file,
      );
      expect(out, hasLength(1));
      final s = out.single;
      expect(s.name, equals('deploy'));
      expect(s.body, equals('body'));
      expect(s.dirName, equals('deploy'));
      expect(s.assets.map((a) => a.path).toSet(),
          equals({'scripts/check.sh', 'templates/n.conf'}));
      // 附件路径是相对技能目录的。
      expect(s.assets.firstWhere((a) => a.path.endsWith('.sh')).content,
          contains('echo hi'));
    });

    test('.sh 被标成可执行，数据文件不是', () {
      final out = skillsFromFileSet(
        _fs({
          'd/SKILL.md': _md('d', 'x', 'b'),
          'd/run.sh': 'x',
          'd/t.conf': 'y',
        }),
        source: SkillSource.file,
      );
      final byPath = {for (final a in out.single.assets) a.path: a};
      expect(byPath['run.sh']!.executable, isTrue);
      expect(byPath['t.conf']!.executable, isFalse);
    });

    test('scripts/ 下无扩展名的文件算脚本', () {
      final out = skillsFromFileSet(
        _fs({
          'd/SKILL.md': _md('d', 'x', 'b'),
          'd/scripts/bootstrap': 'x',
        }),
        source: SkillSource.file,
      );
      expect(out.single.assets.single.executable, isTrue);
    });

    test('SKILL.md 大小写不敏感', () {
      final out = skillsFromFileSet(
        _fs({'d/skill.md': _md('d', 'x', 'b')}),
        source: SkillSource.file,
      );
      expect(out, hasLength(1));
    });

    test('根目录下的 SKILL.md（无子目录）', () {
      final out = skillsFromFileSet(
        _fs({
          'SKILL.md': _md('root-skill', 'x', 'b'),
          't.conf': 'y',
        }),
        source: SkillSource.file,
      );
      expect(out, hasLength(1));
      expect(out.single.name, equals('root-skill'));
      expect(out.single.assets.single.path, equals('t.conf'));
      expect(out.single.dirName, isNull);
    });

    test('嵌套目录的 SKILL.md 各成一份，附件不串门', () {
      final out = skillsFromFileSet(
        _fs({
          'a/SKILL.md': _md('a', 'x', 'ba'),
          'a/f.txt': 'fa',
          'b/SKILL.md': _md('b', 'x', 'bb'),
          'b/g.txt': 'fb',
        }),
        source: SkillSource.file,
      );
      expect(out, hasLength(2));
      final a = out.firstWhere((s) => s.name == 'a');
      final b = out.firstWhere((s) => s.name == 'b');
      expect(a.assets.single.path, equals('f.txt'));
      expect(b.assets.single.path, equals('g.txt'));
    });
  });

  group('扁平形态（兼容改造前）', () {
    test('一堆 .md 各成一份，无附件', () {
      final out = skillsFromFileSet(
        _fs({
          'nginx.md': _md('nginx', 'x', 'bn'),
          'redis.md': _md('redis', 'x', 'br'),
        }),
        source: SkillSource.remote,
      );
      expect(out, hasLength(2));
      expect(out.every((s) => s.assets.isEmpty), isTrue);
      expect(out.map((s) => s.name).toSet(), equals({'nginx', 'redis'}));
    });

    test('两种形态共存', () {
      final out = skillsFromFileSet(
        _fs({
          'deploy/SKILL.md': _md('deploy', 'x', 'b'),
          'deploy/x.sh': 'z',
          'flat.md': _md('flat', 'x', 'b'),
        }),
        source: SkillSource.remote,
      );
      expect(out.map((s) => s.name).toSet(), equals({'deploy', 'flat'}));
      expect(out.firstWhere((s) => s.name == 'deploy').assets, hasLength(1));
      expect(out.firstWhere((s) => s.name == 'flat').assets, isEmpty);
    });
  });

  group('安全与容错', () {
    test('危险附件路径被跳过，技能本身仍导入', () {
      final rejected = <String>[];
      final out = skillsFromFileSet(
        _fs({
          'd/SKILL.md': _md('d', 'x', 'b'),
          'd/ok.sh': 'z',
          // 归到 d/ 下之后 rel = '../evil'，必须被拒。
          'd/../evil.sh': 'bad',
        }),
        source: SkillSource.file,
        onRejected: rejected.add,
      );
      expect(out, hasLength(1), reason: '一份坏附件不该让整条技能导不进来');
      expect(out.single.assets.map((a) => a.path), equals(['ok.sh']));
      expect(rejected, isNotEmpty);
    });

    test('__MACOSX 碎片不会毁掉整次导入', () {
      final out = skillsFromFileSet(
        _fs({
          'd/SKILL.md': _md('d', 'x', 'b'),
          '__MACOSX/d/._SKILL.md': 'junk',
        }),
        source: SkillSource.file,
      );
      expect(out, hasLength(1));
      expect(out.single.name, equals('d'));
    });

    test('frontmatter 坏掉的 SKILL.md 计失败，不产技能', () {
      final rejected = <String>[];
      final out = skillsFromFileSet(
        _fs({
          'd/SKILL.md': 'no frontmatter here',
          'd/x.sh': 'z',
        }),
        source: SkillSource.file,
        onRejected: rejected.add,
      );
      expect(out, isEmpty);
      expect(rejected, contains('d/SKILL.md'));
    });

    test('非 UTF-8 的正文跳过', () {
      final out = skillsFromFileSet(
        {
          'd/SKILL.md': utf8.encode(_md('d', 'x', 'b')),
          'd/bin.dat': [0xff, 0xfe, 0x00],
        },
        source: SkillSource.file,
      );
      expect(out, hasLength(1));
      expect(out.single.assets, isEmpty, reason: '编不出来就不进附件');
    });

    test('反斜杠分隔符（Windows zip）归一化', () {
      final out = skillsFromFileSet(
        _fs({
          r'd\SKILL.md': _md('d', 'x', 'b'),
          r'd\scripts\x.sh': 'z',
        }),
        source: SkillSource.file,
      );
      expect(out, hasLength(1));
      expect(out.single.assets.single.path, equals('scripts/x.sh'));
    });

    test('开头的 ./ 被归一化', () {
      final out = skillsFromFileSet(
        _fs({'./d/SKILL.md': _md('d', 'x', 'b')}),
        source: SkillSource.file,
      );
      expect(out, hasLength(1));
      expect(out.single.dirName, equals('d'));
    });

    test('空文件集产出空列表，不抛', () {
      expect(skillsFromFileSet(const {}, source: SkillSource.file), isEmpty);
    });
  });
}
