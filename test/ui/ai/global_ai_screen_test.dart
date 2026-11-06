import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/direct_chat_view.dart';
import 'package:flyterm/ui/ai/global_ai_screen.dart';
import 'package:flyterm/ui/ai/widgets/panel_chrome.dart';

/// provider 装配照抄 `test/ui/ai/ai_panel_test.dart` 的既有写法：
/// `AIProviderService` 要 prefs（不是无参构造），`VoiceInputService()` 无参，
/// `locale` 锁 zh 让文案断言不受环境 locale 影响。
Widget _app(SharedPreferences prefs) => MultiProvider(
      providers: [
        Provider<SharedPreferences>.value(value: prefs),
        ChangeNotifierProvider<AIProviderService>.value(
          value: AIProviderService(prefs),
        ),
        ChangeNotifierProvider<VoiceInputService>.value(
          value: VoiceInputService(),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GlobalAIScreen(),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('历史为空时显示空状态与三个建议 chip', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_app(prefs));
    await tester.pump();

    // 不再断言 `find.byType(DirectChatView), findsNothing`——方案 B 改造后
    // `DirectChatView` 始终存在（输入框常驻在底部，空状态只是它内部消息
    // 列表区域为空时的占位内容）。这条用例真正要验证的是"现在是空状态"，
    // 改成直接验证占位内容本身：文案 + 三个建议 chip 都在。
    expect(find.text('有什么可以帮你？'), findsOneWidget);
    expect(find.byType(ActionChip), findsNWidgets(3));
  });

  testWidgets('点建议 chip 会真的走到 DirectChatView 的提交路径', (tester) async {
    // 方案 B 之前这条用例测的是"整页替换"：点 chip 让 `_started` 翻转，
    // `DirectChatView` 作为一个新 widget 出现、靠 `initialQuery` 在
    // `initState` 里自动提交一次——所以旧断言是"切到了 DirectChatView"+
    // "空状态文案消失"。`_started` 这个标志位已经不存在了：`DirectChatView`
    // 从一开始就常驻在树里（输入框常驻在底部），点 chip 变成了"占位内容里的
    // `send` 回调把文字塞进 `_ctrl`、调用同一个 `submit()`"——与用户手打后点
    // 发送完全同一条路径，不再有"切换"这个概念。
    //
    // 这个测试环境（`_app`）没有配置 AI provider，`submit()` 的第一行就会
    // 判断 `!svc.hasProvider` 并提前返回、把 `_errorMsg` 设成
    // `context.l10n.aiNoProvider` 展示出来——这正是真实用户"点了建议但还没
    // 配置 AI"时会看到的反馈。用它来验证 chip 点击确实触达了 submit()，而不是
    // 什么都没发生：如果 `emptyBuilder` 的 `send` 回调没有接对 `submit`，这里
    // 不会出现任何提示文字。
    //
    // 既然没有 provider，`submit()` 从未把消息写进 `engine.history`，所以
    // 列表仍然为空、占位文案（含三个建议 chip）仍然可见——这与"清空历史后
    // 回到空状态"那条用例是一致的：空状态只应该在真的有消息被记录时消失。
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_app(prefs));
    await tester.pump();

    await tester.tap(find.text('解释这段报错'));
    await tester.pump();

    expect(find.byType(DirectChatView), findsOneWidget);
    expect(
      find.text('未配置 AI 服务商，请前往 设置 → AI 服务商 添加。'),
      findsOneWidget,
    );
    expect(find.text('有什么可以帮你？'), findsOneWidget);
  });

  testWidgets('已有历史时直接渲染 DirectChatView、不出空状态', (tester) async {
    SharedPreferences.setMockInitialValues({
      'ai_chat_history_${AIEngine.kGlobalServerId}':
          '[{"role":"user","content":"hi"}]',
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_app(prefs));
    await tester.pump();

    expect(find.byType(DirectChatView), findsOneWidget);
    expect(find.text('有什么可以帮你？'), findsNothing);
  });

  testWidgets('清空历史后回到空状态', (tester) async {
    SharedPreferences.setMockInitialValues({
      'ai_chat_history_${AIEngine.kGlobalServerId}':
          '[{"role":"user","content":"hi"}]',
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_app(prefs));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();

    // 同上一条用例：`DirectChatView` 始终存在，不再断言 findsNothing。
    // 验证占位内容本身（文案 + chip 数量）才是这条用例的真实意图——
    // 「清空之后又回到了空状态」。
    expect(find.text('有什么可以帮你？'), findsOneWidget);
    expect(find.byType(ActionChip), findsNWidgets(3));
  });

  testWidgets('空状态下输入框可见（方案 B 的核心验收点）', (tester) async {
    // 这是本次改造的全部意义：旧结构下空状态整页替换掉了输入框，用户想问
    // 自己的问题，只能先点一个他不想发的建议 chip。改造后输入框应当在
    // 空状态下就已经可见，与消息列表的空/非空无关。
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_app(prefs));
    await tester.pump();

    expect(find.text('有什么可以帮你？'), findsOneWidget);
    expect(find.byType(PanelInputRow), findsOneWidget);
  });

  testWidgets(
      'direct 模式下点清空真的调用 _engine.clearHistory（持久化的历史被删除，'
      '而不只是 UI 状态被翻转）', (tester) async {
    // 这条测试是 bug 修复的回归锚点：`_clear()` 曾经只在 agent 分支下被改动，
    // 如果哪天不小心把 direct 分支也改成走别的路径（比如误判进了 agent 分支
    // 却没有归档，或者干脆漏调 `clearHistory`），下面这个 widget 测试本身
    // （见上一条用例「清空历史后回到空状态」）只看 UI 是否回到空状态——那正是
    // report 里描述的 bug 本体会制造的假象：UI 看起来清空了，底层数据其实
    // 还在。这里额外断言 SharedPreferences 里的持久化 key 被真正移除，才是
    // 在验证数据层，而不仅仅是 UI 状态。
    const key = 'ai_chat_history_${AIEngine.kGlobalServerId}';
    SharedPreferences.setMockInitialValues({
      key: '[{"role":"user","content":"hi"}]',
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_app(prefs));
    await tester.pump();

    expect(prefs.getString(key), isNotNull);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();

    expect(prefs.getString(key), isNull);
  });
}
