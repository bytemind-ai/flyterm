// PanelHeader 的两组行为：
//
// 1. bypass 警告标记 —— 见 lib/ui/ai/widgets/panel_chrome.dart 顶部注释：bypass
//    是「开了就忘」的设置，真正该提醒用户的时机是他正看着 agent 干活的这个
//    面板，不能只藏在三级设置页里。
// 2. 右侧动作按钮 —— 「清空对话」的语义已经变成「归档当前段 + 开一段新的」，
//    图标必须跟着变：垃圾桶让用户以为点了就没了，于是不敢点，而它恰恰是新
//    流程里最常用的动作。历史入口只在有会话归档的模式（agent）下出现，且
//    2026-10 从「更多」菜单挪回了头部裸图标。导出则彻底移出头部，只保留在
//    历史列表每一行里。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/panel_chrome.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool bypassActive = false,
  VoidCallback? onHistory,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: PanelHeader(
          onClear: () {},
          bypassActive: bypassActive,
          onHistory: onHistory,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final l = lookupAppLocalizations(const Locale('zh'));

  testWidgets('bypassActive: false 时不显示警告图标', (tester) async {
    await _pump(tester, bypassActive: false);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('bypassActive: true 时显示警告图标 + 对应 tooltip', (tester) async {
    await _pump(tester, bypassActive: true);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    // 每个 IconButton 各自也有 tooltip（内部同样是 Tooltip 包裹），不能直接
    // byType(Tooltip) 期望唯一——按 message 精确定位这一个。
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == l.agentPanelBypassActiveTooltip,
      ),
      findsOneWidget,
    );
  });

  testWidgets('头部不再有垃圾桶图标 —— 它的语义已经是归档而非删除', (tester) async {
    await _pump(tester);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byIcon(Icons.add_comment_outlined), findsOneWidget);
  });

  testWidgets('新建会话按钮的 tooltip 是「新建会话」而非「清空对话」', (tester) async {
    await _pump(tester);
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == l.aiNewSession,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == l.aiClearHistory,
      ),
      findsNothing,
    );
  });

  testWidgets('有历史入口时，头部直接显示历史图标并可点 —— 不再收进更多菜单', (tester) async {
    var opened = false;
    await _pump(tester, onHistory: () => opened = true);

    // 历史是会话管理里最高频的导航动作（看一眼、切回去），2026-10 的 IA
    // 改动把它从「更多」里挪回头部裸图标：收进菜单后每次都要两次点击，
    // 而 agent 模式下菜单里本来也只剩它一项 —— 一个只有一项的菜单不如
    // 直接把那项放出来。
    expect(find.byIcon(Icons.history), findsOneWidget);
    // agent 模式（showPresets 默认 true 但没有预设回调）头部不需要「更多」。
    expect(find.byIcon(Icons.more_vert), findsNothing);

    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });

  testWidgets('onHistory 为 null 时头部没有历史图标 —— 直连模式没有会话归档', (tester) async {
    await _pump(tester);
    expect(find.byIcon(Icons.history), findsNothing);
  });

  testWidgets('头部没有导出入口 —— 导出只能从历史列表每行走', (tester) async {
    // 用户反馈：导出是低频动作，不值得占标题栏一个格子。历史列表里每一行
    // 都有自己的导出菜单，入口没有丢。
    await _pump(tester, onHistory: () {});
    expect(find.byIcon(Icons.ios_share), findsNothing);
  });

  testWidgets('打开历史列表后，头部变脸：左侧 arrow_back + 标题「历史会话」', (tester) async {
    var toggled = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PanelHeader(
            onClear: () {},
            onHistory: () => toggled++,
            historyOpen: true,
            showPresets: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 返回键是整页动作，摆头部最左——不再是右下角那个与「新建会话」并排的
    // history 开关。
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
    // 列表已经打开，那个 history 开关不该再渲染（两个入口干同一件事只会
    // 让人猜它们有什么区别）。
    expect(find.byIcon(Icons.history), findsNothing);
    // 标题换成「历史会话」，告诉用户现在在哪。
    expect(find.text(l.aiSessionHistory), findsWidgets);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(toggled, 1, reason: '返回键点下去应触发同一个 onHistory（再点一次退出）');
  });

  testWidgets('未打开历史列表时，头部是常规的 auto_awesome + 助手标题', (tester) async {
    await _pump(tester, onHistory: () {});

    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(find.text(l.aiAssistant), findsOneWidget);
  });

  // 头部一行要同时放下：标题区（两行，第二行是模型名）+ 三个图标。模型名来自
  // `AIProvider.displayName`，它的真实形状是 `Anthropic (claude-sonnet-4-5-
  // 20250929)` 这种四十来个字符的串 —— 标题区若不受宽度约束，就会把右侧图标
  // 挤出可视区，而最右边那个恰好是新建会话（用户报的「新会话按钮没有了」）。
  //
  // 360×640 是常见的窄屏机型下限，用它当护栏。
  testWidgets('长模型名不得把新建会话按钮挤出头部', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PanelHeader(
            onClear: () {},
            onHistory: () {},
            onSwitchModel: () {},
            modelLabel: 'Anthropic (claude-sonnet-4-5-20250929)',
            showPresets: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '头部不该溢出 —— 溢出的部分会被静默裁掉');

    // agent 模式常驻的只剩两个：历史 + 新建会话。它们都要真的落在屏幕内
    // （溢出时 widget 仍在树上，只是画在可视区之外，所以光 findsOneWidget
    // 守不住这件事）。
    for (final icon in [Icons.history, Icons.add_comment_outlined]) {
      expect(find.byIcon(icon), findsOneWidget);
      final box = tester.getRect(find.byIcon(icon));
      expect(box.right, lessThanOrEqualTo(360.0), reason: '$icon 被挤出了屏幕右边界');
    }
  });

  // 直连模式的菜单里多了「分析错误」「会话总结」，但头部常驻图标数与
  // agent 模式相同（菜单 + 新建）—— 宽度压力一样，同样要守。
  testWidgets('直连模式下长模型名同样不挤掉新建会话', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PanelHeader(
            onClear: () {},
            onAnalyzeError: () {},
            onSummary: () {},
            onSwitchModel: () {},
            modelLabel: 'OpenAI (gpt-5-turbo-2026-08-preview)',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final box = tester.getRect(find.byIcon(Icons.add_comment_outlined));
    expect(box.right, lessThanOrEqualTo(360.0));
  });
}
