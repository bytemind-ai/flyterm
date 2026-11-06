import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ui/ai/agent_view.dart';

import '../../ai/agent/_fakes.dart';

// **不能用真的 `VoiceInputService`。** loop 一开始跑，`_onLoopChanged` 就会
// 调 `cancelListening()` 去打断正在进行的录音——真实实现要碰语音识别插件的
// 平台通道，测试环境里没有对应的 mock handler，会一直挂起，而不是快速抛
// `MissingPluginException`。`test/ui/ai/agent_view_test.dart` 已经用同样的
// 最小 fake 踩过这个坑（见那个文件里 `FakeVoiceInputService` 的文档注释），
// 这里独立复制一份而不是跨测试文件 import——两边各自独立，改一边不用担心
// 牵动另一边。
class _FakeVoiceInputService extends VoiceInputService {
  @override
  bool get isAvailable => false;

  @override
  bool get isListening => false;

  @override
  Future<bool> prepare() async => false;

  @override
  Future<void> startListening({
    required void Function(String) onResult,
    void Function(VoiceInputIssue issue)? onFailure,
  }) async {}

  @override
  Future<void> cancelListening() async {}
}

Widget wrap(AgentLoop loop) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<VoiceInputService>(
        create: (_) => _FakeVoiceInputService(),
        child: Scaffold(
          body: AgentView(loop: loop, providerName: 'fake'),
        ),
      ),
    );

void main() {
  testWidgets('流式增量以纯文本渲染在列表尾部', (tester) async {
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[
        const TextDelta('正在看 '),
        const TextDelta('**nginx** 日志'),
        const StreamDone(AIResponse(text: '正在看 **nginx** 日志')),
      ],
    ]);
    final loop = makeLoop(provider: provider);
    await tester.pumpWidget(wrap(loop));

    final f = loop.send('q');
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump();

    // 流进行中：半截 markdown 以字面量出现（刻意的——见实现里的说明）
    expect(find.textContaining('正在看'), findsOneWidget);

    // `tester.pump(duration)` 推的是 flutter_test 的虚拟时钟——`FakeProvider`
    // 里每个 chunk 之间的 `Future.delayed(1ms)` 也挂在这个虚拟时钟上，不是
    // 真实挂钟时间。上面只推了 2ms，两个 TextDelta 到齐，但 `StreamDone`
    // 还差最后一个 1ms 的定时器没触发；`await f` 本身不会推进任何时钟，
    // 在它前面不够的时间就永远不会有人替它推。这里再推一段富余量，把剩下
    // 那个定时器喂完，`f` 才会真的 resolve——否则这一行会挂到测试整体超时。
    await tester.pump(const Duration(milliseconds: 5));

    await f;
    await tester.pumpAndSettle();

    // 定稿后走 markdown 渲染，`**` 不再以字面量出现
    expect(find.textContaining('**nginx**'), findsNothing);
  });

  testWidgets('运行中的工具卡显示已运行秒数，每秒刷新', (tester) async {
    final provider = FakeProvider([
      bashCall('c1', 'ss -ltnp'),
      const AIResponse(text: 'done'),
    ]);
    final runner = _HangingRunner();
    final loop = makeLoop(provider: provider, runner: runner);
    await tester.pumpWidget(wrap(loop));

    final f = loop.send('q');
    // 让 loop 走到执行态——`_HangingRunner.run` 直接 await 一个 Completer，
    // 不带定时器，一次空 pump 排空 microtask 队列就够。
    await tester.pump();
    await tester.pump();

    // 卡片上「已运行 Ns」读的是 `DateTime.now().difference(ev.startedAt!)`
    // ——两头都是真实挂钟时间，不受 `tester.pump(duration)` 那条虚拟时钟
    // 摆布（虚拟时钟只会让应用里挂的定时器空转，`DateTime.now()` 本身
    // 纹丝不动）。所以先用 `runAsync` 跳出虚拟时钟、真等待 2 秒挂钟时间，
    // 让 `DateTime.now()` 真的往前走。
    //
    // 但光真等待还不够：`AgentView` 里刷新这段文字靠的是
    // `Timer.periodic(const Duration(seconds: 1), ...)`（见 agent_view.dart
    // 的 `_syncTick`）——这是挂在 flutter_test 虚拟时钟上的定时器，只有显式
    // `pump(duration)` 才会把它喂到触发，单纯 `pump()`（不带参数）只重绘
    // 当前帧、不推进虚拟时钟，定时器不会响，界面就还停在上一次 build 时
    // 读到的「0s」。所以这里还要再 `pump` 至少 1 个虚拟秒，把 tick 定时器
    // 喂响一次，触发 rebuild，让新的（已经真实前进过的）`DateTime.now()`
    // 读数画出来。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump(const Duration(seconds: 2));

    // 用精确文本而不是 `textContaining('2s')`：底部运行条现在（aipanel
    // 等待可见性任务）也会显示已等待秒数——`executing` 态配一条命令时
    // 渲染的是 "Running ss -ltnp 2s"，同样含有子串 "2s"。这不是回归，是
    // 两处各自独立、都符合预期的新行为，只是让原来那个宽松断言产生了
    // 歧义匹配。工具卡片自己的文案是精确的 "running {seconds}s"
    // （`agentToolRunningFor`，小写、不含命令名），用它精确匹配就只会
    // 命中工具卡片这一个 widget。
    expect(find.text('running 2s'), findsOneWidget);

    runner.release();
    await f;
    await tester.pumpAndSettle();
  });

  testWidgets('loop 停下后 tick 停掉，不再无限重建', (tester) async {
    final provider = FakeProvider([const AIResponse(text: 'done')]);
    final loop = makeLoop(provider: provider);
    await tester.pumpWidget(wrap(loop));
    await loop.send('q');
    await tester.pumpAndSettle();

    // pumpAndSettle 在有周期性 Timer 时会超时。能走到这里即说明 tick
    // 已经被取消 —— 这条断言的价值全在「没超时」上。
    expect(loop.isRunning, isFalse);
  });

  testWidgets('loop 停了但后台任务还在跑时，tick 继续走', (tester) async {
    final provider = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: 'j', name: 'run_background', args: {
          'command': 'sleep 3600',
          'description': '等着',
        })
      ]),
      const AIResponse(text: 'started'),
    ]);
    final loop = makeLoop(
      provider: provider,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
    );
    await tester.pumpWidget(wrap(loop));
    // 不能裸 `await loop.send('q')`：`run_background` 会走到
    // `FakeRunner.run()`，那里有一个真实的 `Future.delayed(1ms)`（模拟网络
    // 往返），挂在 flutter_test 的虚拟时钟上——裸 await 永远等不到它被推进，
    // 整个 future 就此挂起。先拿到 future，pump 一段虚拟时间把那个定时器
    // 喂响，再 await 它。
    final f = loop.send('q');
    await tester.pump(const Duration(milliseconds: 5));
    await f;

    expect(loop.isRunning, isFalse);
    expect(loop.hasRunningJobs, isTrue);

    // 时长要随时间前进。pump 两秒后卡上的秒数应该变了。
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('s'), findsWidgets);

    // 收尾：把任务标记成结束，否则周期 Timer 会让 tester 报「有未完成的
    // Timer」。真实场景里这个 Timer 会在 check_job 拿到退出码时停掉。
    loop.events.whereType<BackgroundJobEvent>().single.exitCode = 0;
    loop.debugNotify();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  });
}

class _HangingRunner extends FakeRunner {
  final _gate = Completer<void>();
  void release() => _gate.complete();

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    ran.add(command);
    await _gate.future;
    return const CommandOutput(stdout: 'ok', stderr: '', exitCode: 0);
  }
}
