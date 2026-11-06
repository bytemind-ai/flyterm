import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:flyterm/ui/shell/app_shell.dart';
import 'package:flyterm/ai/voice_input_service.dart';

/// 点底部导航的某个 tab。
///
/// **必须把 finder 限定在 ShellNavBar 里**：`IndexedStack` 把三页全都留在
/// widget 树中（只是不绘制），而 `GlobalAIScreen` 的 AppBar 标题也是 'AI'。
/// 裸的 `find.text('AI')` 会命中两个，`tap` 直接报 "Found 2 widgets"。
Future<void> tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(ShellNavBar),
    matching: find.text(label),
  ));
}

/// Stand-in for SettingsScreen: a page that imports a server (writes to the
/// repo) — mirrors what the real config-import flow does.
///
/// 不再需要 `Navigator.pop()`：设置现在是一个 tab，不是 push 出来的页面。
/// 用户靠点底部的「服务器」回去，而那一下正是触发刷新的事件。
class _FakeSettingsPage extends StatelessWidget {
  const _FakeSettingsPage({required this.repo, required this.server});
  final ServerRepository repo;
  final Server server;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const Key('import'),
            onPressed: () => repo.insert(server),
            child: const Text('Import'),
          ),
        ),
      );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // 用 `databaseFactoryFfiNoIsolate` 而不是仓库里更常见的
    // `databaseFactoryFfi`：后者在「非空查询结果 + `tester.runAsync` +
    // populated 的 widget 子树」这个组合下会在 test body 跑完之后、
    // `tearDown` 之前卡死（不是断言失败，是进程挂起到默认超时）。在
    // `app_shell_test.dart` 里用裸 `HomeScreen`（完全不经过 `AppShell`）
    // 复现过同样的卡死，确认是 `sqflite_common_ffi` 后台 isolate 通信与
    // flutter_test binding 收尾逻辑的既有交互问题，与本文件测的刷新逻辑
    // 无关。`databaseFactoryFfiNoIsolate` 去掉了那层后台 isolate。
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late ServerRepository repo;
  late SessionManager mgr;
  late SharedPreferences prefs;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = ServerRepository(db);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    mgr = SessionManager(prefs: prefs);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets(
      'server list refreshes after switching back from the settings tab '
      '(config import)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final imported = Server(
      id: const Uuid().v4(),
      name: 'Imported Server',
      host: 'imported.example.com',
      port: 22,
      username: 'root',
      authType: 'password',
    );

    final app = MultiProvider(
      providers: [
        Provider<SharedPreferences>.value(value: prefs),
        Provider<ServerRepository>.value(value: repo),
        ChangeNotifierProvider<SessionManager>.value(value: mgr),
        // `AIProviderService` 要 prefs（不是无参构造），照
        // `test/ui/ai/ai_panel_test.dart:67` 的既有写法。
        ChangeNotifierProvider<AIProviderService>.value(
            value: AIProviderService(prefs)),
        ChangeNotifierProvider<VoiceInputService>.value(
            value: VoiceInputService()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppShell(
          settingsPage: _FakeSettingsPage(repo: repo, server: imported),
        ),
      ),
    );

    // The home list reads servers via FutureBuilder over a real (ffi) DB, so
    // the futures only resolve under runAsync — fake-async pump() won't drain
    // them, and the loading spinner never lets pumpAndSettle settle.
    await tester.runAsync(() async {
      await tester.pumpWidget(app);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      // Initial load: DB empty → no servers shown.
      expect(find.text('Imported Server'), findsNothing);

      // Go to the settings tab (the entry point that previously forgot to
      // reload — now covered by ServerListRefreshSignal).
      await tapTab(tester, '设置');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      await tester.tap(find.byKey(const Key('import')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      // Switch back to the servers tab — this is what fires the signal.
      await tapTab(tester, '服务器');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      // The list must reflect the newly imported server.
      expect(find.text('Imported Server'), findsOneWidget);

      // Let the deferred initState update-check timer fire (noop on this host).
      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });

  testWidgets('切到 AI tab 再回来不触发重查（只有设置 tab 会）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final sneaky = Server(
      id: const Uuid().v4(),
      name: 'Sneaky Server',
      host: 'sneaky.example.com',
      port: 22,
      username: 'root',
      authType: 'password',
    );

    final app = MultiProvider(
      providers: [
        Provider<SharedPreferences>.value(value: prefs),
        Provider<ServerRepository>.value(value: repo),
        ChangeNotifierProvider<SessionManager>.value(value: mgr),
        // `AIProviderService` 要 prefs（不是无参构造），照
        // `test/ui/ai/ai_panel_test.dart:67` 的既有写法。
        ChangeNotifierProvider<AIProviderService>.value(
            value: AIProviderService(prefs)),
        ChangeNotifierProvider<VoiceInputService>.value(
            value: VoiceInputService()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AppShell(
          settingsPage: Scaffold(body: Center(child: Text('FAKE-SETTINGS'))),
        ),
      ),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(app);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      // 绕过 UI 直接写 DB，模拟「列表数据在背后变了」。
      await repo.insert(sneaky);

      await tapTab(tester, 'AI');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tapTab(tester, '服务器');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      // 没有重查 —— AI tab 不会改服务器记录，从那边回来重查是白查。
      expect(find.text('Sneaky Server'), findsNothing);

      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });
}
