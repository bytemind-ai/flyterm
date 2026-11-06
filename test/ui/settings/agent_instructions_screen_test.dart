import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/server_notes_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/agent_instructions_screen.dart';

// 这一页新增了「机器笔记总览」入口，需要 ServerNotesManager（渲染笔记数）
// 和 ServerRepository（点击后 findAll）两个 provider —— 用内存 sqflite
// 搭一套最小依赖，不测总览页本身的行为（那边有专门的
// agent_server_notes_list_test.dart）。
Widget _wrap(AgentSessionManager mgr, {required Database db}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AgentSessionManager>.value(value: mgr),
        Provider<ServerRepository>(create: (_) => ServerRepository(db)),
        // 不调 load()：这些用例只关心全局说明输入框，不关心笔记数量，
        // 空缓存（notes == []）已经够用。真正调一次 load() 是异步的，
        // fire-and-forget 到 widget 树已经 dispose 之后才完成的话，会在
        // tearDown 之后触发「used after disposed」。
        ChangeNotifierProvider<ServerNotesManager>(
          create: (_) => ServerNotesManager(ServerNotesRepository(db)),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AgentInstructionsScreen(),
      ),
    );

void main() {
  final l = lookupAppLocalizations(const Locale('zh'));

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
  });

  tearDown(() async => db.close());

  testWidgets('输入并保存后落盘', (tester) async {
    final mgr = AgentSessionManager(await SharedPreferences.getInstance());

    await tester.pumpWidget(_wrap(mgr, db: db));
    await tester.enterText(find.byType(TextField), '回答简洁点');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(mgr.instructions, equals('回答简洁点'));
  });

  testWidgets('已有的说明进入时预填', (tester) async {
    final mgr = AgentSessionManager(await SharedPreferences.getInstance());
    mgr.instructions = '先说结论';

    await tester.pumpWidget(_wrap(mgr, db: db));

    expect(find.text('先说结论'), findsOneWidget);
  });

  testWidgets('超出字节上限时提示变成警告文案', (tester) async {
    final mgr = AgentSessionManager(await SharedPreferences.getInstance());

    await tester.pumpWidget(_wrap(mgr, db: db));
    await tester.enterText(find.byType(TextField), 'x' * 5000);
    await tester.pump();

    expect(find.textContaining('超出'), findsOneWidget);
  });

  // 这个页面现在**只管全局说明**。单台机器的笔记搬去了
  // AgentServerNotesSheet（入口在服务器编辑页，数据存 app 端 SQLite）——
  // 从「这台机器的说明」进来的人要看的就是那份，主次不该颠倒成「大的
  // 全局编辑框在上、这台机器的内容在下」。
  testWidgets('页面里不再有远端说明那一段', (tester) async {
    final mgr = AgentSessionManager(await SharedPreferences.getInstance());

    await tester.pumpWidget(_wrap(mgr, db: db));

    expect(find.textContaining('尚未同步'), findsNothing);
    // 只有全局那一个输入框
    expect(find.byType(TextField), findsOneWidget);
  });

  group('示例 chips', () {
    testWidgets('三个示例都在，点一下插入输入框', (tester) async {
      // 「告诉 AI 你希望它怎么回答」很抽象，面对空白输入框多数人不知道
      // 写什么。示例把抽象要求变成可直接用的东西。
      final mgr = AgentSessionManager(await SharedPreferences.getInstance());
      await tester.pumpWidget(_wrap(mgr, db: db));

      expect(find.text(l.agentInstructionsExample1), findsOneWidget);
      expect(find.text(l.agentInstructionsExample2), findsOneWidget);
      expect(find.text(l.agentInstructionsExample3), findsOneWidget);

      await tester.tap(find.widgetWithText(ActionChip, l.agentInstructionsExample1));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        equals(l.agentInstructionsExample1),
      );
    });

    testWidgets('点第二个是追加，不是覆盖', (tester) async {
      // 用户可能已经写了一条，点另一个例子是想加上去。
      final mgr = AgentSessionManager(await SharedPreferences.getInstance());
      await tester.pumpWidget(_wrap(mgr, db: db));

      await tester.tap(find.widgetWithText(ActionChip, l.agentInstructionsExample1));
      await tester.pump();
      await tester.tap(find.widgetWithText(ActionChip, l.agentInstructionsExample2));
      await tester.pump();

      final text =
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      expect(text, contains(l.agentInstructionsExample1));
      expect(text, contains(l.agentInstructionsExample2));
      expect(text.split('\n'), hasLength(2));
    });

    testWidgets('同一个示例点两次不会插两遍', (tester) async {
      final mgr = AgentSessionManager(await SharedPreferences.getInstance());
      await tester.pumpWidget(_wrap(mgr, db: db));

      await tester.tap(find.widgetWithText(ActionChip, l.agentInstructionsExample1));
      await tester.pump();
      await tester.tap(find.widgetWithText(ActionChip, l.agentInstructionsExample1));
      await tester.pump();

      final text =
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      expect(l.agentInstructionsExample1.allMatches(text), hasLength(1));
    });

    testWidgets('已有内容时插入示例保留原有内容', (tester) async {
      final mgr = AgentSessionManager(await SharedPreferences.getInstance());
      mgr.instructions = '用中文';
      await tester.pumpWidget(_wrap(mgr, db: db));

      await tester.tap(find.widgetWithText(ActionChip, l.agentInstructionsExample1));
      await tester.pump();

      final text =
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      expect(text, contains('用中文'));
      expect(text, contains(l.agentInstructionsExample1));
    });

    testWidgets('插入后保存，落盘的是拼好的内容', (tester) async {
      final mgr = AgentSessionManager(await SharedPreferences.getInstance());
      await tester.pumpWidget(_wrap(mgr, db: db));

      await tester.tap(find.widgetWithText(ActionChip, l.agentInstructionsExample1));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      expect(mgr.instructions, equals(l.agentInstructionsExample1));
    });
  });
}
