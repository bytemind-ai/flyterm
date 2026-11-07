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
import 'package:flyterm/tunnel/tunnel_manager.dart';
import 'package:flyterm/ui/home/home_screen.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // 非空查询 + FutureBuilder 必须用 NoIsolate 工厂（见 app_shell_test 注释）。
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late ServerRepository repo;
  late SessionManager mgr;
  late String serverId;

  setUp(() async {
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
    await db.close();
  });

  Widget app({
    Map<String, int> tunnelCounts = const {},
    bool forceNewTab = false,
  }) =>
      MultiProvider(
        providers: [
          Provider<ServerRepository>.value(value: repo),
          ChangeNotifierProvider<SessionManager>.value(value: mgr),
          ChangeNotifierProvider<TunnelManager>.value(value: TunnelManager()),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HomeScreen(
            forceNewTab: forceNewTab,
            debugJobCounts: const {},
            debugTunnelCounts: tunnelCounts,
          ),
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  }

  // IndexedStack 的未选中子树不会被标记为 offstage，finder 仍能命中其中的
  // 文本（`暂无隧道` / `新建隧道`）。因此"当前在哪个分段"只能由
  // `SegmentedButton.selected` 断言，不能用文本 finder 断言"某内容不存在"。
  //
  // 生产代码用的是 `SegmentedButton<_HomeSegment>`（保留强类型），
  // `find.byType(SegmentedButton)` 是 `SegmentedButton<dynamic>` 的精确匹配、
  // 命不中带类型参数的那个，所以这里用 `byWidgetPredicate`。
  Finder segmentFinder() =>
      find.byWidgetPredicate((w) => w is SegmentedButton);

  String selectedSegment(WidgetTester tester) {
    final seg = tester.widget<SegmentedButton<dynamic>>(segmentFinder());
    return seg.selected.single.toString();
  }

  testWidgets('默认在服务器段', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app());
      await settle(tester);
      expect(segmentFinder(), findsOneWidget);
      expect(find.text('prod-web'), findsWidgets);
      expect(selectedSegment(tester), '_HomeSegment.servers');
      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });

  testWidgets('切到隧道段', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app());
      await settle(tester);

      await tester.tap(find.text('隧道 0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(selectedSegment(tester), '_HomeSegment.tunnels');
      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });

  testWidgets('有隧道计数时服务器行渲染徽标', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app(tunnelCounts: {serverId: 2}));
      await settle(tester);

      expect(find.text('2 隧道'), findsOneWidget);
      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });

  testWidgets('forceNewTab 模式不渲染分段', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app(forceNewTab: true));
      await settle(tester);

      expect(segmentFinder(), findsNothing);
      expect(find.text('prod-web'), findsWidgets);
      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });
}
