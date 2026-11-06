import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_skill_manager.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late AgentSkillManager mgr;
  late AppControlService svc;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    mgr = AgentSkillManager(AgentSkillRepository(db));
    await mgr.reload();
    svc = AppControlService(
      settings: TerminalSettings(SecureStorageService()),
      skills: mgr,
    );
  });

  tearDown(() async => db.close());

  Future<void> seed(String name, {String desc = 'd'}) => mgr.save(
        name: name,
        description: desc,
        body: 'body of $name',
        source: SkillSource.ai,
      );

  group('listSkills', () {
    test('列出名字/描述/启用态/来源', () async {
      await seed('restart-nginx');
      final rows = svc.listSkills()!;
      expect(rows.single['name'], 'restart-nginx');
      expect(rows.single['enabled'], isTrue);
      expect(rows.single['source'], 'ai');
    });

    // in_prompt 是这组工具的核心信息：false = 存着但 AI 看不见。
    test('给出 in_prompt —— 区分「存着」和「进了 prompt」', () async {
      await seed('a');
      expect(svc.listSkills()!.single['in_prompt'], isTrue);

      await svc.setSkillEnabled('a', false);
      final row = svc.listSkills()!.single;
      expect(row['enabled'], isFalse);
      expect(row['in_prompt'], isFalse,
          reason: '禁用的技能不该被标成进了 prompt');
    });

    test('禁用的技能仍在列表里 —— 否则 AI 无从重新启用', () async {
      await seed('a');
      await svc.setSkillEnabled('a', false);
      expect(svc.listSkills(), hasLength(1));
    });

    test('带 hit_count', () async {
      await seed('a');
      expect(svc.listSkills()!.single.containsKey('hit_count'), isTrue);
    });

    test('没注入 manager 时回 null', () {
      final bare =
          AppControlService(settings: TerminalSettings(SecureStorageService()));
      expect(bare.listSkills(), isNull);
    });
  });

  group('deleteSkill', () {
    test('删掉并可撤销 —— 正文原样回来', () async {
      await seed('a');
      svc.changeLog.clear();

      final r = await svc.deleteSkill('a');
      expect(r.ok, isTrue);
      expect(svc.listSkills(), isEmpty);

      await svc.changeLog.undoAll();
      expect(svc.listSkills(), hasLength(1));
      expect(await mgr.bodyOf('a'), 'body of a');
    });

    test('删不存在的回明确错误', () async {
      final r = await svc.deleteSkill('nope');
      expect(r.ok, isFalse);
      expect(r.error, contains('No skill named'));
    });

    test('名字匹配大小写不敏感', () async {
      await seed('Restart-Nginx');
      final r = await svc.deleteSkill('restart-nginx');
      expect(r.ok, isTrue);
    });
  });

  group('setSkillEnabled', () {
    test('禁用后撤销能恢复', () async {
      await seed('a');
      svc.changeLog.clear();

      await svc.setSkillEnabled('a', false);
      expect(svc.listSkills()!.single['enabled'], isFalse);

      await svc.changeLog.undoAll();
      expect(svc.listSkills()!.single['enabled'], isTrue);
    });

    test('已是目标状态时回错误而不是静默成功', () async {
      await seed('a');
      final r = await svc.setSkillEnabled('a', true);
      expect(r.ok, isFalse);
      expect(r.error, contains('already'));
    });
  });

  group('updateSkill', () {
    test('改描述并可撤销', () async {
      await seed('a', desc: 'old');
      svc.changeLog.clear();

      await svc.updateSkill('a', description: 'new');
      expect(svc.listSkills()!.single['description'], 'new');

      await svc.changeLog.undoAll();
      expect(svc.listSkills()!.single['description'], 'old');
    });

    test('两个字段都不给时回错误', () async {
      await seed('a');
      final r = await svc.updateSkill('a');
      expect(r.ok, isFalse);
      expect(r.error, contains('at least one'));
    });
  });
}
