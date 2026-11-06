import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/server_notes_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/agent_server_notes_list_screen.dart';
import 'package:flyterm/ui/settings/agent_server_notes_sheet.dart';

/// 测一台"活着"的服务器——用来验证标题显示机器名而不是 serverId。
Server _server(String id, String name) => Server(
      id: id,
      name: name,
      host: 'example.com',
      port: 22,
      username: 'root',
      authType: 'password',
    );

void main() {
  final l = lookupAppLocalizations(const Locale('zh'));

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late ServerNotesManager mgr;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    mgr = ServerNotesManager(ServerNotesRepository(db));
    await mgr.load();
  });

  tearDown(() async => db.close());

  Future<void> pump(WidgetTester tester, List<Server> servers) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ServerNotesManager>.value(
        value: mgr,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AgentServerNotesListScreen(servers: servers),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有任何笔记时显示引导文案', (tester) async {
    await pump(tester, const []);

    expect(find.text(l.agentServerNotesOverviewEmpty), findsOneWidget);
  });

  testWidgets('列出有笔记的机器，显示机器名与行数', (tester) async {
    await tester.runAsync(() async {
      await mgr.replaceNote(serverId: 'srv-1', body: '第一行\n第二行\n第三行');
    });
    await pump(tester, [_server('srv-1', 'my-box')]);

    expect(find.text('my-box'), findsOneWidget);
    expect(find.textContaining(l.agentServerNotesLines(3)), findsOneWidget);
  });

  testWidgets('机器已被删掉但笔记还在时，退回显示 serverId，不崩', (tester) async {
    await tester.runAsync(() async {
      await mgr.replaceNote(serverId: 'ghost-id', body: '孤儿笔记');
    });
    // 传入的 servers 列表里没有 ghost-id —— 模拟服务器已经被删除。
    await pump(tester, const []);

    expect(find.text('ghost-id'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('能删掉一份笔记', (tester) async {
    await tester.runAsync(() async {
      await mgr.replaceNote(serverId: 'srv-1', body: '待删除');
    });
    await pump(tester, [_server('srv-1', 'my-box')]);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (mgr.noteFor('srv-1') != null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();

    expect(mgr.noteFor('srv-1'), isNull);
  });

  testWidgets('点条目能进编辑 sheet', (tester) async {
    await tester.runAsync(() async {
      await mgr.replaceNote(serverId: 'srv-1', body: '内容');
    });
    await pump(tester, [_server('srv-1', 'my-box')]);

    await tester.tap(find.text('my-box'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentServerNotesSheet), findsOneWidget);
  });
}
