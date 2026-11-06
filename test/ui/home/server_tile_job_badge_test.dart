import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:flyterm/ui/home/home_screen.dart';
import 'package:flyterm/ui/ui_flags.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // 用 `databaseFactoryFfiNoIsolate` 而不是计划原文里的
    // `databaseFactoryFfi`：本测试会插入一条服务器记录并通过
    // `HomeScreen` 的 `FutureBuilder` 真实渲染出来，这正是
    // `test/ui/shell/app_shell_test.dart` 注释里记录的会挂死
    // 10 分钟的场景（非空查询结果 + `tester.runAsync` + 后台 isolate）。
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late ServerRepository repo;
  late SessionManager mgr;
  late String serverId;

  setUp(() async {
    // 本文件断言的是「徽标逻辑对不对」，不是「看板要不要显示」——那条
    // 由 `kShowJobBoard` 另管，编译期默认 false 会让下面所有断言落空。
    debugShowJobBoardOverride = true;
    db = await AppDatabase.open(inMemory: true);
    repo = ServerRepository(db);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    mgr = SessionManager(prefs: prefs);
    serverId = const Uuid().v4();
    await repo.insert(Server(
      id: serverId,
      name: 'prod-web',
      host: 'prod.example.com',
      port: 22,
      username: 'root',
      authType: 'password',
    ));
  });

  tearDown(() async {
    debugShowJobBoardOverride = null;
    await db.close();
  });

  Widget app(Map<String, int> counts) => MultiProvider(
        providers: [
          Provider<ServerRepository>.value(value: repo),
          ChangeNotifierProvider<SessionManager>.value(value: mgr),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HomeScreen(debugJobCounts: counts),
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  }

  testWidgets('有运行中的 job 时渲染徽标，数字正确', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app({serverId: 3}));
      await settle(tester);

      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });

  testWidgets('job 数为 0 时不渲染徽标', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app({serverId: 0}));
      await settle(tester);

      expect(find.byIcon(Icons.play_circle_outline), findsNothing);

      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });

  testWidgets('没扫过（key 不在 Map 里）时不渲染徽标', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app(const {}));
      await settle(tester);

      expect(find.byIcon(Icons.play_circle_outline), findsNothing);

      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });
}
