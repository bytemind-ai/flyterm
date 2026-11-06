import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ui/ai/widgets/job_card.dart';
import 'package:flyterm/ui/ai/widgets/dense_event_row.dart';

BackgroundJobEvent job({
  int? exitCode,
  bool killed = false,
  String tail = '',
  int agoSeconds = 5,
  String? serverId,
  String? serverName,
}) =>
    BackgroundJobEvent(
      seq: 1,
      jobId: 'job-1700000000000-abcd',
      command: 'apt upgrade -y',
      description: '升级系统包',
      startedAtMs: DateTime.now()
          .subtract(Duration(seconds: agoSeconds))
          .millisecondsSinceEpoch,
      tail: tail,
      exitCode: exitCode,
      killed: killed,
      serverId: serverId,
      serverName: serverName,
    );

Widget wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('运行中的卡不写「运行中」，写距启动与最后确认', (t) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await t.pumpWidget(wrap(JobCard(
      event: BackgroundJobEvent(
        seq: 1,
        jobId: 'j1',
        command: 'docker build .',
        description: '构建镜像',
        startedAtMs: now - 14 * 60 * 1000,
        lineCursor: 0,
        tail: '',
        lastCheckedAtMs: now - 3 * 60 * 1000,
      ),
      onKill: () {},
    )));

    expect(find.textContaining('apt upgrade -y'), findsNothing);
    expect(find.textContaining('距启动 14m'), findsOneWidget);
    expect(find.textContaining('3 分钟前确认'), findsOneWidget);
    // 「运行中」是我们无法确认的事——exitCode 只有模型 check 时才会写。
    expect(find.textContaining('已运行'), findsNothing);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
  });

  testWidgets('已结束：不显示终止按钮，显示退出码', (tester) async {
    await tester.pumpWidget(wrap(JobCard(event: job(exitCode: 0))));

    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
    expect(find.textContaining('0'), findsWidgets);
  });

  testWidgets('日志尾巴按等宽渲染，且不走 markdown', (tester) async {
    await tester.pumpWidget(wrap(JobCard(
      event: job(tail: 'Get:1 http://deb.debian.org\n**not bold**'),
    )));

    // shell 输出里的 ** 是字面量，必须原样出现
    expect(find.textContaining('**not bold**'), findsOneWidget);
  });

  testWidgets('点终止调 onKill 一次，之后按钮禁用', (tester) async {
    var calls = 0;
    await tester.pumpWidget(wrap(JobCard(
      event: job(),
      onKill: () => calls++,
    )));

    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();
    expect(calls, equals(1));
  });

  testWidgets('已请求终止但进程还没死：显示正在终止，按钮不可点', (tester) async {
    var calls = 0;
    await tester.pumpWidget(wrap(JobCard(
      event: job(killed: true),
      onKill: () => calls++,
    )));

    await tester.tap(find.byIcon(Icons.stop_circle_outlined),
        warnIfMissed: false);
    await tester.pump();
    expect(calls, equals(0));
  });

  testWidgets('任务结束走流水行', (t) async {
    await t.pumpWidget(wrap(JobCard(event: job(exitCode: 0))));
    expect(find.byType(DenseEventRow), findsOneWidget);
  });

  testWidgets('运行中仍是完整卡，终止钮在', (t) async {
    await t.pumpWidget(wrap(JobCard(event: job(), onKill: () {})));
    expect(find.byType(DenseEventRow), findsNothing);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
  });

  testWidgets('结束后日志尾巴收在展开区', (t) async {
    await t.pumpWidget(
        wrap(JobCard(event: job(exitCode: 0, tail: 'build done'))));
    expect(find.text('build done'), findsNothing);
    await t.tap(find.byIcon(Icons.expand_more));
    await t.pump();
    expect(find.text('build done'), findsOneWidget);
  });

  testWidgets('结束且无日志时没有展开钮', (t) async {
    await t.pumpWidget(wrap(JobCard(event: job(exitCode: 0))));
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  group('跨机任务显示机器名', () {
    testWidgets('运行中的跨机卡片命令带 [web-2] 前缀', (t) async {
      await t.pumpWidget(wrap(JobCard(
        event: job(serverId: 'id-2', serverName: 'web-2'),
        onKill: () {},
      )));

      expect(find.text('[web-2] apt upgrade -y'), findsOneWidget);
      expect(find.text('apt upgrade -y'), findsNothing,
          reason: '裸命令分不清是哪台机器在跑，两个 pane 一对比就露馅');
    });

    testWidgets('已结束的跨机卡片（流水行）同样带前缀', (t) async {
      // 两条渲染路径（运行中的完整卡 / 结束后的 DenseEventRow）都得带 ——
      // 只改一条的话任务一结束归属就消失。
      await t
          .pumpWidget(wrap(JobCard(event: job(serverName: 'web-2', exitCode: 0))));

      expect(find.textContaining('[web-2] apt upgrade -y'), findsOneWidget);
    });

    testWidgets('本机任务不加任何前缀 —— 与改动前逐像素一致', (t) async {
      await t.pumpWidget(wrap(JobCard(event: job(), onKill: () {})));

      expect(find.text('apt upgrade -y'), findsOneWidget);
      expect(find.textContaining('[', findRichText: true), findsNothing,
          reason: '绝大多数任务在本机跑，给它们加标记只会稀释前缀的信息量');
    });

    test('jobCommandLabel：只有 serverName 非空时才加前缀', () {
      expect(jobCommandLabel(job()), 'apt upgrade -y');
      expect(jobCommandLabel(job(serverName: 'web-2')), '[web-2] apt upgrade -y');
      // serverName 为 null 但 serverId 非空（理论上不该发生）时不加 ——
      // 前缀是给人看的，没有名字就不摆位置。
      expect(jobCommandLabel(job(serverId: 'id-2')), 'apt upgrade -y');
    });
  });

  group('jobCheckedAgo 分档', () {
    test('不足 1 分钟是「刚确认过」', () {
      expect(jobCheckedAgo(0).unit, JobCheckedUnit.justNow);
      expect(jobCheckedAgo(59 * 1000).unit, JobCheckedUnit.justNow);
    });

    test('60 秒整进分钟档', () {
      final r = jobCheckedAgo(60 * 1000);
      expect(r.unit, JobCheckedUnit.minutes);
      expect(r.value, 1);
    });

    test('59 分钟仍是分钟，60 分钟进小时', () {
      expect(jobCheckedAgo(59 * 60 * 1000).unit, JobCheckedUnit.minutes);
      final h = jobCheckedAgo(60 * 60 * 1000);
      expect(h.unit, JobCheckedUnit.hours);
      expect(h.value, 1);
    });

    test('23 小时仍是小时，24 小时进天', () {
      expect(jobCheckedAgo(23 * 3600 * 1000).unit, JobCheckedUnit.hours);
      final d = jobCheckedAgo(24 * 3600 * 1000);
      expect(d.unit, JobCheckedUnit.days);
      expect(d.value, 1);
    });

    test('负数（用户改过系统时间）当作刚确认，不显示负值', () {
      expect(jobCheckedAgo(-5000).unit, JobCheckedUnit.justNow);
    });
  });

  group('formatSinceStart 分钟级', () {
    test('不足 1 分钟显示 <1m —— 不显示秒，秒级跳动是在声称实时性', () {
      expect(formatSinceStart(0), '<1m');
      expect(formatSinceStart(59), '<1m');
    });

    test('分钟与小时', () {
      expect(formatSinceStart(60), '1m');
      expect(formatSinceStart(14 * 60 + 23), '14m');
      expect(formatSinceStart(3600), '1h0m');
      expect(formatSinceStart(3600 + 25 * 60), '1h25m');
    });
  });
}
