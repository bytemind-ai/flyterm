import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/agent_session.dart';
import 'package:flyterm/data/repositories/agent_session_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AgentSessionRepository repo;
  late List<String> orphaned;

  String archiveWith(List<String> relPaths) => jsonEncode({
        'events': [
          {
            't': 'user',
            'text': 'x',
            'attachments': [
              for (final p in relPaths)
                {'kind': 'image', 'relPath': p, 'mime': 'image/png', 'bytes': 1}
            ],
          }
        ],
        'history': const [],
      });

  AgentSession sample({
    required String serverId,
    required String title,
    required String archive,
    int eventCount = 1,
    int at = 1000,
  }) =>
      AgentSession(
        serverId: serverId,
        title: title,
        archive: archive,
        eventCount: eventCount,
        createdAt: DateTime.fromMillisecondsSinceEpoch(at),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(at),
      );

  // 每个测试自开自关 —— 共享 in-memory 实例会让状态跨测试泄漏
  // （项目既有约定，见 CLAUDE.md 的 Testing Notes）。
  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    orphaned = [];
    repo = AgentSessionRepository(db,
        onAttachmentsOrphaned: (paths) async => orphaned.addAll(paths));
  });
  tearDown(() async => db.close());

  test('delete 把该段引用的附件路径报给回调', () async {
    final id = await repo.insert(sample(
      serverId: 's1',
      title: 't',
      archive: archiveWith(['s1/a.png', 's1/b.png']),
    ));

    await repo.delete(id);
    expect(orphaned, containsAll(['s1/a.png', 's1/b.png']));
  });

  test('pruneNonStarred 把被裁掉那些段的附件也报出来', () async {
    for (var i = 0; i < 3; i++) {
      await repo.insert(sample(
        serverId: 's1',
        title: 't$i',
        archive: archiveWith(['s1/img$i.png']),
        at: 1000 + i,
      ));
    }
    await repo.pruneNonStarred('s1', keep: 1);
    // 最新那段留下，另两段的图片应被报为孤儿
    expect(orphaned, hasLength(2));
  });

  test('archive 是坏 JSON 时不抛，只是收集不到路径', () async {
    final id = await repo.insert(sample(serverId: 's1', title: 't', archive: '{{{'));
    await repo.delete(id);
    expect(orphaned, isEmpty);
  });

  test('没传回调时照常删除，不崩', () async {
    final bare = AgentSessionRepository(db);
    final id = await bare.insert(sample(
      serverId: 's1',
      title: 't',
      archive: archiveWith(['s1/x.png']),
    ));
    await bare.delete(id);
    expect(await bare.byId(id), isNull);
  });

  test('allAttachmentPaths 汇总全部段的引用', () async {
    await repo.insert(sample(serverId: 's1', title: 'a', archive: archiveWith(['s1/a.png'])));
    await repo.insert(sample(serverId: 's2', title: 'b', archive: archiveWith(['s2/b.png'])));
    expect(await repo.allAttachmentPaths(), {'s1/a.png', 's2/b.png'});
  });
}
