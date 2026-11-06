// 配额**接线**测试：证明 `AgentSessionManager` 真的把按 serverId 取的额度
// 传给了 `pruneNonStarred`，而不只是那个纯函数算得对。
//
// 两者是不同的事：`sessionQuotaFor` 在 repository 测试里已经钉过，但「调用点
// 是否真的用了它」只能在这里测 —— 漏接线的话纯函数测试全绿而行为不变。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_session_repository.dart';

import '_fakes.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AgentSessionRepository repo;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = AgentSessionRepository(db);
  });
  tearDown(() async => db.close());

  Future<void> seed(String serverId, int n) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final mgr = AgentSessionManager(prefs, repo);
    for (var i = 0; i < n; i++) {
      final loop = makeLoop(provider: FakeProvider([]));
      loop.debugAddEvent(UserTurnEvent('q$i'));
      mgr.register(serverId, loop);
      await mgr.archiveCurrent(serverId);
      mgr.closeLoop(serverId);
    }
  }

  test('wiring: 全局 id 走 100 的额度，普通 id 走 50', () async {
    await seed(kGlobalServerId, kSessionsGlobal + 3);
    expect((await repo.listForServer(kGlobalServerId)).length,
        equals(kSessionsGlobal),
        reason: '全局 tab 应保留 100 条');
  });

  test('wiring: 普通服务器仍是 50', () async {
    await seed('s1', kSessionsPerServer + 3);
    expect((await repo.listForServer('s1')).length, equals(kSessionsPerServer),
        reason: '普通服务器应保留 50 条');
  });
}
