// 复现：真实面板里（DraggableScrollableSheet 包着 AgentView）自动滚动不生效。
//
// 与 agent_view_autoscroll_test.dart 的区别：那边直接塞一个裸的
// `ScrollController`，而真实场景里 controller 是 `DraggableScrollableSheet`
// 的 builder 交下来的 —— 它是个 `_DraggableScrollableSheetScrollController`，
// 位置对象 override 了 `goBallistic`，会把「滚内容」重定向成「改 sheet 尺寸」。
// 裸 controller 的测试因此测不出真实行为。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_events.dart';
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

void _seedText(AgentLoop loop, int n) {
  for (var i = 0; i < n; i++) {
    loop.debugAddEvent(UserTurnEvent('问题 $i：${'很长的一行'.padRight(40, 'x')}'));
    loop.debugAddEvent(AssistantTextEvent('回答 $i：${'很长的一行'.padRight(40, 'y')}'));
  }
}

/// 真实面板的形状：DraggableScrollableSheet 把它的 controller 交给 AgentView。
Widget _sheet(AgentLoop loop, {ScrollController? external}) {
  return DraggableScrollableSheet(
    expand: false,
    controller: external == null ? null : SheetController(external),
    initialChildSize: 0.5,
    minChildSize: 0.3,
    maxChildSize: 0.95,
    builder: (_, scrollController) {
      return AgentView(
        loop: loop,
        providerName: 'fake',
        scrollController: scrollController,
      );
    },
  );
}

/// 最小可用的 DraggableScrollableSheet 外部 controller，只为观察 sheet 尺寸。
class SheetController extends DraggableScrollableController {
  final ScrollController inner;
  SheetController(this.inner);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真实 sheet 里：内容超出后自动滚到底部', (tester) async {
    final loop = makeLoop(provider: FakeProvider([]));

    await tester.pumpWidget(_wrap(_sheet(loop)));
    await tester.pump();

    _seedText(loop, 60);
    loop.debugNotify();
    await tester.pumpAndSettle();

    // 拿到 sheet 交给 AgentView 的那个 controller。
    final listView = tester.widget<ListView>(find.byType(ListView));
    final sc = listView.controller!;
    expect(sc.hasClients, isTrue);
    expect(sc.position.maxScrollExtent, greaterThan(0),
        reason: '内容必须真的超出视口');

    // 关键断言：真的停在底部。
    expect(
      sc.position.pixels,
      closeTo(sc.position.maxScrollExtent, 1.0),
      reason: 'DraggableScrollableSheet 的 controller 下也应该滚到底',
    );
  });

  testWidgets('真实 sheet 里：流式持续增长时也跟到底部', (tester) async {
    final loop = makeLoop(provider: FakeProvider([]));

    await tester.pumpWidget(_wrap(_sheet(loop)));
    await tester.pump();

    _seedText(loop, 60);
    loop.debugNotify();
    await tester.pumpAndSettle();

    final listView = tester.widget<ListView>(find.byType(ListView));
    final sc = listView.controller!;

    // 模拟流式：每 16ms 加一段文本，远快于 200ms 动画。
    for (var i = 0; i < 20; i++) {
      loop.debugSetStreamingText('流式内容 $i ${'z' * 120}');
      loop.debugNotify();
      await tester.pump(const Duration(milliseconds: 16));
    }
    loop.debugSetStreamingText(null);
    loop.debugNotify();
    await tester.pumpAndSettle();

    expect(
      sc.position.pixels,
      closeTo(sc.position.maxScrollExtent, 1.0),
      reason: '流式过程中反复触发也必须最终停在底部',
    );
  });

  testWidgets('用户上滑看历史后，执行中会跟回底部吗', (tester) async {
    final loop = makeLoop(provider: FakeProvider([]));

    await tester.pumpWidget(_wrap(_sheet(loop)));
    await tester.pump();

    _seedText(loop, 60);
    loop.debugNotify();
    await tester.pumpAndSettle();

    final listView = tester.widget<ListView>(find.byType(ListView));
    final sc = listView.controller!;
    expect(sc.position.pixels, closeTo(sc.position.maxScrollExtent, 1.0));

    // 用户上滑到历史。
    sc.jumpTo(sc.position.maxScrollExtent - 500);
    await tester.pump();
    final scrolledUp = sc.position.pixels;
    expect(scrolledUp, lessThan(sc.position.maxScrollExtent - 100));

    // AI 继续执行（新内容 + 通知）—— 应当自动跟回底部。
    loop.debugSetStreamingText('新的输出 ${'z' * 200}');
    loop.debugNotify();
    await tester.pumpAndSettle();

    expect(
      sc.position.pixels,
      closeTo(sc.position.maxScrollExtent, 1.0),
      reason: '用户上滑后，执行中的新内容应当把他带回最新一行',
    );
  });
}
