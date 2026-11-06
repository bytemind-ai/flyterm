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

  // 每个测试自开自关 —— 共享 in-memory 实例会让状态跨测试泄漏
  // （项目既有约定，见 CLAUDE.md 的 Testing Notes）。
  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = AgentSessionRepository(db);
  });
  tearDown(() async => db.close());

  AgentSession sample({
    String serverId = 's1',
    String? title = 'why 502',
    String archive = '{"events":[]}',
    int eventCount = 3,
    bool starred = false,
    int at = 1000,
  }) =>
      AgentSession(
        serverId: serverId,
        title: title,
        archive: archive,
        eventCount: eventCount,
        starred: starred,
        createdAt: DateTime.fromMillisecondsSinceEpoch(at),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(at),
      );

  test('插入后按 server 倒序列出', () async {
    await repo.insert(sample(title: 'old', at: 1000));
    await repo.insert(sample(title: 'new', at: 2000));
    await repo.insert(sample(serverId: 's2', title: 'other', at: 3000));

    final rows = await repo.listForServer('s1');
    expect(rows.map((r) => r.title).toList(), equals(['new', 'old']));
  });

  test('archive 逐字节取回 —— 它是 JSON，不能被任何转换碰过', () async {
    const raw = '{"events":[{"t":"user","text":"a\\"b\\\\c"}],"history":[]}';
    final id = await repo.insert(sample(archive: raw));
    final back = await repo.byId(id);
    expect(back!.archive, equals(raw));
  });

  test('滚动删除跳过标星：53 段里 3 段标星 → 剩 50 非标星 + 3 标星', () async {
    for (var i = 0; i < 53; i++) {
      await repo.insert(sample(title: 'n$i', at: 1000 + i));
    }
    // 把最旧的三段标星 —— 它们本该最先被删，标星后不该被删
    final all = await repo.listForServer('s1');
    for (final s in all.sublist(50)) {
      await repo.setStarred(s.id!, true);
    }

    await repo.pruneNonStarred('s1');

    final left = await repo.listForServer('s1');
    expect(left.where((r) => !r.starred).length, equals(kSessionsPerServer));
    expect(left.where((r) => r.starred).length, equals(3));
    expect(left.length, equals(kSessionsPerServer + 3));
  });

  test('标星段不计入配额', () async {
    // 先塞满 kSessionsPerServer 段标星，再塞 5 段普通 —— 普通那 5 段一条都不该被删
    for (var i = 0; i < kSessionsPerServer; i++) {
      final id = await repo.insert(sample(title: 'star$i', at: 1000 + i));
      await repo.setStarred(id, true);
    }
    for (var i = 0; i < 5; i++) {
      await repo.insert(sample(title: 'plain$i', at: 2000 + i));
    }

    await repo.pruneNonStarred('s1');

    final left = await repo.listForServer('s1');
    expect(left.where((r) => !r.starred).length, equals(5));
    expect(left.length, equals(kSessionsPerServer + 5));
  });

  test('滚动删除不跨 server', () async {
    for (var i = 0; i < kSessionsPerServer + 5; i++) {
      await repo.insert(sample(serverId: 's1', at: 1000 + i));
    }
    for (var i = 0; i < 5; i++) {
      await repo.insert(sample(serverId: 's2', at: 1000 + i));
    }

    await repo.pruneNonStarred('s1');

    expect((await repo.listForServer('s1')).length, equals(kSessionsPerServer));
    expect((await repo.listForServer('s2')).length, equals(5),
        reason: 's2 的段数没超限，不该被 s1 的清理波及');
  });

  test('mostRecent 取 updated_at 最大的那段', () async {
    await repo.insert(sample(title: 'a', at: 1000));
    await repo.insert(sample(title: 'b', at: 3000));
    await repo.insert(sample(title: 'c', at: 2000));

    expect((await repo.mostRecent('s1'))!.title, equals('b'));
    expect(await repo.mostRecent('nope'), isNull);
  });

  test('delete 与 setStarred', () async {
    final id = await repo.insert(sample());
    await repo.setStarred(id, true);
    expect((await repo.byId(id))!.starred, isTrue);
    await repo.setStarred(id, false);
    expect((await repo.byId(id))!.starred, isFalse);
    await repo.delete(id);
    expect(await repo.byId(id), isNull);
  });

  test('title 可以为 null（从「长按报错 → AI 分析」进来的会话）', () async {
    final id = await repo.insert(sample(title: null));
    expect((await repo.byId(id))!.title, isNull);
  });

  group('sessionQuotaFor —— 全局 AI 比普通服务器宽', () {
    test('普通 serverId 用 kSessionsPerServer', () {
      expect(sessionQuotaFor('s1'), kSessionsPerServer);
      expect(sessionQuotaFor('a-uuid-v4'), kSessionsPerServer);
    });

    test('全局 tab 用 kSessionsGlobal', () {
      expect(sessionQuotaFor(kGlobalServerId), kSessionsGlobal);
    });

    test('两档确实不同 —— 否则分档没意义', () {
      expect(kSessionsGlobal, greaterThan(kSessionsPerServer),
          reason: '全局 tab 是「随手问 + 跨机排查」的地方，会话密度更高');
    });

    test('全局额度真的生效：全局 id 下 100 段不触发裁剪', () async {
      // 这条是本改动的**行为**断言（不只测那个纯函数）：用全局 serverId
      // 插入超 100 的分量，看 prune 到底留了多少。
      for (var i = 0; i < kSessionsGlobal + 3; i++) {
        await repo.insert(sample(serverId: kGlobalServerId, at: 1000 + i));
      }
      await repo.pruneNonStarred(kGlobalServerId,
          keep: sessionQuotaFor(kGlobalServerId));
      expect((await repo.listForServer(kGlobalServerId)).length,
          equals(kSessionsGlobal));
    });

    test('普通服务器的额度不受全局提高的影响', () async {
      for (var i = 0; i < kSessionsPerServer + 3; i++) {
        await repo.insert(sample(serverId: 's1', at: 1000 + i));
      }
      await repo.pruneNonStarred('s1', keep: sessionQuotaFor('s1'));
      expect((await repo.listForServer('s1')).length,
          equals(kSessionsPerServer));
    });
  });
}
