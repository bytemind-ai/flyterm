// 运行条的渲染测试。文案分支已由 running_bar_label_test 锁死，这里只验证
// 三件 widget 层的事：接对了纯函数、秒数会自己走、非运行态不渲染。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/agent_view.dart';

import '../../ai/agent/_fakes.dart';

Widget _wrap(AgentLoop loop) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider(
        create: (_) => VoiceInputService(),
        child: Scaffold(body: AgentView(loop: loop, providerName: 'fake')),
      ),
    );

void main() {
  testWidgets('thinking 状态显示带秒数的文案', (t) async {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);
    loop.debugForceRunning();

    await t.pumpWidget(_wrap(loop));

    // 断言的是**格式**而不是「0s」这个具体读数。
    //
    // elapsed 读的是真实挂钟（`DateTime.now()`），而 `pumpWidget` 要把
    // AgentView 这棵树整个建出来 —— 机器一忙，这一步本身就能花掉 1.5~2.5
    // 秒，于是「刚开始就断言 0s」会稳定地在高负载下失败。这不是被测代码
    // 的问题，是拿墙钟去卡一个包含冷启动的窗口。
    //
    // 这条用例真正要证明的是「thinking 走的是带秒数的新分支」——旧文案
    // 「思考中…」不匹配这个正则，够用了。秒数走得对不对由下一条用例
    // （真等 2 秒再断言 2s）负责。
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && RegExp(r'^思考中 \d+s$').hasMatch(w.data ?? ''),
      ),
      findsOneWidget,
    );
  });

  testWidgets('秒数随时间前进', (t) async {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);
    loop.debugForceRunning();

    await t.pumpWidget(_wrap(loop));

    // `runningBarLabel` 的 elapsed 读的是 `DateTime.now().difference(...)`
    // ——两头都是真实挂钟时间，不受 `tester.pump(duration)` 那条虚拟时钟
    // 摆布（虚拟时钟只会让应用里挂的 Timer 空转，`DateTime.now()` 本身
    // 纹丝不动）。同款场景 `agent_streaming_view_test.dart` 里的
    // 「运行中的工具卡显示已运行秒数」已经踩过并写明这个坑：先用
    // `runAsync` 跳出虚拟时钟、真等 2 秒挂钟时间，`DateTime.now()` 才会
    // 真的往前走。
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    // 光真等待还不够：刷新这段文字靠的是 `_tick` 那个挂在虚拟时钟上的
    // `Timer.periodic(1s)`（见 agent_view.dart 的 `_syncTick`），只有显式
    // `pump(duration)` 才会把它喂响、触发 rebuild，把已经真实前进过的
    // `DateTime.now()` 读数画出来。
    await t.pump(const Duration(seconds: 2));

    expect(find.text('思考中 2s'), findsOneWidget);

    // 不能让 Timer 活着走出测试：AgentView 在 dispose 时会 cancel，这里
    // 靠 pumpWidget(空) 触发它。少了这行会报 "A Timer is still pending"。
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('idle 状态不渲染运行条', (t) async {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    await t.pumpWidget(_wrap(loop));

    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
  });

  group('用量并入运行条', () {
    testWidgets('运行中：用量与运行条在同一行 —— 不各占一行', (t) async {
      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(
            text: '答', usage: TokenUsage(inputTokens: 800, outputTokens: 30)),
      ]));
      addTearDown(loop.dispose);
      await _seedUsage(loop);
      // 让 loop 回到运行态，模拟「又开了一轮，同时上一轮的用量还在」。
      loop.debugForceRunning();

      await t.pumpWidget(_wrap(loop));
      await t.pump();

      // 运行条在（有停止按钮）
      expect(find.text('停止'), findsOneWidget);
      // 用量也在，且与运行条同属一个 Row
      expect(find.textContaining('800'), findsOneWidget);

      // 关键断言：两者在**同一个 Row** 里。
      //
      // 取 `ancestor(...).last` 而不是 first：`usageFooterLabel` 自己内部也是
      // 一个 Row（导出图标 + 文字），first 会命中那个最内层的，它当然不含
      // 「停止」。最外层那个共同祖先才是运行条那一行。
      final stopRow = find
          .ancestor(of: find.text('停止'), matching: find.byType(Row))
          .last;
      expect(
        find.descendant(of: stopRow, matching: find.textContaining('800')),
        findsOneWidget,
        reason: '用量应在运行条那一行里 —— 两条独立行会在面板最小的高度下太挤',
      );

      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('不运行：用量自己占一行（运行条不在）', (t) async {
      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(
            text: '答', usage: TokenUsage(inputTokens: 800, outputTokens: 30)),
      ]));
      addTearDown(loop.dispose);
      await _seedUsage(loop);

      await t.pumpWidget(_wrap(loop));
      await t.pump();

      expect(find.text('停止'), findsNothing, reason: '已收工，不该有运行条');
      expect(find.textContaining('800'), findsOneWidget,
          reason: '用量仍要显示 —— 收工后正是看统计的时候');
    });

    testWidgets('窄屏 + 长用量：运行文案不被挤掉，也不横向溢出', (t) async {
      // 复现场景：360dp 宽的机器 + 一段带缓存的完整用量文案。
      // 修复前这一行会 `RenderFlex overflowed`，而且运行文案（用
      // `Flexible` 的那个）被不可压缩的用量挤到宽度归零、整段消失 ——
      // 用户只剩一个停止按钮，看不出 agent 卡在哪一阶段。
      t.view.physicalSize = const Size(360, 720);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(
          text: '答',
          usage: TokenUsage(
              inputTokens: 12345, cachedTokens: 9876, outputTokens: 4567),
        ),
      ]));
      addTearDown(loop.dispose);
      await _seedUsage(loop);
      loop.debugForceRunning();

      await t.pumpWidget(_wrap(loop));
      await t.pump();

      expect(t.takeException(), isNull,
          reason: '窄屏下这一行不该横向溢出');
      // `debugForceRunning()` 把状态置为 thinking → 文案是「思考中 Ns」。
      // 断言的是「那一行还在」而不是具体秒数（秒数走的是真实挂钟）。
      expect(
        find.byWidgetPredicate(
            (w) => w is Text && RegExp(r'^思考中 \d+s$').hasMatch(w.data ?? '')),
        findsOneWidget,
        reason: '运行文案是这一行的主信息 —— 宽度再紧也得留着；'
            '被挤没的话用户只看到一个停止按钮，不知道 agent 在干什么',
      );
      expect(find.text('停止'), findsOneWidget,
          reason: '停止按钮永不缩 —— 它是 escape hatch');

      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('宽屏：一行放下时，用量与运行文案仍在同一行', (t) async {
      // 宽屏（平板 / 横屏）下不该因为下面的窄屏适配而拆行 ——
      // 一行能放下就还是一行，这是 2026-10-13 合并的初衷。
      t.view.physicalSize = const Size(900, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(
            text: '答', usage: TokenUsage(inputTokens: 800, outputTokens: 30)),
      ]));
      addTearDown(loop.dispose);
      await _seedUsage(loop);
      loop.debugForceRunning();

      await t.pumpWidget(_wrap(loop));
      await t.pump();

      final stopRow = find
          .ancestor(of: find.text('停止'), matching: find.byType(Row))
          .last;
      expect(
        find.descendant(of: stopRow, matching: find.textContaining('800')),
        findsOneWidget,
        reason: '宽屏下用量应与停止按钮同行 —— 能一行放下就不该拆',
      );

      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('窄屏：用量整段完整显示（不截断），且不在停止按钮那一行',
        (t) async {
      // 方案 C 的核心：窄屏放不下时拆成两行，而不是把用量省略号截断。
      // 用户报的「token 统计显示不全」就是上一版强行单行 + ellipsis 的结果。
      t.view.physicalSize = const Size(360, 720);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      // 一段长到单行绝无可能放下的用量：缓存 + 累计都完整。
      final loop = makeLoop(provider: FakeProvider([
        const AIResponse(
          text: '答',
          usage: TokenUsage(
              inputTokens: 12345, cachedTokens: 9876, outputTokens: 4567),
        ),
      ]));
      addTearDown(loop.dispose);
      await _seedUsage(loop);
      loop.debugForceRunning();

      await t.pumpWidget(_wrap(loop));
      await t.pump();

      expect(t.takeException(), isNull, reason: '拆行后更不该溢出');

      // 用量整段在（不截断）：用「缓存命中」这个只在完整文案里出现的词
      // 判定，而不是数字 —— 数字在截断后的前缀里也可能命中。
      expect(find.textContaining('缓存命中'), findsOneWidget,
          reason: '窄屏下也要看到完整 token 统计，不能省略号截断');

      // 且它不挤在停止按钮同一行里（说明真的拆了行）。
      final stopRow = find
          .ancestor(of: find.text('停止'), matching: find.byType(Row))
          .last;
      expect(
        find.descendant(of: stopRow, matching: find.textContaining('缓存命中')),
        findsNothing,
        reason: '窄屏下用量应独占一行，而不是和停止按钮挤在一行里被截断',
      );

      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('运行中显示本轮已调用次数（实时增长）', (t) async {
      // 用户要的「工具调用次数」：不是收工后才有，而是运行中就能看到
      // 本轮到目前为止调了几次。
      final loop = makeLoop(provider: FakeProvider(const []));
      addTearDown(loop.dispose);
      loop.debugForceRunning();
      // 造一个本轮累计：直接往 MetricsRecorder 里塞两条 TurnMetrics。
      _seedRunTotals(loop, calls: 7);

      await t.pumpWidget(_wrap(loop));
      await t.pump();

      expect(find.textContaining('已调用 7 次'), findsOneWidget,
          reason: '运行中应显示本轮到目前为止的工具调用次数');

      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('本轮一次都没调用时不显示次数 —— 不报无意义的 0', (t) async {
      final loop = makeLoop(provider: FakeProvider(const []));
      addTearDown(loop.dispose);
      loop.debugForceRunning();
      _seedRunTotals(loop, calls: 0);

      await t.pumpWidget(_wrap(loop));
      await t.pump();

      expect(find.textContaining('已调用'), findsNothing,
          reason: '还没动手时显示「已调用 0 次」是噪音');

      await t.pumpWidget(const SizedBox.shrink());
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────
// 用量与运行条合并（2026-10-13）
//
// 两条能同时出现（运行中 + 有 token 统计），而面板最小可拖到屏高的 25%，
// 两行小字条在那里太贵。合并后运行中只剩一行。
// ─────────────────────────────────────────────────────────────────────────

/// 跑一轮真实的 send，让 `loop.totalUsage` 非空（它只从 provider 响应里
/// 累加，没有测试钩子可以直接设）。
Future<void> _seedUsage(AgentLoop loop) async {
  await loop.send('q');
}

/// 给 loop 的本轮计量塞进 [calls] 次工具调用。
///
/// `currentRunTotals` 只看 `_turns` 里 `turn >= _runStartTurn` 的那些
/// —— 所以必须 `beginRun()` 先定边界再 `startTurn()`，否则新塞的轮次会被
/// 挡在边界外、数出 0。`toolCallCount` 是直接可写的字段（`TurnMetrics`
/// 刻意设计成可变，见 turn_metrics.dart 的库文档）。
void _seedRunTotals(AgentLoop loop, {required int calls}) {
  final r = loop.metrics;
  r.beginRun();
  final t = r.startTurn();
  t.toolCallCount = calls;
}
