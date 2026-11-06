import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_skill_manager.dart';
import 'package:flyterm/ai/agent/builtin_skill_manager.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/agent_skills_screen.dart';
import 'package:flyterm/ui/settings/agent_skill_detail_screen.dart';

/// ## 为什么这个文件里所有碰数据库的调用都裹着 `tester.runAsync`
///
/// `testWidgets` 的回调跑在 flutter_test 的 **fake-async zone** 里：那里的
/// `Timer` 和 microtask 由 `FakeAsync` 接管，只有 `tester.pump()` 才推进。
/// 而 `sqflite_common_ffi` 的异步是靠真实的 timer/microtask 实现的 ——
/// 于是 `await mgr.save(...)` 的 Future 永远不会完成，整条测试挂死。
///
/// 症状极具迷惑性：不是断言失败，而是 `pumpAndSettle` 一直转，直到
/// flutter_test 默认的 10 分钟超时才报错。空库那条测试（不碰数据库）照常
/// 通过，所以第一眼会以为是渲染问题。
///
/// `tester.runAsync` 把回调切回真实 async zone，是 flutter_test 为这种情形
/// 提供的标准出口。
///
/// **点击触发的写入也必须整个放进 `runAsync`**（见下面 `_tapAndPersist`）：
/// `Switch.onChanged` 里的 `mgr.setEnabled(...)` 是 fire-and-forget，它的
/// Future 在 fake zone 里创建，`runAsync` 之后再补一个 delay 也推不动它 ——
/// 必须让 `tap` 本身就发生在真实 zone 里。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AgentSkillManager mgr;

  /// 设置页顶部有一段内置技能分组，要从 provider 里读。
  ///
  /// **刻意不 `load()`**：这个文件测的是用户技能那一段（列表、预算行、开关、
  /// 来源徽标），内置为空才能让那些断言只反映用户技能。内置分组自身的渲染与
  /// 开关由 `agent_skills_screen_builtin_test.dart` 单独钉住。
  late BuiltinSkillManager builtin;

  // setUp 不在 fake-async zone 里，所以这里可以直接 await 真实 IO。
  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    mgr = AgentSkillManager(AgentSkillRepository(db));
    await mgr.reload();
    SharedPreferences.setMockInitialValues({});
    builtin = BuiltinSkillManager(await SharedPreferences.getInstance());
  });

  tearDown(() async => db.close());

  /// 在真实 async zone 里往库里写测试数据。见文件顶部说明。
  Future<void> seed(WidgetTester tester, Future<void> Function() op) =>
      tester.runAsync(op);

  /// 点一个会触发数据库写入的控件，并等它真正落盘。
  ///
  /// `tap` 必须在 `runAsync` 内部：控件回调里那次 `mgr.xxx()` 是
  /// fire-and-forget，只有在真实 zone 里发起才有机会完成。之后的 `pump`
  /// 要放在 `runAsync` **外面**，让 widget 树用新状态重建。
  ///
  /// [until] 是「写入已经落地」的判据。传了就轮询到它成立（上限 5 秒），
  /// 没传则退回固定 200ms。
  ///
  /// **固定 sleep 在并发跑全量时会被负载推翻**：`flutter test` 同时跑多个
  /// 文件，200 ms 不够时保存在测试结束之后才落地，撞上 `tearDown` 关掉的库，
  /// 报 `DatabaseException(error database_closed)` —— 而且只在全量时红、
  /// 单独跑这个文件永远绿，是最难查的那种偶发。
  Future<void> tapAndPersist(
    WidgetTester tester,
    Finder finder, {
    bool Function()? until,
  }) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      if (until == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return;
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!until() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
  }

  /// 带超时的 settle。默认的 `pumpAndSettle()` 超时是 10 分钟 —— 一旦将来
  /// 又出现不收敛的情况，5 秒报错比等十分钟有用得多。
  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

  // 800x600 的默认测试视口装不下 AppBar + 预算行 + overflow 提示 + Divider +
  // 一条 ListTile，会把「找不到 widget」和「逻辑错了」混在一起。用
  // 1080x2400（真机常见尺寸）避免这个问题——keybar 编辑器的测试也是这么做的。
  void setSurfaceSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pump(WidgetTester tester) async {
    setSurfaceSize(tester);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: mgr),
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

  testWidgets('空库时显示空态说明', (tester) async {
    await pump(tester);
    expect(find.textContaining('还没有技能'), findsOneWidget);
  });

  testWidgets('列出技能的 name 与 description', (tester) async {
    await seed(
        tester,
        () => mgr.save(
            name: 'nginx',
            description: '排查 502',
            body: 'b',
            source: SkillSource.ai));
    await pump(tester);
    expect(find.text('nginx'), findsOneWidget);
    expect(find.text('排查 502'), findsOneWidget);
  });

  testWidgets('顶部显示条数与 token 预算', (tester) async {
    await seed(
        tester,
        () => mgr.save(
            name: 'a', description: 'd', body: 'b', source: SkillSource.ai));
    await pump(tester);
    expect(find.textContaining('token'), findsOneWidget);
  });

  testWidgets('开关能禁用一条', (tester) async {
    await seed(
        tester,
        () => mgr.save(
            name: 'a', description: 'd', body: 'b', source: SkillSource.ai));
    await pump(tester);
    await tapAndPersist(tester, find.byType(Switch).first,
        until: () => !mgr.skills.single.enabled);
    expect(mgr.skills.single.enabled, isFalse);
  });

  testWidgets('显示来源徽标', (tester) async {
    await seed(
        tester,
        () => mgr.save(
            name: 'a', description: 'd', body: 'b', source: SkillSource.ai));
    await pump(tester);
    expect(find.textContaining('助手'), findsWidgets);
  });

  testWidgets('手动创建的技能显示自己的来源徽标', (tester) async {
    await seed(
        tester,
        () => mgr.save(
            name: 'a',
            description: 'd',
            body: 'b',
            source: SkillSource.manual));
    await pump(tester);
    expect(find.textContaining('手动创建'), findsWidgets);
  });

  testWidgets('超出上限时显示警告', (tester) async {
    await seed(tester, () async {
      for (var i = 0; i <= kMaxIndexedSkills; i++) {
        await mgr.save(
            name: 's$i', description: 'd', body: 'b', source: SkillSource.ai);
      }
    });
    await pump(tester);
    // 文案改动（fix: 加了 search_skills 之后「超出上限」不再等于「模型看
    // 不到」）：现在写的是「超出索引上限」，断言跟着改成新文案里实际存在
    // 的子串。
    expect(find.textContaining('超出索引上限'), findsOneWidget);
  });

  testWidgets('没有远端导入回调时不显示那个菜单项', (tester) async {
    await pump(tester);
    await tester.tap(find.byIcon(Icons.add));
    await settle(tester);
    expect(find.textContaining('从这台服务器'), findsNothing);
    expect(find.textContaining('从文件'), findsOneWidget);
  });

  testWidgets('「+」菜单里有手动新建', (tester) async {
    await pump(tester);
    await tester.tap(find.byIcon(Icons.add));
    await settle(tester);
    expect(find.textContaining('手动新建'), findsOneWidget);
  });

  group('手动新建', () {
    /// 从列表页走「+」→「手动新建」进入新建页。
    ///
    /// 刻意走真实导航而不是直接 pump 新建页：这条路径本身就是被测行为的一
    /// 部分，而且新建页要靠列表页那层 Provider 拿到 AgentSkillManager。
    Future<void> openCreate(WidgetTester tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.add));
      await settle(tester);
      await tester.tap(find.text('手动新建'));
      await settle(tester);
    }

    testWidgets('进入新建页，有名称/描述/正文三个字段', (tester) async {
      await openCreate(tester);
      expect(find.text('新建技能'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));
    });

    Future<void> fill(
      WidgetTester tester, {
      String name = 'my-skill',
      String desc = '我的描述',
      String body = '正文内容',
    }) async {
      await tester.enterText(find.byType(TextField).at(0), name);
      await tester.enterText(find.byType(TextField).at(1), desc);
      await tester.enterText(find.byType(TextField).at(2), body);
      await settle(tester);
    }

    testWidgets('填完保存后落库，来源记为手动创建', (tester) async {
      await openCreate(tester);
      await fill(tester);
      await tapAndPersist(tester, find.byIcon(Icons.check),
          until: () => mgr.skills.isNotEmpty);

      expect(mgr.skills, hasLength(1));
      final s = mgr.skills.single;
      expect(s.name, 'my-skill');
      expect(s.description, '我的描述');
      expect(s.body, '正文内容');
      expect(s.source, SkillSource.manual);
    });

    IconButton saveButton(WidgetTester tester) => tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.check));

    testWidgets('名称为空时不能保存', (tester) async {
      await openCreate(tester);
      await fill(tester, name: '   ');
      expect(saveButton(tester).onPressed, isNull);
    });

    // 空 description 不是小瑕疵：索引段每轮都进 system prompt，一条没有描述
    // 的技能等于每次请求都花钱买一行废话，而且模型也没法判断该不该取用它。
    testWidgets('描述为空时不能保存', (tester) async {
      await openCreate(tester);
      await fill(tester, desc: '   ');
      expect(saveButton(tester).onPressed, isNull);
    });

    /// 撞名必须拦住，因为 `AgentSkillRepository.upsert` 是「按 name
    /// COLLATE NOCASE 命中即更新」—— 不拦就是**静默覆盖**掉用户已有的那条，
    /// 而且没有撤销手段。AI 的 save_skill 撞名时会显示「更新已有技能」+ diff
    /// 让用户确认，手动新建这条路必须有等价的保护。
    testWidgets('名称撞已有技能时给出提示且不能保存', (tester) async {
      await seed(
          tester,
          () => mgr.save(
              name: 'nginx',
              description: '排查 502',
              body: '原有正文',
              source: SkillSource.ai));
      await openCreate(tester);
      await fill(tester, name: 'nginx');

      expect(find.textContaining('已经有一个叫'), findsOneWidget);
      expect(saveButton(tester).onPressed, isNull);
      expect(mgr.skills.single.body, '原有正文', reason: '原有技能不能被动过');
    });

    testWidgets('撞名判定大小写不敏感', (tester) async {
      await seed(
          tester,
          () => mgr.save(
              name: 'nginx',
              description: 'd',
              body: 'b',
              source: SkillSource.ai));
      await openCreate(tester);
      await fill(tester, name: 'NGINX');

      expect(saveButton(tester).onPressed, isNull,
          reason: 'upsert 的判据是 COLLATE NOCASE，大小写不同照样命中同一行；'
              'UI 这层若按大小写敏感放行，到仓库那层就变成静默覆盖');
    });
  });

  group('AgentSkillDetailScreen', () {
    Future<void> pumpDetail(WidgetTester tester, AgentSkill skill) async {
      setSurfaceSize(tester);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: mgr,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AgentSkillDetailScreen(skill: skill),
        ),
      ));
      await settle(tester);
    }

    Future<AgentSkill> seedOne(WidgetTester tester) async {
      await seed(
          tester,
          () => mgr.save(
              name: 'nginx',
              description: '排查 502',
              body: 'b',
              source: SkillSource.ai));
      return mgr.skills.single;
    }

    testWidgets('改 description 后保存能落库', (tester) async {
      final skill = await seedOne(tester);
      await pumpDetail(tester, skill);

      await tester.enterText(find.byType(TextField).first, '新的描述');
      await settle(tester);
      await tapAndPersist(tester, find.byIcon(Icons.check),
          until: () => mgr.skills.single.description == '新的描述');

      expect(mgr.skills.single.description, '新的描述');
    });

    testWidgets('description 超 200 字节时保存按钮禁用', (tester) async {
      final skill = await seedOne(tester);
      await pumpDetail(tester, skill);

      await tester.enterText(find.byType(TextField).first, 'x' * 201);
      await settle(tester);

      final checkButton = tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.check));
      expect(checkButton.onPressed, isNull);
      // 落库不应该发生：description 还是原来的那句。
      expect(mgr.skills.single.description, '排查 502');
    });

    // 这条只验证「确认框确实拦在删除前面」，**不验证确认之后是否落库**。
    //
    // 那半件事在这一层测不了：`_delete` 里 `await showDialog<bool>(...)` 的
    // Future 在 fake-async zone 里 resolve，它之后那句
    // `await mgr.delete(...)` 因此也在 fake zone 里发起 —— 而
    // `tester.runAsync` 推不动一个已经排进 FakeAsync 队列的 continuation
    // （见文件顶部说明）。硬要测就得往生产代码里塞测试钩子。
    //
    // 而且不值得：「delete 真的落库」已经由
    // `test/ai/agent/agent_skill_manager_test.dart` 的「删除之后索引同步
    // 移除」覆盖。在 widget 层重测一遍换不到新的保障，只会把 fake-async
    // 的复杂度引进来。这里守的是**这一层独有**的那个不变量：不点确认，
    // 技能不会消失。
    testWidgets('删除要先过确认对话框，取消则技能还在', (tester) async {
      final skill = await seedOne(tester);
      await pumpDetail(tester, skill);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await settle(tester);
      expect(find.textContaining('不可撤销'), findsOneWidget,
          reason: '删除必须先弹确认框');

      // 取消按钮用的是 MaterialLocalizations 的标准文案（zh 下是「取消」），
      // 不是我们自己的 l10n key。
      await tester.tap(find.text('取消'));
      await settle(tester);

      expect(find.textContaining('不可撤销'), findsNothing, reason: '对话框该关掉');
      expect(mgr.skills, hasLength(1), reason: '取消之后技能不该被删');
    });
  });
}
