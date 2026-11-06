// AI 面板的**自动滚动**行为。
//
// ## 问题
//
// agent 执行中（尤其是流式输出）面板不自动跟到最新内容。用户得手动往下拖。
//
// ## 现有实现的形状（`agent_view.dart` `_onLoopChanged`）
//
// 每次 loop 通知（流式 token 也会触发，每个 chunk 一次）都做：
//
// ```dart
// WidgetsBinding.instance.addPostFrameCallback((_) {
//   final sc = widget.scrollController;
//   if (sc == null || !sc.hasClients) return;
//   final pos = sc.position;
//   if (pos.maxScrollExtent <= 0) return;
//   sc.animateTo(pos.maxScrollExtent, duration: 200ms, curve: easeOut);
// });
// ```
//
// 这里要锁的是**它真的滚到了底部**，而不是「调了 animateTo」。后者在流式
// 场景下特别容易假绿：每个 chunk 重启一次动画，看起来一直在动，实际永远
// 追不上内容增长。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_events.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/agent_view.dart';

import '../../ai/agent/_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

/// 造一堆纯文本事件，把列表撑到需要滚动。
void _seedText(AgentLoop loop, int n) {
  for (var i = 0; i < n; i++) {
    loop.debugAddEvent(
      UserTurnEvent('问题 $i：${'很长的一行'.padRight(40, 'x')}'),
    );
    loop.debugAddEvent(
      AssistantTextEvent('回答 $i：${'很长的一行'.padRight(40, 'y')}'),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('内容超出视口后，post-frame 滚动把列表带到底部', (tester) async {
    final loop = makeLoop(provider: FakeProvider([]));
    final sc = ScrollController();
    addTearDown(sc.dispose);

    await tester.pumpWidget(_wrap(
      AgentView(loop: loop, providerName: 'fake', scrollController: sc),
    ));
    await tester.pump();

    // 撑到远超视口。
    _seedText(loop, 60);
    loop.debugNotify();
    await tester.pumpAndSettle();

    expect(sc.hasClients, isTrue, reason: 'ListView 应该已经挂上了');
    expect(sc.position.maxScrollExtent, greaterThan(0),
        reason: '内容必须真的超出视口，否则这条测试什么都没验证到');

    // 自动滚动后应该停在底部（允许 1px 的取整误差）。
    expect(
      sc.position.pixels,
      closeTo(sc.position.maxScrollExtent, 1.0),
      reason: '列表应该自动滚到最新内容',
    );
  });

  testWidgets('连续流式更新（每个 chunk 一次通知）最终仍停在底部', (tester) async {
    // 这条专门盯「animateTo 被反复重启」这个失败形态：200ms 的动画还没走完
    // 就被下一个 chunk 重启，pixels 会一直在半路，永远到不了底部。
    final loop = makeLoop(provider: FakeProvider([]));
    final sc = ScrollController();
    addTearDown(sc.dispose);

    await tester.pumpWidget(_wrap(
      AgentView(loop: loop, providerName: 'fake', scrollController: sc),
    ));
    await tester.pump();

    _seedText(loop, 60);
    loop.debugNotify();
    await tester.pumpAndSettle();

    final target = sc.position.maxScrollExtent;

    // 模拟流式：每加一点内容就通知一次，间隔远小于动画时长。
    for (var i = 0; i < 10; i++) {
      loop.debugSetStreamingText('流式内容 $i ${'z' * 80}');
      loop.debugNotify();
      await tester.pump(const Duration(milliseconds: 16));
    }
    loop.debugSetStreamingText(null);
    loop.debugNotify();

    // 让动画和布局都稳定下来。
    await tester.pumpAndSettle();

    expect(
      sc.position.pixels,
      closeTo(sc.position.maxScrollExtent, 1.0),
      reason: '流式过程中反复触发也必须最终停在底部',
    );
    expect(sc.position.maxScrollExtent, greaterThanOrEqualTo(target));
  });
}
