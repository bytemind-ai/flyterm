import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/agent_assembly.dart';
import 'package:flyterm/ai/agent/app_permission.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/agent_skill_manager.dart';
import 'package:flyterm/ai/agent/ai_command_manager.dart';
import 'package:flyterm/ai/agent/builtin_skill_manager.dart';
import 'package:flyterm/ai/agent/server_notes_manager.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/agent_session_repository.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/data/repositories/favorite_command_repository.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/ssh/session_manager.dart';

void main() {
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
  });

  tearDown(() async => db.close());

  testWidgets('fromContext 把一棵 provider 树收成一个句柄包', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final storage = SecureStorageService();
    AgentAssemblyDeps? captured;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SecureStorageService>.value(value: storage),
          Provider<ServerRepository>(create: (_) => ServerRepository(db)),
          ChangeNotifierProvider<SessionManager>(
            create: (_) => SessionManager(prefs: prefs),
          ),
          ChangeNotifierProvider<AIProviderService>.value(
              value: AIProviderService(prefs)),
          // 四个 manager 的构造与 `lib/main.dart:344-362` 一致：
          // AgentSessionManager 的 repo 是**可选位置参数**（不是命名参数），
          // AiCommandManager 收的是 FavoriteCommandRepository（不是 prefs）。
          ChangeNotifierProvider<AgentSessionManager>(
            create: (_) =>
                AgentSessionManager(prefs, AgentSessionRepository(db)),
          ),
          ChangeNotifierProvider<AgentSkillManager>(
            create: (_) => AgentSkillManager(AgentSkillRepository(db)),
          ),
          ChangeNotifierProvider<BuiltinSkillManager>(
            create: (_) => BuiltinSkillManager(prefs),
          ),
          ChangeNotifierProvider<AiCommandManager>(
            create: (_) => AiCommandManager(FavoriteCommandRepository(db)),
          ),
          ChangeNotifierProvider<ServerNotesManager>(
            create: (_) => ServerNotesManager(ServerNotesRepository(db)),
          ),
        ],
        child: Builder(
          builder: (ctx) {
            captured = AgentAssemblyDeps.fromContext(ctx);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(captured, isNotNull);
    expect(captured!.servers, isNotNull);
    expect(captured!.sessions, isNotNull);
    expect(captured!.agentMgr, isNotNull);
    // 可空依赖缺席时不抛,降级成 null —— 见实现里的说明。
    expect(captured!.settings, isNull);
    expect(captured!.attachments, isNull);
    expect(captured!.appControl, isNull);
  });

  group('shouldDeclareAppTools', () {
    test('有 appControl 就声明 —— 不再有「关闭 app 工具」这一档', () {
      // `AppPermissionMode.off` 已随两档合并（2026-10-13）被删除，
      // 所以现在只剩 `hasService` 一个条件。
      expect(shouldDeclareAppTools(hasService: true), isTrue);
    });

    test('没有 appControl 时不声明 —— 否则调用必然回 not available', () {
      expect(shouldDeclareAppTools(hasService: false), isFalse);
    });
  });

  group('buildAgentLoop 装配的 serverNoteSaver', () {
    // `save_note` 的执行器（`skill_executors.dart`）把 `server` 参数解析成
    // id 之后原样转发给这个闭包；null 表示模型没传 `server`。这里要钉死的
    // 是闭包本身怎么决定「null 落到哪」——猜错会把一台机器的事实写进另一台
    // 的笔记，而且没人会发现，所以宁可报错也不猜。
    AgentAssemblyDeps depsWith(
      Database db,
      SharedPreferences prefs, {
      required ServerNotesManager serverNotes,
    }) =>
        AgentAssemblyDeps(
          servers: ServerRepository(db),
          sessions: SessionManager(prefs: prefs),
          storage: SecureStorageService(),
          agentMgr: AgentSessionManager(prefs, AgentSessionRepository(db)),
          ai: AIProviderService(prefs),
          skills: AgentSkillManager(AgentSkillRepository(db)),
          builtinSkills: BuiltinSkillManager(prefs),
          savedCommands: AiCommandManager(FavoriteCommandRepository(db)),
          serverNotes: serverNotes,
        );

    test('全局会话（defaultServer 为 null）且模型没传 server → 报错，不猜落点',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final notes = ServerNotesManager(ServerNotesRepository(db));
      final deps = depsWith(db, prefs, serverNotes: notes);

      final loop = buildAgentLoop(
        deps: deps,
        sessionKey: 'global',
        defaultServer: null,
        serverCache: () => const [],
        languageTag: 'en',
      );

      final r = await loop.serverNoteSaver!(null, 'containers', 'uses podman');

      expect(r.ok, isFalse);
      expect(r.error, contains('server'));
    });

    test('单机会话里不传 server → 落到当前这台（defaultServer）', () async {
      final prefs = await SharedPreferences.getInstance();
      final notes = ServerNotesManager(ServerNotesRepository(db));
      final deps = depsWith(db, prefs, serverNotes: notes);
      const server = Server(
        id: 's1',
        name: 'dk',
        host: 'h',
        port: 22,
        username: 'u',
        authType: 'password',
      );

      final loop = buildAgentLoop(
        deps: deps,
        sessionKey: server.id,
        defaultServer: server,
        serverCache: () => const [server],
        languageTag: 'en',
      );

      final r = await loop.serverNoteSaver!(null, 'containers', 'uses podman');

      expect(r.ok, isTrue);
      expect(notes.noteFor('s1'), contains('uses podman'));
    });

    test('单机会话里模型显式传了别的 serverId → 用模型给的，不用 defaultServer',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final notes = ServerNotesManager(ServerNotesRepository(db));
      final deps = depsWith(db, prefs, serverNotes: notes);
      const server = Server(
        id: 's1',
        name: 'dk',
        host: 'h',
        port: 22,
        username: 'u',
        authType: 'password',
      );

      final loop = buildAgentLoop(
        deps: deps,
        sessionKey: server.id,
        defaultServer: server,
        serverCache: () => const [server],
        languageTag: 'en',
      );

      final r = await loop.serverNoteSaver!('s2', 'containers', 'uses docker');

      expect(r.ok, isTrue);
      expect(notes.noteFor('s1'), isNull);
      expect(notes.noteFor('s2'), contains('uses docker'));
    });
  });
}
