import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/ai_launchpad.dart';

Widget host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

LaunchpadSession sess(int id, {List<String> machines = const []}) =>
    LaunchpadSession(
      id: id,
      title: 't$id',
      machines: machines,
      updatedAt: DateTime(2026, 10, 6),
    );

Widget pad({
  List<LaunchpadSession> sessions = const [],
  List<LaunchpadMachine> machines = const [],
  int total = 0,
  List<String> suggestions = const ['s1'],
  void Function(int)? onOpen,
  void Function(String)? onOpenMachine,
  void Function(String)? onSend,
}) =>
    AiLaunchpad(
      title: '标题',
      recentSessions: sessions,
      machines: machines,
      totalMachineCount: total,
      suggestions: suggestions,
      onOpenSession: onOpen ?? (_) {},
      onOpenMachine: onOpenMachine ?? (_) {},
      onSend: onSend ?? (_) {},
    );

void main() {
  testWidgets('全空：只有建议，无标题残留', (tester) async {
    await tester.pumpWidget(host(pad(suggestions: ['s1', 's2'])));
    expect(find.text('s1'), findsOneWidget);
    expect(find.text('接着上次'), findsNothing);
    expect(find.text('机器'), findsNothing);
  });

  testWidgets('有历史有机器：三段标题都在', (tester) async {
    await tester.pumpWidget(host(pad(
      sessions: [sess(1)],
      machines: [const LaunchpadMachine(id: 'a', name: 'web-01', connected: true)],
      total: 1,
    )));
    expect(find.text('接着上次'), findsOneWidget);
    expect(find.text('机器'), findsOneWidget);
  });

  testWidgets('点会话回调拿到 id', (tester) async {
    int? got;
    await tester.pumpWidget(host(pad(sessions: [sess(7)], onOpen: (v) => got = v)));
    await tester.tap(find.text('t7'));
    expect(got, 7);
  });

  testWidgets('点机器回调拿到机器 id（不是名字）', (tester) async {
    String? got;
    await tester.pumpWidget(host(pad(
      machines: [const LaunchpadMachine(id: 'uuid-1', name: 'web-01', connected: true)],
      total: 1,
      onOpenMachine: (v) => got = v,
    )));
    await tester.tap(find.text('web-01'));
    expect(got, 'uuid-1');
  });

  testWidgets('机器 chip 带尾随箭头 —— 给出「点进去」的导航暗示', (tester) async {
    await tester.pumpWidget(host(pad(
      machines: [const LaunchpadMachine(id: 'a', name: 'web-01', connected: true)],
      total: 1,
    )));
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('点建议回调拿到原文', (tester) async {
    String? got;
    await tester.pumpWidget(host(pad(suggestions: ['查一下 web-01 的磁盘'], onSend: (v) => got = v)));
    await tester.tap(find.text('查一下 web-01 的磁盘'));
    expect(got, '查一下 web-01 的磁盘');
  });

  testWidgets('+N 用 totalMachineCount 算，且不可点', (tester) async {
    await tester.pumpWidget(host(pad(
      machines: [
        for (var i = 0; i < 5; i++)
          LaunchpadMachine(id: '$i', name: 'm$i', connected: false),
      ],
      total: 8,
      onOpenMachine: (_) => fail('+N 不该触发任何回调'),
    )));
    expect(find.text('+3'), findsOneWidget);
    await tester.tap(find.text('+3'));
  });

  testWidgets('360dp 不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(pad(
      machines: [
        for (var i = 0; i < 5; i++)
          LaunchpadMachine(id: '$i', name: 'very-long-machine-name-$i', connected: false),
      ],
      total: 5,
      suggestions: ['查一下 very-long-machine-name-0 的磁盘'],
    )));
    expect(tester.takeException(), isNull);
  });
}
