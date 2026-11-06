import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/ai_command_manager.dart';
import 'package:flyterm/ai/agent/saved_command_index.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/favorite_command.dart';
import 'package:flyterm/data/repositories/favorite_command_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late FavoriteCommandRepository repo;
  late AiCommandManager mgr;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = FavoriteCommandRepository(db);
    mgr = AiCommandManager(repo);
    await mgr.reload();
  });

  tearDown(() async => db.close());

  // 这几条复刻 terminal_screen.dart 里那两个闭包的写法，守的是「勾选之后
  // 下一轮生效」这个不变量。有人把它挪到闭包外面当快照，这里会红。
  test('勾选之后下一轮就进 prompt', () async {
    String promptNow() => buildAgentSystemPrompt(
          cwd: null,
          terminalContext: null,
          savedCommandIndex: composeSavedCommandIndex(mgr.indexEntries),
        );

    expect(promptNow(), isNot(contains('部署服务')));
    await repo.insert(const FavoriteCommand(
        id: 'd', name: '部署服务', command: 'deploy {{s}}', aiEnabled: true));
    await mgr.reload();
    expect(promptNow(), contains('部署服务 [s]: deploy {{s}}'));
  });

  test('第一条勾选之后工具清单才出现 run_saved_command', () async {
    List<String> toolsNow() => agentToolSpecsFor(AgentToolTier.full,
            hasSavedCommands: mgr.indexEntries.isNotEmpty)
        .map((s) => s.name)
        .toList();

    expect(toolsNow(), isNot(contains('run_saved_command')));
    await repo.insert(const FavoriteCommand(
        id: 'x', name: 'x', command: 'ls', aiEnabled: true));
    await mgr.reload();
    expect(toolsNow(), contains('run_saved_command'));
  });

  test('取消勾选之后工具又消失', () async {
    const cmd =
        FavoriteCommand(id: 'x', name: 'x', command: 'ls', aiEnabled: true);
    await repo.insert(cmd);
    await mgr.reload();
    expect(mgr.indexEntries, isNotEmpty);

    await repo.update(cmd.copyWith(aiEnabled: false));
    await mgr.reload();
    expect(mgr.indexEntries, isEmpty,
        reason: '否则模型会调一个必然失败的工具');
  });

  test('byName 能给 AgentLoop 用 —— 同步，且只认进了索引的', () async {
    await repo.insert(const FavoriteCommand(
        id: 'a', name: '开放', command: 'ls', aiEnabled: true));
    await repo.insert(const FavoriteCommand(
        id: 'b', name: '未开放', command: 'ps', aiEnabled: false));
    await mgr.reload();

    expect(mgr.byName('开放'), isNotNull);
    expect(mgr.byName('未开放'), isNull);
  });
}
