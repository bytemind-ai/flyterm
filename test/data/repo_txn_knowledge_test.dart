import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('notes upsertTxn 提交后可见，回滚后消失', () async {
    final db = await AppDatabase.open(inMemory: true);
    addTearDown(db.close);
    final repo = ServerNotesRepository(db);

    await db.transaction((txn) async {
      await repo.upsertTxn(txn, serverId: 's1', body: 'note');
    });
    expect(await repo.bodyOf('s1'), 'note');

    await expectLater(
      db.transaction((txn) async {
        await repo.upsertTxn(txn, serverId: 's2', body: 'x');
        throw Exception('boom');
      }),
      throwsException,
    );
    expect(await repo.bodyOf('s2'), isNull);
  });

  test('skill upsertTxn 同名更新、异名插入', () async {
    final db = await AppDatabase.open(inMemory: true);
    addTearDown(db.close);
    final repo = AgentSkillRepository(db);

    await db.transaction((txn) async {
      await repo.upsertTxn(txn,
          name: 'S', description: 'd1', body: 'b1', source: SkillSource.manual);
    });
    var all = await repo.all();
    expect(all, hasLength(1));
    expect(all.first.body, 'b1');

    // 同名（含大小写差异）应更新而非新增
    await db.transaction((txn) async {
      await repo.upsertTxn(txn,
          name: 's', description: 'd2', body: 'b2', source: SkillSource.ai);
    });
    all = await repo.all();
    expect(all, hasLength(1), reason: 'COLLATE NOCASE 应视作同名');
    expect(all.first.body, 'b2');
  });
}
