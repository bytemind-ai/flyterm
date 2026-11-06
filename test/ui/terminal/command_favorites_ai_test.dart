import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/ai_command_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/favorite_command.dart';
import 'package:flyterm/data/repositories/favorite_command_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/terminal/command_favorites_sheet.dart';

/// ## 为什么这里所有碰数据库的调用都裹着 `tester.runAsync`
///
/// `testWidgets` 的回调跑在 flutter_test 的 fake-async zone 里，`Timer` 和
/// microtask 由 `FakeAsync` 接管、只有 `tester.pump()` 才推进；而 sqflite 的
/// 异步靠真实 timer 实现，那个 Future 永远不会完成——不是断言失败，是
/// `pumpAndSettle` 一直转到默认 10 分钟超时。`setUp` 不在这个 zone 里，
/// 所以 `setUp` 里 await 数据库是正常的。点击触发的写入必须让 tap 本身
/// 发生在真实 zone 里，事后补 runAsync + delay 推不动 fake zone 里创建的
/// Future。见 test/ui/settings/agent_skills_screen_test.dart 顶部的完整记录。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late FavoriteCommandRepository repo;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = FavoriteCommandRepository(db);
  });

  tearDown(() async => db.close());

  Future<void> seed(WidgetTester tester, FavoriteCommand cmd) =>
      tester.runAsync(() => repo.insert(cmd));

  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider.value(value: repo),
        // command_favorites_sheet.dart 增删改排序之后都会 reload() 这个
        // manager —— 缺了这个 provider，那些调用会在 context.read 处抛异常。
        ChangeNotifierProvider.value(value: AiCommandManager(repo)),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: CommandFavoritesSheet()),
      ),
    ));
    // CommandFavoritesSheet 自己在 initState 里发起 repo.findAll() —— 这个
    // Future 在 fake-async zone 里创建，靠真实 timer 才能落地，pump()/
    // pumpAndSettle() 推不动它。用 runAsync 顶一下真实事件循环，让它有机会
    // 完成，再切回 fake zone 让 widget 树用新状态（_loading=false）重建。
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 50)));
    await tester.pump();
    await settle(tester);
  }

  testWidgets('对 AI 开放的条目有标记', (tester) async {
    await seed(
        tester,
        const FavoriteCommand(
            id: 'a', name: '开放', command: 'ls', aiEnabled: true));
    await pump(tester);
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
  });

  testWidgets('未开放的条目没有标记', (tester) async {
    await seed(
        tester, const FavoriteCommand(id: 'b', name: '不开放', command: 'ps'));
    await pump(tester);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });

  testWidgets('有开放条目时显示预算行', (tester) async {
    await seed(
        tester,
        const FavoriteCommand(
            id: 'a', name: '开放', command: 'ls', aiEnabled: true));
    await pump(tester);
    expect(find.textContaining('token'), findsOneWidget);
  });

  testWidgets('一条都没开放时不显示预算行', (tester) async {
    await seed(
        tester, const FavoriteCommand(id: 'b', name: '不开放', command: 'ps'));
    await pump(tester);
    expect(find.textContaining('token'), findsNothing);
  });

  testWidgets('编辑对话框里有 AI 开关', (tester) async {
    await seed(
        tester, const FavoriteCommand(id: 'b', name: '某条', command: 'ps'));
    await pump(tester);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await settle(tester);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.textContaining('允许 AI'), findsOneWidget);
  });

  testWidgets('编辑时打开开关并保存后落库', (tester) async {
    await seed(
        tester, const FavoriteCommand(id: 'b', name: '某条', command: 'ps'));
    await pump(tester);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await settle(tester);

    // 开关和保存都会触发数据库写入 —— tap 必须发生在真实 zone 里，
    // 事后再 runAsync 一个 delay 是推不动 fake zone 里那个 Future 的。
    await tester.runAsync(() async {
      await tester.tap(find.byType(SwitchListTile));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('保存'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    final rows = await tester.runAsync(() => repo.findAll());
    expect(rows!.single.aiEnabled, isTrue);
  });
}
