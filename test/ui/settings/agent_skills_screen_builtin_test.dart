import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_skill_manager.dart';
import 'package:flyterm/ai/agent/builtin_skill_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ui/settings/agent_skills_screen.dart';

/// 内置技能分组：出现在列表里、带开关、没有删除按钮。
///
/// 正文来自真实 assets（`BuiltinSkillManager.load()` 不传 `bundle`），因为
/// 这条测试要盯住的是「真实两条内置技能出现在设置页」，而不是一份假数据 ——
/// 假数据由 `test/ai/agent/builtin_skill_manager_test.dart` 覆盖。
///
/// `testWidgets` 里直接 await sqflite / SharedPreferences 平台调用会挂死
/// 十分钟才报超时，而不是报错（这个项目已经踩过这个坑，见
/// `test/ui/settings/agent_skills_screen_test.dart` 顶部说明）。点击触发的
/// prefs 写入因此整个包进 `tester.runAsync`。
///
/// 默认 800×600 测试视口装不下 AppBar + 预算行 + Divider + 两条内置
/// ListTile，用 1080×2400 覆盖（keybar 编辑器测试的既有做法）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AgentSkillManager skills;
  late BuiltinSkillManager builtin;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    skills = AgentSkillManager(AgentSkillRepository(db));
    await skills.reload();
    builtin = BuiltinSkillManager(await SharedPreferences.getInstance());
    await builtin.load(); // 走真实 assets
  });

  tearDown(() async => db.close());

  void setSurfaceSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

  Future<void> pump(WidgetTester tester) async {
    setSurfaceSize(tester);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: skills),
        ChangeNotifierProvider.value(value: builtin),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AgentSkillsScreen(),
      ),
    ));
    await settle(tester);
  }

  testWidgets('内置技能出现在列表里，中文标题 + 英文 name 都在', (tester) async {
    await pump(tester);

    // 标题是中文 —— 英文 slug 认不出是干什么的。
    expect(find.text('排查故障'), findsOneWidget);
    expect(find.text('规划改动'), findsOneWidget);

    // 英文 name 也必须露出来：那是用户在输入框里打 `/` 时要输的那个串。
    // 用 textContaining 是因为它和「内置」徽标同在一行（`内置 · name`）。
    expect(find.textContaining('troubleshoot'), findsOneWidget);
    expect(find.textContaining('plan-change'), findsOneWidget);

    expect(find.textContaining('内置'), findsWidgets);
  });

  testWidgets('内置技能有开关，关掉后落盘', (tester) async {
    await pump(tester);

    final before = builtin.names.length;
    final sw = find.byType(Switch).first;
    await tester.runAsync(() async {
      await tester.tap(sw);
      // 轮询而不是固定 sleep：并发跑全量时负载会让固定 200ms 不够，写入落在
      // 测试结束之后 —— 只在全量时红、单独跑永远绿的那种偶发。
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (builtin.names.length >= before && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await settle(tester);

    // 不写死“关掉后剩 1 条”：内置技能会随版本增加（troubleshoot /
    // plan-change / skill-creator），写死个数的断言每加一条就红一次，
    // 而它想守的其实是「关掉一条 → 索引少一条」。
    expect(builtin.names, hasLength(before - 1),
        reason: '关掉一条之后就该少一条进索引');
  });

  testWidgets('内置技能没有删除按钮', (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  /// 手动新建撞内置名：`save_skill` 那条 AI 路径已经拦了，UI 路径必须等价。
  ///
  /// 不拦的后果不是覆盖，是**产出一条永远读不到的技能**：`load_skill` 走
  /// `resolveSkillBody`，内置优先，用户存的那份正文取不出来；而这条技能会
  /// 照常列在设置页上显示「已启用」，还会让 system prompt 里同一个名字出现
  /// 两条互相矛盾的描述。
  group('撞内置技能名', () {
    Future<void> openCreate(WidgetTester tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.add));
      await settle(tester);
      await tester.tap(find.text('手动新建'));
      await settle(tester);
    }

    IconButton saveButton(WidgetTester tester) => tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.check));

    Future<void> fill(WidgetTester tester, String name) async {
      await tester.enterText(find.byType(TextField).at(0), name);
      await tester.enterText(find.byType(TextField).at(1), '我的描述');
      await tester.enterText(find.byType(TextField).at(2), '正文内容');
      await settle(tester);
    }

    testWidgets('手动新建用内置技能的名字 → 提示且不能保存', (tester) async {
      await openCreate(tester);
      await fill(tester, 'plan-change');

      expect(find.textContaining('已经有一个叫'), findsOneWidget);
      expect(saveButton(tester).onPressed, isNull);
    });

    testWidgets('撞内置名的判定大小写不敏感', (tester) async {
      await openCreate(tester);
      await fill(tester, 'Plan-Change');
      expect(saveButton(tester).onPressed, isNull);
    });

    testWidgets('禁用内置之后名字仍然被占着', (tester) async {
      // 名字是保留的，禁用只是「不进索引」。放行的话：存一条同名的（此时
      // 读得到，因为内置被禁）→ 用户哪天重新启用内置 → 自己那条被永久遮住。
      await tester.runAsync(() => builtin.setEnabled('plan-change', false));

      await openCreate(tester);
      await fill(tester, 'plan-change');
      expect(saveButton(tester).onPressed, isNull);
    });

    testWidgets('不撞名时照常能保存 —— 别把整条路堵死了', (tester) async {
      await openCreate(tester);
      await fill(tester, 'my-nginx-notes');
      expect(saveButton(tester).onPressed, isNotNull);
    });
  });
}
