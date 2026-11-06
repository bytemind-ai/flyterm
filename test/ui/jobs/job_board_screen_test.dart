import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/jobs/job_board_controller.dart';
import 'package:flyterm/ui/jobs/job_board_screen.dart';

Server srv(String id) => Server(
      id: id, name: id, host: '$id.example.com', port: 22,
      username: 'ops', authType: 'password', serverType: 'ssh');
CommandOutput out(String s) =>
    CommandOutput(stdout: s, stderr: '', exitCode: 0);

// DenseEventRow 内部用 context.l10n（tooltip 文案），MaterialApp 必须挂上
// AppLocalizations 的 delegates/supportedLocales，否则会在 Tooltip 构造时
// 抛异常。参照 test/ui/ai/widgets/dense_event_row_test.dart 的 wrap()。
Future<void> pump(WidgetTester tester, JobBoardController c) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: JobBoardScreen(controller: c),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('列出任务，显示状态与行数', (tester) async {
    final c = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, __) async => out('job-1757000000000-aaaa|running|12|0\n'),
    );
    await pump(tester, c);
    expect(find.textContaining('job-1757000000000-aaaa'), findsOneWidget);
    expect(find.textContaining('12'), findsWidgets);
  });

  testWidgets('没有任务时显示「没有后台任务」', (tester) async {
    final c = JobBoardController(
      servers: [srv('a')], probe: (_) => true, run: (_, __) async => out(''));
    await pump(tester, c);
    expect(find.textContaining('没有后台任务'), findsOneWidget);
  });

  testWidgets('全部失败时不显示空态，显示错误行', (tester) async {
    final c = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, __) async => throw Exception('connect failed'),
    );
    await pump(tester, c);
    expect(find.textContaining('没有后台任务'), findsNothing);
    expect(find.textContaining('connect failed'), findsOneWidget);
  });

  testWidgets('杀之前要二次确认', (tester) async {
    var killed = false;
    final c = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, cmd) async {
        if (cmd.contains('kill -TERM')) killed = true;
        return out('job-1757000000000-aaaa|running|1|0\n');
      },
    );
    await pump(tester, c);
    // DenseEventRow 的展开区默认收起：trailingLabel + 展开箭头是同一个
    // InkWell 热区（_TrailingTapTarget），点它才能展开出杀任务的按钮。
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.stop_circle_outlined).first);
    await tester.pumpAndSettle();
    expect(killed, isFalse, reason: '弹确认框之前不许发命令');
    await tester.tap(find.text('终止'));
    await tester.pumpAndSettle();
    expect(killed, isTrue);
  });

  testWidgets('杀完的提示说「已发送终止信号」，不说「已终止」', (tester) async {
    // buildJobKillCommand 自带 || true、永远成功，客户端拿不到失败信号。
    final c = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, __) async => out('job-1757000000000-aaaa|running|1|0\n'),
    );
    await pump(tester, c);
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.stop_circle_outlined).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('终止'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已发送终止信号'), findsOneWidget);
    expect(find.textContaining('已终止'), findsNothing);
  });

  testWidgets('kill 之后清掉该 job 的日志缓存，避免展开区还显示杀之前的旧日志',
      (tester) async {
    var pollCalls = 0;
    final c = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, cmd) async {
        // buildJobPollCommand（含 tailLog 复用的那条）固定以这段起头，
        // buildJobListCommand / buildJobKillCommand 不是。
        if (cmd.startsWith('if [ ! -f')) pollCalls++;
        return out('job-1757000000000-aaaa|running|1|0\n');
      },
    );
    await pump(tester, c);
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();
    expect(pollCalls, 1, reason: '第一次展开应该拉一次日志');

    await tester.tap(find.byIcon(Icons.stop_circle_outlined).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('终止'));
    await tester.pumpAndSettle();

    expect(pollCalls, 2,
        reason: 'kill 之后缓存没清的话，这里还是 1——'
            '展开区会一直显示杀之前缓存的那份日志，而不是杀之后可能追加的收尾几行');
  });

  testWidgets('没有活跃 tab 时「让模型接手」disabled', (tester) async {
    final c = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, __) async => out('job-1757000000000-aaaa|running|1|0\n'),
    );
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: JobBoardScreen(controller: c, hasTabFor: (_) => false),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();
    final btn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.smart_toy_outlined));
    expect(btn.onPressed, isNull);
  });

  testWidgets('有活跃 tab 时「让模型接手」投递 prompt 并回到根路由', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mgr = AgentSessionManager(await SharedPreferences.getInstance());
    final c = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, __) async => out('job-1757000000000-aaaa|running|1|0\n'),
    );
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ChangeNotifierProvider<AgentSessionManager>.value(
                value: mgr,
                child: JobBoardScreen(controller: c, hasTabFor: (_) => true),
              ),
            )),
            child: const Text('root'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('root'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();
    final btn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.smart_toy_outlined));
    expect(btn.onPressed, isNotNull);

    await tester.tap(find.byIcon(Icons.smart_toy_outlined));
    await tester.pumpAndSettle();

    expect(mgr.takeStagedPrompt('a'), contains('job-1757000000000-aaaa'));
    // popUntil((r) => r.isFirst) 应该已经把我们送回根路由。
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets('rebuild 不会让已展开的日志重新拉取', (tester) async {
    var pollCalls = 0;
    final c = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, cmd) async {
        // buildJobPollCommand 固定以这段起头，buildJobListCommand 不是。
        if (cmd.startsWith('if [ ! -f')) pollCalls++;
        return out('job-1757000000000-aaaa|running|12|0\n');
      },
    );
    await pump(tester, c);
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();
    expect(pollCalls, 1);

    // 模拟一次跟这个 job 无关的 controller 通知——真实场景里，refreshAll
    // 扫另一台机器扫完也会 notifyListeners，从而触发这里的 rebuild。
    c.refreshOne('a');
    await tester.pumpAndSettle();

    expect(pollCalls, 1, reason: 'rebuild 不该让已经缓存的日志重新发一次 SSH 命令');
  });
}
