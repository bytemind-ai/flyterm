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

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // 用 `databaseFactoryFfiNoIsolate` 而不是仓库里更常见的
    // `databaseFactoryFfi`：后者在「非空查询结果 + `tester.runAsync` +
    // populated 的 widget 子树」这个组合下会在 test body 跑完之后、
    // `tearDown` 之前卡死（不是断言失败，是进程挂起到默认 10 分钟超时）。
    // 用 `find.byType(HomeScreen)` 之类的裸 `HomeScreen`（完全不经过
    // `AppShell`）复现过同样的卡死，确认是 `sqflite_common_ffi` 后台 isolate
    // 通信与 flutter_test binding 收尾逻辑的既有交互问题，与本文件测的
    // `AppShell` 逻辑无关。`databaseFactoryFfiNoIsolate` 去掉了那层后台
    // isolate，同样的用例立刻转绿。
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

  Widget app({Widget? settingsPage}) => MultiProvider(
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
            settingsPage: settingsPage ??
                const Scaffold(body: Center(child: Text('FAKE-SETTINGS'))),
          ),
        ),
      );

  /// HomeScreen 的列表走 FutureBuilder + 真实 ffi DB，fake-async 的 pump()
  /// 排不干这些 future。必须 runAsync 包住并用真实延时推进。
  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  }

  /// 点底部导航的某个 tab。
  ///
  /// **必须把 finder 限定在 ShellNavBar 里**：`IndexedStack` 用
  /// `Visibility.maintain` 把三页全都留在 widget 树中（只是不绘制），其他
  /// 页面的文字可能和导航栏标签撞名（例如 `GlobalAIScreen` 的 AppBar 标题
  /// 变化过几次）。裸的 `find.text(label)` 可能同时命中别处，`tap` 直接报
  /// "Found 2 widgets"。限定在 ShellNavBar 里就不必关心其他页写了什么。
  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(ShellNavBar),
      matching: find.text(label),
    ));
  }

  /// 当前选中的 tab index。
  ///
  /// 同样因为三页全在树里，**不能**用 `find.byType(HomeScreen)` 之类判断
  /// 「现在在哪个 tab」—— 那种断言恒为真，测试会假通过。唯一可靠的信号是
  /// ShellNavBar 自己的 selectedIndex。
  int selectedTab(WidgetTester tester) =>
      tester.widget<ShellNavBar>(find.byType(ShellNavBar)).selectedIndex;

  testWidgets('三个 destination 都渲染，默认停在服务器 tab', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(app());
      await settle(tester);

      final bar = find.byType(ShellNavBar);
      expect(find.descendant(of: bar, matching: find.text('AI')),
          findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('服务器')),
          findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('设置')),
          findsOneWidget);
      expect(selectedTab(tester), kServersTab);

      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });

  testWidgets('切 tab 保状态：搜索词切走再切回还在', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await repo.insert(Server(
      id: const Uuid().v4(),
      name: 'alpha',
      host: 'alpha.example.com',
      port: 22,
      username: 'root',
      authType: 'password',
    ));

    await tester.runAsync(() async {
      await tester.pumpWidget(app());
      await settle(tester);

      await tester.enterText(find.byType(TextField).first, 'alph');
      await tester.pump();

      await tapTab(tester, 'AI');
      await settle(tester);
      await tapTab(tester, '服务器');
      await settle(tester);

      expect(selectedTab(tester), kServersTab);
      // 搜索词还在 = HomeScreen 的 State 没被重建。若 AppShell 换成条件
      // 渲染（而不是 IndexedStack），这里的 State 会被 dispose、文本丢失。
      expect(find.text('alph'), findsOneWidget);

      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });

  testWidgets('返回键：AI tab 切回服务器 tab 而不是退出', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(app());
      await settle(tester);

      await tapTab(tester, 'AI');
      await settle(tester);
      expect(selectedTab(tester), kAiTab);

      // 模拟系统返回键。handlePopRoute 返回 true = 这一下被应用消费掉了
      // （没有退出 App）。
      final consumed = await tester.binding.handlePopRoute();
      await tester.pump();

      expect(consumed, isTrue);
      expect(selectedTab(tester), kServersTab);

      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
  });
}
