import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/skill_file_import.dart';

import '_tar_bundle.dart';

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('skillimp'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<File> write(String name, String content) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsString(content);
    return f;
  }

  test('读合法文件得到一份 PendingSkill', () async {
    final f = await write('nginx.md',
        '---\nname: nginx\ndescription: 排查 502\n---\n正文');
    final r = await importSkillFromFile(f.path);
    expect(r.error, isNull);
    expect(r.skill!.name, equals('nginx'));
    expect(r.skill!.source, equals(SkillSource.file));
  });

  test('name 缺失时回落到文件名（去掉 .md）', () async {
    final f = await write('my-notes.md', '---\ndescription: d\n---\n正文');
    final r = await importSkillFromFile(f.path);
    expect(r.skill!.name, equals('my-notes'));
  });

  test('解析失败时给出错误、不抛', () async {
    final f = await write('bad.md', '没有 frontmatter');
    final r = await importSkillFromFile(f.path);
    expect(r.error, isNotNull);
    expect(r.skill, isNull);
  });

  test('文件不存在时给出错误、不抛', () async {
    final r = await importSkillFromFile('${tmp.path}/nope.md');
    expect(r.error, isNotNull);
  });

  test('非 UTF-8 内容给出错误而不是崩溃', () async {
    final f = File('${tmp.path}/bin.md');
    await f.writeAsBytes([0xff, 0xfe, 0x00, 0x01, 0xff]);
    final r = await importSkillFromFile(f.path);
    expect(r.error, isNotNull);
  });

  // ───────── 目录导入 ─────────

  Future<void> mkdir(String rel) async {
    await Directory('${tmp.path}/$rel').create(recursive: true);
  }

  Future<void> writeAt(String rel, String content) async {
    final f = File('${tmp.path}/$rel');
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
  }

  test('目录导入：SKILL.md + 附件', () async {
    await writeAt('deploy/SKILL.md',
        '---\nname: deploy\ndescription: d\n---\n步骤正文');
    await writeAt('deploy/scripts/run.sh', '#!/bin/sh\necho hi');
    await writeAt('deploy/templates/n.conf', 'server {}');

    final r = await importSkillsFromDirectory('${tmp.path}/deploy');
    expect(r.error, isNull);
    expect(r.skills, hasLength(1));
    final s = r.skills.single;
    expect(s.name, equals('deploy'));
    expect(s.body, equals('步骤正文'));
    expect(s.assets.map((a) => a.path).toSet(),
        equals({'scripts/run.sh', 'templates/n.conf'}));
    expect(
        s.assets.firstWhere((a) => a.path.endsWith('.sh')).executable, isTrue);
    expect(
        s.assets.firstWhere((a) => a.path.endsWith('.conf')).executable,
        isFalse);
  });

  test('目录导入：父目录装了多份技能', () async {
    await writeAt('a/SKILL.md', '---\nname: a\ndescription: d\n---\nb');
    await writeAt('b/SKILL.md', '---\nname: b\ndescription: d\n---\nb');
    final r = await importSkillsFromDirectory(tmp.path);
    expect(r.skills.map((s) => s.name).toSet(), equals({'a', 'b'}));
  });

  test('目录导入：没有 SKILL.md 时报错而不是空结果', () async {
    await writeAt('random.txt', 'nope');
    final r = await importSkillsFromDirectory(tmp.path);
    expect(r.error, isNotNull);
    expect(r.skills, isEmpty);
  });

  test('目录导入：空目录报错', () async {
    await mkdir('empty');
    final r = await importSkillsFromDirectory('${tmp.path}/empty');
    expect(r.error, isNotNull);
  });

  test('目录导入：不存在的路径报错，不抛', () async {
    final r = await importSkillsFromDirectory('${tmp.path}/nope');
    expect(r.error, isNotNull);
  });

  test('目录导入：垃圾目录被跳过（__MACOSX / 隐藏目录）', () async {
    await writeAt('d/SKILL.md', '---\nname: d\ndescription: x\n---\nb');
    await writeAt('d/__MACOSX/._SKILL.md', 'junk');
    await writeAt('d/.git/config', 'junk');
    final r = await importSkillsFromDirectory('${tmp.path}/d');
    expect(r.error, isNull);
    expect(r.skills.single.assets, isEmpty, reason: '垃圾目录不该变成附件');
  });

  // ───────── zip 导入 ─────────

  test('zip 导入：目录形态 + 附件', () async {
    final z = buildZip({
      'deploy/SKILL.md': '---\nname: deploy\ndescription: d\n---\nbody',
      'deploy/run.sh': 'echo hi',
    });
    final f = File('${tmp.path}/s.zip');
    await f.writeAsBytes(z);
    final r = await importSkillsFromArchive(f.path);
    expect(r.error, isNull);
    expect(r.skills.single.name, equals('deploy'));
    expect(r.skills.single.assets.single.path, equals('run.sh'));
  });

  test('zip 导入：扁平形态', () async {
    final z = buildZip({'x.md': '---\nname: x\ndescription: d\n---\nb'});
    final f = File('${tmp.path}/s.zip');
    await f.writeAsBytes(z);
    final r = await importSkillsFromArchive(f.path);
    expect(r.skills.single.name, equals('x'));
  });

  test('zip 导入：不是 zip 时报错，不抛', () async {
    final f = await write('not.zip', '这不是 zip');
    final r = await importSkillsFromArchive(f.path);
    expect(r.error, isNotNull);
    expect(r.skills, isEmpty);
  });

  test('zip 导入：空包报错', () async {
    final f = File('${tmp.path}/empty.zip');
    await f.writeAsBytes(buildZip({}));
    final r = await importSkillsFromArchive(f.path);
    expect(r.error, isNotNull);
  });

  test('zip 导入：包里没有 SKILL.md 时报错', () async {
    final f = File('${tmp.path}/n.zip');
    await f.writeAsBytes(buildZip({'readme.txt': 'hi'}));
    final r = await importSkillsFromArchive(f.path);
    expect(r.error, isNotNull);
  });
}
