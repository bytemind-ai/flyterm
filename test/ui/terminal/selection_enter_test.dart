import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ui/terminal/terminal_widget.dart';

/// 复现真机路径：长按 → 菜单 → 点「选择」→ 选区出现。
///
/// 这条路径此前没有任何测试覆盖 —— controller 的 18 个单测都是直接喂
/// 合法的 CellOffset，绕过了 widget 层的坐标换算与手势时序。
Widget _wrap(
  Terminal terminal,
  TerminalSettings settings, {
  GlobalKey<TerminalWidgetState>? widgetKey,
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
          body: SizedBox(
            width: 400,
            height: 800,
            child: TerminalWidget(
              key: widgetKey,
              terminal: terminal,
              shell: null,
            ),
          ),
        ),
      ),
    );

void main() {
  late Terminal terminal;
  late TerminalSettings settings;

  setUp(() {
    terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    terminal.write('hello world\r\nfoo bar baz\r\nthird line here\r\n');
    settings = TerminalSettings(SecureStorageService());
  });

  testWidgets('长按弹出菜单，点「选择」后进入选区模式', (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings));
    await tester.pumpAndSettle();

    // 长按：这里用的是 Listener + 自己的 500ms Timer，不是 GestureDetector，
    // 所以必须手动按住并 pump 过阈值，tester.longPress 不走这条路。
    final center = tester.getCenter(find.byType(TerminalWidget));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('floating_menu_body')), findsOneWidget,
        reason: '长按 600ms 后应弹出浮动菜单');

    await tester.tap(find.byIcon(Icons.text_fields));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('start_handle')), findsOneWidget,
        reason: '点「选择」后选区 handle 应该出现');
    expect(find.byKey(const ValueKey('end_handle')), findsOneWidget);
  });

  testWidgets('在有文字的位置进入选区，选中的是那个词', (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings));
    await tester.pumpAndSettle();

    // 打到第一行左上角附近，那里是 "hello"
    final topLeft = tester.getTopLeft(find.byType(TerminalWidget));
    final target = topLeft + const Offset(20, 8);
    final gesture = await tester.startGesture(target);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.text_fields));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('start_handle')), findsOneWidget);
  });

  // TerminalScreen 用这个 getter 判断该不该禁用左右滑切 tab。它读的是选区
  // 的当下状态，而不是 onSelectionModeChanged 回调留下的镜像 —— 镜像可能
  // 在手势中途过期（anchor detach、切 buffer 都不发通知）。
  testWidgets('isSelectionActive 跟随选区：进入前 false，进入后 true', (tester) async {
    final key = GlobalKey<TerminalWidgetState>();
    await tester.pumpWidget(_wrap(terminal, settings, widgetKey: key));
    await tester.pumpAndSettle();

    expect(key.currentState!.isSelectionActive, isFalse,
        reason: '还没进选区模式');

    final center = tester.getCenter(find.byType(TerminalWidget));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.text_fields));
    await tester.pumpAndSettle();

    expect(key.currentState!.isSelectionActive, isTrue,
        reason: 'handle 在屏幕上时，滑动必须被判为不切 tab');
  });

}
