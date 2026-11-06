// 端到端：metrics 走完整条落盘链路 —— loop -> toArchive -> JSON ->
// SQLite -> 读回 -> restoreFrom -> 新 loop 的 recorder。
//
// 上层（turn_metrics_test）已经钉过 toArchive/restore 这一对。这里补的是
// **中间那段**：`AgentSessionManager._persistActive` 的 jsonEncode 与
// `takeMostRecent` 的 jsonDecode 是否会把它原样带过去。
//
// 之所以值得单独测：那一对函数对归档内容是「原样存取、不解析」的
// （见 `AgentSession` 的类文档），所以任何新增字段都自动流过去 ——
// 但「自动」这件事本身没有任何测试保证，而它一旦不成立，
// 症状就是本文件要防的那个：会话结束后统计消失。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_session_repository.dart';

import '_fakes.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AgentSessionRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    repo = AgentSessionRepository(db);
  });
  tearDown(() async => db.close());

  test('落盘再读回：metrics 里的 token 数原样还在', () async {
    final prefs = await SharedPreferences.getInstance();
    final mgr = AgentSessionManager(prefs, repo);

    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'bash', args: {
            'command': 'uptime', 'description': '看负载', 'server': 'web-1',
          }),
        ]),
        const AIResponse(
            text: 'done',
            usage: TokenUsage(inputTokens: 8200, outputTokens: 450)),
      ]),
      runner: FakeRunner(),
      servers: const [
        ServerListEntry(id: 'id-1', name: 'web-1', host: 'h', credsOk: true),
      ],
      toolSpecs: () => fullToolSpecs,
    );
    mgr.register('s1', loop);
    await loop.send('查负载');
    await mgr.archiveCurrent('s1');
    mgr.closeLoop('s1');

    // 会话结束：loop 没了，从表里读回来
    final archive = await mgr.takeMostRecent('s1');
    expect(archive, isNotNull);
    expect(archive!.containsKey('metrics'), isTrue,
        reason: 'jsonEncode/jsonDecode 这一段必须把它原样带过去');

    final restored =
        makeLoop(provider: FakeProvider([]), restoreFrom: archive);
    expect(restored.metrics.currentRunTotals.tokens, 8650,
        reason: '会话结束后仍要显示 token 统计 —— 用户报的就是这个');
    expect(restored.metrics.currentRunTotals.toolCalls, 1);

    restored.dispose();
  });

  /// 等到表里出现至少 [expected] 行，而不是赌一个固定延迟。
  ///
  /// 落盘是 fire-and-forget 的（从同步的 notifyListeners 回调里
  /// `unawaited` 起），而且现在要穿过一层每服务器队列。写死一个毫秒数在
  /// 机器忙时就会不够 —— 轮询只是慢，不会错。
  Future<void> waitForRows(String serverId, int expected) async {
    for (var i = 0; i < 200; i++) {
      if ((await repo.listForServer(serverId)).length >= expected) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('等了 2 秒，$serverId 的行数仍未达到 $expected');
  }

  test('同一段会话反复落盘只占一行，metrics 是最新的', () async {
    final prefs = await SharedPreferences.getInstance();
    final mgr = AgentSessionManager(prefs, repo);

    final loop = makeLoop(
      provider: FakeProvider([
        const AIResponse(
            text: 'r1', usage: TokenUsage(inputTokens: 100, outputTokens: 10)),
        const AIResponse(
            text: 'r2', usage: TokenUsage(inputTokens: 300, outputTokens: 20)),
      ]),
      servers: const [],
      toolSpecs: () => fullToolSpecs,
    );
    mgr.register('s1', loop);

    // 两次真实的用户提问。**不调 `archiveCurrent`** —— 那个方法是「会话
    // 边界」，它会刻意松开当前行让下次 INSERT 新行。
    await loop.send('q1');
    await loop.send('q2');
    await waitForRows('s1', 1);
    // 再给一会，让「可能存在的第二次 INSERT」也有机会落下去 —— 竞态已修，
    // 但要证明它没回来，得给足时间。
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final rows = await repo.listForServer('s1');
    expect(rows, hasLength(1),
        reason: '同一段会话只占一行（落盘重叠不该重复 INSERT）');

    final archive = await mgr.takeMostRecent('s1');
    final restored =
        makeLoop(provider: FakeProvider([]), restoreFrom: archive);
    expect(restored.metrics.turns, isNotEmpty);
    // `currentRunTotals` 是**最近一次提问**的合计（`beginRun` 在每次
    // `_run()` 开头调用），不是整段会话。所以这里要的是 q2 的
    // 300+20，而不是两次相加 —— 后者是 `turns` 整体，不是这个 getter。
    // 这正是会话期间显示的那个数，恢复后必须一致。
    expect(restored.metrics.currentRunTotals.tokens, 320);
    expect(restored.metrics.turns, hasLength(2),
        reason: '两轮的明细都要在（每轮一行）');

    mgr.closeLoop('s1');
    restored.dispose();
  });
}
