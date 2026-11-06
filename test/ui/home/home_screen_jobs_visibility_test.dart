// 回归测试：后台任务看板的编译期开关（`lib/ui/ui_flags.dart` 的
// `kShowJobBoard`）关掉时，首页 AppBar 的任务入口必须整个消失——不是禁用，
// 是不渲染。复用 `server_tile_job_badge_test.dart` 的最小 provider 搭法
// （`HomeScreen(debugJobCounts: ...)` 绕开真实 SSH/扫描）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:flyterm/ui/home/home_screen.dart';
import 'package:flyterm/ui/ui_flags.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late ServerRepository repo;
  late SessionManager mgr;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = ServerRepository(db);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    mgr = SessionManager(prefs: prefs);
  });

  tearDown(() async {
    debugShowJobBoardOverride = null;
    await db.close();
  });

  Widget app() => MultiProvider(
        providers: [
          Provider<ServerRepository>.value(value: repo),
          ChangeNotifierProvider<SessionManager>.value(value: mgr),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomeScreen(debugJobCounts: {}),
        ),
      );

  // `HomeScreen.initState` 用真实 `Future.delayed(seconds: 3)` 触发更新检查
  // （与本测试无关，但它是真实 Timer）。不用 `tester.runAsync` 包裹、把它
  // 喂完的话，测试结束时 widget 树已 dispose 而 Timer 还挂着，
  // flutter_test 的 `!timersPending` 断言会炸——`server_tile_job_badge_test.dart`
  // 已经踩过这个坑，这里照抄同一个套路。
  testWidgets('kShowJobBoard 为 false 时首页不出现任务按钮', (tester) async {
    await tester.runAsync(() async {
      debugShowJobBoardOverride = false;
      await tester.pumpWidget(app());
      await tester.pump();

      expect(find.byIcon(Icons.list_alt_outlined), findsNothing);

      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });

  testWidgets('kShowJobBoard 为 true 时首页出现任务按钮', (tester) async {
    await tester.runAsync(() async {
      debugShowJobBoardOverride = true;
      await tester.pumpWidget(app());
      await tester.pump();

      expect(find.byIcon(Icons.list_alt_outlined), findsOneWidget);

      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });
}
