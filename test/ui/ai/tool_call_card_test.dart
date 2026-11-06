import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/dense_event_row.dart';
import 'package:flyterm/ui/ai/widgets/tool_call_card.dart';

Widget _wrap(Widget child, {Locale? locale}) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

ToolCallEvent _event({
  ToolCallStatus status = ToolCallStatus.done,
  String? output,
  int? exitCode,
  int? durationMs,
  String? backupPath,
  bool undone = false,
  bool backupMissing = false,
  bool superseded = false,
}) =>
    ToolCallEvent(
      seq: 0,
      callId: 'c1',
      toolName: 'bash',
      displayCommand: 'systemctl status nginx',
      description: '检查 nginx 是否在跑',
      check: const CheckResult(decision: ToolDecision.allow),
      status: status,
    )
      ..output = output
      ..exitCode = exitCode
      ..durationMs = durationMs
      ..backupPath = backupPath
      ..undone = undone
      ..backupMissing = backupMissing
      ..superseded = superseded;

void main() {
  testWidgets('显示 description 与命令', (t) async {
    // done 状态现在走流水行：description 与命令拼进同一段富文本，不再是
    // 两个独立的 Text —— 用 textContaining 表达「两者都在」这个原意图。
    await t.pumpWidget(_wrap(ToolCallCard(event: _event())));
    expect(find.textContaining('检查 nginx 是否在跑'), findsOneWidget);
    expect(find.textContaining('systemctl status nginx'), findsOneWidget);
  });

  testWidgets('输出默认折叠', (t) async {
    await t.pumpWidget(
        _wrap(ToolCallCard(event: _event(output: 'active (running)'))));
    expect(find.text('active (running)'), findsNothing);
  });

  testWidgets('点击后展开输出', (t) async {
    await t.pumpWidget(
        _wrap(ToolCallCard(event: _event(output: 'active (running)'))));
    await t.tap(find.byIcon(Icons.expand_more));
    await t.pumpAndSettle();
    expect(find.text('active (running)'), findsOneWidget);
  });

  testWidgets('无输出时不显示展开按钮', (t) async {
    await t.pumpWidget(_wrap(ToolCallCard(event: _event())));
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  testWidgets('running 状态显示进度圈', (t) async {
    await t.pumpWidget(
        _wrap(ToolCallCard(event: _event(status: ToolCallStatus.running))));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('failed 状态显示错误图标', (t) async {
    await t.pumpWidget(_wrap(
        ToolCallCard(event: _event(status: ToolCallStatus.failed, output: 'x'))));
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('rejected 状态显示拒绝图标', (t) async {
    await t.pumpWidget(_wrap(
        ToolCallCard(event: _event(status: ToolCallStatus.rejected))));
    expect(find.byIcon(Icons.block), findsOneWidget);
  });

  // deferred 是 plan 模式下「已加入方案」的状态。加这条测试时还没有任何
  // 代码会真正产生它（提案队列尚未接线），但图标分支已经写了——先钉住
  // 渲染，等接线那一批就不必同时排查逻辑和渲染两层。
  testWidgets('deferred 状态显示加入方案图标', (t) async {
    await t.pumpWidget(_wrap(
        ToolCallCard(event: _event(status: ToolCallStatus.deferred))));
    expect(find.byIcon(Icons.playlist_add_check), findsOneWidget);
  });

  testWidgets('有备份的写入卡显示撤销按钮，点它触发回调', (t) async {
    // 撤销按钮现在收进流水行的展开区——先展开才看得到。
    var undone = 0;
    await t.pumpWidget(_wrap(
      ToolCallCard(
        event: _writeEvent(backupPath: '/etc/.a.conf.flyterm.bak.1'),
        onUndo: () => undone++,
      ),
      locale: const Locale('zh'),
    ));

    expect(find.text('撤销'), findsNothing);
    await t.tap(find.byIcon(Icons.expand_more));
    await t.pump();
    expect(find.text('撤销'), findsOneWidget);
    await t.tap(find.text('撤销'));
    expect(undone, equals(1));
  });

  testWidgets('没有备份路径时不显示撤销行——写入失败的卡不该给假按钮', (t) async {
    await t.pumpWidget(_wrap(
      ToolCallCard(
        event: _writeEvent(backupPath: null),
        onUndo: () {},
      ),
      locale: const Locale('zh'),
    ));

    expect(find.text('撤销'), findsNothing);
    expect(find.text('已撤销'), findsNothing);
  });

  testWidgets('已撤销显示「已撤销」且没有可点的撤销按钮', (t) async {
    // 「已撤销」现在并进流水行的富文本尾部，不再是独立 Text——用
    // textContaining 表达同一意图。
    await t.pumpWidget(_wrap(
      ToolCallCard(
        event: _writeEvent(backupPath: '/etc/.a.bak.1', undone: true),
        onUndo: () {},
      ),
      locale: const Locale('zh'),
    ));

    expect(find.textContaining('已撤销'), findsOneWidget);
    expect(find.text('撤销'), findsNothing);
  });

  testWidgets('备份丢失时说明原因，且不可再点', (t) async {
    await t.pumpWidget(_wrap(
      ToolCallCard(
        event: _writeEvent(backupPath: '/etc/.a.bak.1', backupMissing: true),
        onUndo: () {},
      ),
      locale: const Locale('zh'),
    ));

    expect(find.textContaining('备份已不存在'), findsOneWidget);
    expect(find.text('撤销'), findsNothing);
  });

  testWidgets('onUndo 为 null 时不显示按钮——只读场景', (t) async {
    await t.pumpWidget(_wrap(
      ToolCallCard(event: _writeEvent(backupPath: '/etc/.a.bak.1')),
      locale: const Locale('zh'),
    ));

    expect(find.text('撤销'), findsNothing);
  });

  testWidgets('bash 卡不显示撤销行', (t) async {
    // 既有的 _event 辅助造的是 bash 卡，它没有 backupPath
    await t.pumpWidget(_wrap(
      ToolCallCard(event: _event(), onUndo: () {}),
      locale: const Locale('zh'),
    ));

    expect(find.text('撤销'), findsNothing);
  });

  testWidgets('superseded 的卡片压暗并显示说明', (t) async {
    // 说明文字现在并进流水行富文本尾部，不再单占一行 Text——用
    // textContaining 表达同一意图。
    final ev = _event()..superseded = true;
    await t.pumpWidget(_wrap(
      ToolCallCard(event: ev),
      locale: const Locale('zh'),
    ));

    final opacityFinder = find.byType(Opacity);
    expect(opacityFinder, findsOneWidget);
    final opacity = t.widget<Opacity>(opacityFinder);
    expect(opacity.opacity, lessThan(1));
    expect(find.textContaining('抢跑结果已弃用，此命令已重新执行'), findsOneWidget);
  });

  testWidgets('普通卡片不压暗、不显示那句说明', (t) async {
    await t.pumpWidget(_wrap(
      ToolCallCard(event: _event()),
      locale: const Locale('zh'),
    ));

    expect(find.byType(Opacity), findsNothing);
    expect(find.text('抢跑结果已弃用，此命令已重新执行'), findsNothing);
  });

  testWidgets('终态耗时超过阈值时显示', (t) async {
    final ev = _event(status: ToolCallStatus.done)..durationMs = 2400;
    await t.pumpWidget(_wrap(ToolCallCard(event: ev)));
    expect(find.textContaining('2.4s'), findsOneWidget);
  });

  testWidgets('终态耗时低于阈值时不显示', (t) async {
    final ev = _event(status: ToolCallStatus.done)..durationMs = 300;
    await t.pumpWidget(_wrap(ToolCallCard(event: ev)));
    expect(find.textContaining('0.3s'), findsNothing);
  });

  group('formatToolDuration', () {
    test('低于 1s 不显示', () {
      expect(formatToolDuration(999), isNull);
      expect(formatToolDuration(0), isNull);
      expect(formatToolDuration(null), isNull);
    });
    test('秒级保留一位小数', () {
      expect(formatToolDuration(1000), '1.0s');
      expect(formatToolDuration(2400), '2.4s');
      expect(formatToolDuration(59900), '59.9s');
    });
    test('超过一分钟用 m/s', () {
      expect(formatToolDuration(60000), '1m0s');
      expect(formatToolDuration(133000), '2m13s');
    });
  });

  group('isTerminal', () {
    test('终态三种', () {
      expect(isTerminal(ToolCallStatus.done), isTrue);
      expect(isTerminal(ToolCallStatus.failed), isTrue);
      expect(isTerminal(ToolCallStatus.rejected), isTrue);
    });

    test('未结束三种', () {
      expect(isTerminal(ToolCallStatus.running), isFalse);
      expect(isTerminal(ToolCallStatus.awaitingApproval), isFalse);
      expect(isTerminal(ToolCallStatus.deferred), isFalse);
    });
  });

  group('流水行', () {
    testWidgets('done 走流水行', (t) async {
      await t.pumpWidget(_wrap(ToolCallCard(event: _event())));
      expect(find.byType(DenseEventRow), findsOneWidget);
    });

    testWidgets('deferred 走完整卡', (t) async {
      await t.pumpWidget(_wrap(
          ToolCallCard(event: _event(status: ToolCallStatus.deferred))));
      expect(find.byType(DenseEventRow), findsNothing);
    });

    testWidgets('running 走完整卡', (t) async {
      await t.pumpWidget(_wrap(
          ToolCallCard(event: _event(status: ToolCallStatus.running))));
      expect(find.byType(DenseEventRow), findsNothing);
    });

    testWidgets('命令逐字完整，无省略号', (t) async {
      await t.pumpWidget(_wrap(SizedBox(
        width: 360,
        child: ToolCallCard(event: _event()),
      )));
      final txt = t.widget<SelectableText>(find.byType(SelectableText));
      expect(txt.textSpan!.toPlainText(), contains('systemctl status nginx'));
      expect(txt.textSpan!.toPlainText(), isNot(contains('…')));
    });

    testWidgets('耗时进尾部', (t) async {
      await t.pumpWidget(_wrap(ToolCallCard(event: _event(durationMs: 1200))));
      final txt = t.widget<SelectableText>(find.byType(SelectableText));
      expect(txt.textSpan!.toPlainText(), contains('1.2s'));
    });

    testWidgets('非零退出码进尾部', (t) async {
      await t.pumpWidget(_wrap(ToolCallCard(
          event: _event(status: ToolCallStatus.failed, exitCode: 1))));
      final txt = t.widget<SelectableText>(find.byType(SelectableText));
      expect(txt.textSpan!.toPlainText(), contains('1'));
      expect(find.byType(DenseEventRow), findsOneWidget);
    });

    testWidgets('已撤销进尾部且仍是流水行', (t) async {
      // 默认 locale 在测试环境下解析成 en，「已撤销」是中文文案，必须
      // 显式指定 locale 才断言得到。
      await t.pumpWidget(_wrap(
        ToolCallCard(event: _event(backupPath: '/tmp/b', undone: true)),
        locale: const Locale('zh'),
      ));
      expect(find.byType(DenseEventRow), findsOneWidget);
      final txt = t.widget<SelectableText>(find.byType(SelectableText));
      expect(txt.textSpan!.toPlainText(), contains('已撤销'));
    });

    testWidgets('备份丢失进流水行，不再是完整卡', (t) async {
      await t.pumpWidget(_wrap(ToolCallCard(
          event: _event(backupPath: '/tmp/b', backupMissing: true))));
      expect(find.byType(DenseEventRow), findsOneWidget);
    });

    testWidgets('superseded 压暗且尾部带说明', (t) async {
      // 计划草稿断言 contains('取代')，但 agentToolSuperseded 的实际文案是
      // 「抢跑结果已弃用，此命令已重新执行」，不含「取代」二字——按仓库
      // 现状改断言，用实际文案的子串。默认 locale 在测试环境下解析成
      // en，必须显式指定 zh 才能断言到中文文案。
      await t.pumpWidget(_wrap(
        ToolCallCard(event: _event(superseded: true)),
        locale: const Locale('zh'),
      ));
      expect(find.byType(Opacity), findsWidgets);
      final txt = t.widget<SelectableText>(find.byType(SelectableText));
      expect(txt.textSpan!.toPlainText(), contains('抢跑结果已弃用'));
    });

    testWidgets('输出行数标签', (t) async {
      await t.pumpWidget(
          _wrap(ToolCallCard(event: _event(output: 'a\nb\nc\n'))));
      expect(find.textContaining('3'), findsWidgets);
    });

    testWidgets('description 为空时不留下孤零零的分隔符', (t) async {
      // 并非所有工具都给 description，这条路会真的走到。前导 ' · '
      // 必须跟着一起省略，否则行首会出现「· cat /etc/...」。
      final ev = ToolCallEvent(
        seq: 0,
        callId: 'c1',
        toolName: 'bash',
        displayCommand: 'ls -la',
        description: '',
        check: const CheckResult(decision: ToolDecision.allow),
        status: ToolCallStatus.done,
      );
      await t.pumpWidget(_wrap(ToolCallCard(event: ev)));
      final txt = t.widget<SelectableText>(find.byType(SelectableText));
      expect(txt.textSpan!.toPlainText(), 'ls -la');
    });
  });
}

/// 造一张写文件工具卡。[backupPath] 为 null 表示写入没成功（或不是写文件
/// 工具），此时撤销行整个不显示。
ToolCallEvent _writeEvent({
  String? backupPath,
  bool undone = false,
  bool backupMissing = false,
}) {
  final ev = ToolCallEvent(
    seq: 1,
    callId: 'c1',
    toolName: 'write_file',
    displayCommand: 'write /etc/a.conf (1 lines)',
    description: '写配置',
    check: const CheckResult(decision: ToolDecision.allow),
    preview: const FileEditPreview(path: '/etc/a.conf', newText: 'x'),
    status: ToolCallStatus.done,
  );
  ev.backupPath = backupPath;
  ev.undone = undone;
  ev.backupMissing = backupMissing;
  return ev;
}
