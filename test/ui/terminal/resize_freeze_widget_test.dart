// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ssh/transport/remote_transport.dart';
import 'package:flyterm/ui/terminal/resize_freeze.dart';
import 'package:flyterm/ui/terminal/terminal_widget.dart';

/// 键盘弹收导致的本地 resize：alt-buffer + 非 mosh 时 TerminalWidget 盖一张
/// 冻结快照，远端重绘落屏后的下一帧撤掉。键盘用 `tester.view.viewInsets`
/// 模拟 —— 和真机一样同时走 didChangeMetrics 与 MediaQuery 两条路，
/// Scaffold 随之把 body 缩矮，终端真的触发 onResize。
Widget _wrap(
  Terminal terminal,
  TerminalSettings settings, {
  required ValueNotifier<int> signal,
  bool isMosh = false,
  bool isActive = true,
  RemoteTransport? transport,
}) =>
    MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<TerminalSettings>.value(
        value: settings,
        child: Scaffold(
          body: TerminalWidget(
            terminal: terminal,
            shell: null,
            isActive: isActive,
            isMosh: isMosh,
            transport: transport,
            // 远端输出用 SessionTab.resizeOutputTick 的同款信号模拟。
            resizeOutputSignal: signal,
            // iconButton：不让激活时自动 requestKeyboard 干扰测试。
            keyboardTriggerMode: KeyboardTriggerMode.iconButton,
          ),
        ),
      ),
    );

/// 只实现 TerminalWidget 冻结路径会碰到的成员，其余走 noSuchMethod。
class _FakeTransport implements RemoteTransport {
  final states = StreamController<TransportState>.broadcast();
  @override
  Set<TransportCapability> get capabilities => const {};
  @override
  TransportState get currentState => TransportState.connected;
  @override
  Stream<TransportState> get stateStream => states.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Finder get _overlay => find.byKey(kResizeFreezeOverlayKey);

void main() {
  late Terminal terminal;
  late TerminalSettings settings;
  late ValueNotifier<int> signal;

  setUp(() {
    terminal = Terminal(maxLines: 1000);
    settings = TerminalSettings(SecureStorageService());
    signal = ValueNotifier(0);
  });

  tearDown(() => signal.dispose());

  Future<void> showKeyboard(WidgetTester tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    // 把 220 ms 防抖、300 ms 兜底、600 ms Ctrl+End 以及冻结硬上限都走完。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('alt buffer + SSH：键盘弹起即冻结，远端重绘落屏后的下一帧解冻',
      (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings, signal: signal));
    terminal.write('\x1b[?1049h\x1b[Hvim screen');
    await tester.pump();
    expect(terminal.isUsingAltBuffer, isTrue);
    expect(_overlay, findsNothing);

    await showKeyboard(tester);
    expect(_overlay, findsOneWidget, reason: '首帧就要盖上快照');
    expect(
      find.descendant(of: _overlay, matching: find.byType(RawImage)),
      findsOneWidget,
    );

    // 远端 resize 还没发（防抖 220 ms）：此时来的输出不算重绘，不解冻。
    signal.value++;
    await tester.pump();
    await tester.pump();
    expect(_overlay, findsOneWidget);

    // 防抖到期 → _shellResize → remoteResizeSent。
    await tester.pump(const Duration(milliseconds: 250));
    expect(_overlay, findsOneWidget);

    // 刚发出 resize 就来的输出是服务端还没看到新尺寸时产生的（RTT 未知时
    // 门限 = 0.8 × 80 ms），不能解冻。
    signal.value++;
    await tester.pump();
    await tester.pump();
    expect(_overlay, findsOneWidget, reason: '门限内的在途旧输出');

    // 过了门限后的远端重绘写进终端：当帧仍盖着，post-frame 撤掉，
    // 下一帧露出真画面。
    await tester.pump(const Duration(milliseconds: 70));
    signal.value++;
    await tester.pump();
    await tester.pump();
    expect(_overlay, findsNothing);
    await settle(tester);
  });

  testWidgets('远端 resize 已发但一直没输出 → 500 ms 后解冻', (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings, signal: signal));
    terminal.write('\x1b[?1049h\x1b[Hvim screen');
    await tester.pump();
    await showKeyboard(tester);
    expect(_overlay, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_overlay, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_overlay, findsNothing);
    await settle(tester);
  });

  testWidgets('键盘收起同样冻结（视口变高，图像盖不到处用背景色）', (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings, signal: signal));
    terminal.write('\x1b[?1049h\x1b[Hvim screen');
    await tester.pump();
    await showKeyboard(tester);
    await settle(tester);
    expect(_overlay, findsNothing);

    tester.view.resetViewInsets();
    await tester.pump();
    expect(_overlay, findsOneWidget);
    final box = tester.widget<ColoredBox>(
      find.descendant(of: _overlay, matching: find.byType(ColoredBox)),
    );
    expect(box.color, isNot(Colors.transparent));
    await settle(tester);
    expect(_overlay, findsNothing);
  });

  testWidgets('mosh 永不冻结', (tester) async {
    await tester.pumpWidget(
      _wrap(terminal, settings, signal: signal, isMosh: true),
    );
    terminal.write('\x1b[?1049h\x1b[Hvim screen');
    await tester.pump();
    await showKeyboard(tester);
    expect(_overlay, findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_overlay, findsNothing);
    await settle(tester);
  });

  testWidgets('main buffer（普通 shell）永不冻结', (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings, signal: signal));
    terminal.write('user@host:~\$ ');
    await tester.pump();
    await showKeyboard(tester);
    expect(_overlay, findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_overlay, findsNothing);
    await settle(tester);
  });

  testWidgets('非活动 tab 不冻结', (tester) async {
    await tester.pumpWidget(
      _wrap(terminal, settings, signal: signal, isActive: false),
    );
    terminal.write('\x1b[?1049h\x1b[Hvim screen');
    await tester.pump();
    await showKeyboard(tester);
    expect(_overlay, findsNothing);
    await settle(tester);
  });

  testWidgets('冻结中 tab 被切走 → 立即解冻', (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings, signal: signal));
    terminal.write('\x1b[?1049h\x1b[Hvim screen');
    await tester.pump();
    await showKeyboard(tester);
    expect(_overlay, findsOneWidget);
    await tester.pumpWidget(
      _wrap(terminal, settings, signal: signal, isActive: false),
    );
    await tester.pump();
    expect(_overlay, findsNothing);
    await settle(tester);
  });

  testWidgets('冻结中 widget 销毁不抛异常、不泄漏计时器', (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings, signal: signal));
    terminal.write('\x1b[?1049h\x1b[Hvim screen');
    await tester.pump();
    await showKeyboard(tester);
    expect(_overlay, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  // ── fix round 1 ──────────────────────────────────────────────────────────

  testWidgets('inset 变了但终端网格没变 → 很快解冻，不挡 1.5 s', (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings, signal: signal));
    terminal.write('\x1b[?1049h\x1b[Hvim screen');
    await tester.pump();
    final rows = terminal.viewHeight;
    final cols = terminal.viewWidth;
    // 1 个逻辑像素：IME 工具条 / 候选栏高度微调这一类。
    tester.view.viewInsets = const FakeViewPadding(bottom: 3);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    expect(terminal.viewHeight, rows, reason: '前提：网格确实没变');
    expect(terminal.viewWidth, cols);
    expect(_overlay, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(_overlay, findsNothing);
    await settle(tester);
  });

  testWidgets('同一次键盘过渡里解冻后，后续 inset 帧不再重新冻结', (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings, signal: signal));
    terminal.write('\x1b[?1049h\x1b[Hvim screen');
    await tester.pump();
    addTearDown(tester.view.resetViewInsets);
    // 一段一直在动的 inset（动画 / IME 抖动），每 50 ms 一帧。
    var inset = 900.0;
    Future<void> tick() async {
      inset += 3;
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 50));
    }

    tester.view.viewInsets = FakeViewPadding(bottom: inset);
    await tester.pump();
    expect(_overlay, findsOneWidget);
    // inset 一直在动，onResize 防抖被不断推迟；300 ms 的 open-fallback 先发出
    // 一次 resize（就是动画中途的那种中间尺寸），过门限后来输出 → 解冻。
    for (var i = 0; i < 8; i++) {
      await tick();
    }
    signal.value++;
    await tester.pump();
    await tester.pump();
    expect(_overlay, findsNothing);
    // 过渡还没结束：继续抖，不能再盖上一张快照。
    for (var i = 0; i < 4; i++) {
      await tick();
      expect(_overlay, findsNothing);
    }
    // 静下来之后的新一次键盘变化可以重新冻结。
    await tester.pump(const Duration(milliseconds: 300));
    tester.view.resetViewInsets();
    await tester.pump();
    expect(_overlay, findsOneWidget);
    await settle(tester);
  });

  testWidgets('冻结中 transport 掉线（对象不变）→ 立即解冻', (tester) async {
    final t = _FakeTransport();
    addTearDown(t.states.close);
    await tester.pumpWidget(
      _wrap(terminal, settings, signal: signal, transport: t),
    );
    terminal.write('\x1b[?1049h\x1b[Hvim screen');
    await tester.pump();
    await showKeyboard(tester);
    expect(_overlay, findsOneWidget);
    t.states.add(TransportState.reconnecting);
    await tester.pump();
    await tester.pump();
    expect(_overlay, findsNothing);
    await settle(tester);
  });
}
