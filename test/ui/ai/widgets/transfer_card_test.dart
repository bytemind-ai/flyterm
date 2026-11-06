import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/dense_event_row.dart';
import 'package:flyterm/ui/ai/widgets/transfer_card.dart';

Widget wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

TransferEvent downloading({int done = 40}) => TransferEvent(
      seq: 1,
      direction: TransferDirection.download,
      remotePath: '/var/log/app.log',
      filename: 'app.log',
      totalBytes: 100,
      bytesDone: done,
    );

void main() {
  testWidgets('进行中：有进度条与取消按钮，没有结果按钮', (tester) async {
    // onCancel 必须传 —— 实现里 null 时不渲染那个按钮。
    await tester.pumpWidget(
      wrap(TransferCard(event: downloading(), onCancel: () {})),
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('打开'), findsNothing);
  });

  // 完成态改走 DenseEventRow（AI 面板信息密度改版）：进度条
  // 消失没变，但三个按钮不再直接可见，收进了展开区，需要先点展开钮。
  testWidgets('完成：进度条没了，按钮收进展开区里才看得到', (tester) async {
    final ev = downloading(done: 100)
      ..status = TransferStatus.done
      ..localPath = '/storage/Download/app.log';
    await tester.pumpWidget(wrap(TransferCard(event: ev)));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('打开'), findsNothing);

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();

    expect(find.text('打开'), findsOneWidget);
    expect(find.text('让 AI 读完'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
  });

  testWidgets('凭据命中：行上警告收起就看得见，「让 AI 读完」展开后仍禁用', (tester) async {
    final ev = downloading(done: 100)
      ..status = TransferStatus.done
      ..localPath = '/storage/Download/id_rsa'
      ..credentialDeny = true;
    await tester.pumpWidget(wrap(TransferCard(
      event: ev,
      onLetAiRead: () {},
      onOpen: () {},
      onShare: () {},
    )));
    await tester.pump();

    // 凭据警告是数据边界提示，必须留在行上、收起时也看得见 —— 它现在是
    // 流水行富文本里的一段，不是独立 Text，用 textSpan 断言。
    final txt = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(txt.textSpan!.toPlainText(), contains('凭据'));

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();

    final read = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('让 AI 读完'),
        matching: find.byType(TextButton),
      ),
    );
    expect(read.onPressed, isNull, reason: '这是数据边界，不能只靠灰色提示');

    final open = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('打开'),
        matching: find.byType(TextButton),
      ),
    );
    expect(open.onPressed, isNotNull, reason: '用户看自己设备上的文件不该被拦');
  });

  testWidgets('取消按钮触发回调', (tester) async {
    var cancelled = false;
    await tester.pumpWidget(wrap(TransferCard(
      event: downloading(),
      onCancel: () => cancelled = true,
    )));
    await tester.pump();

    await tester.tap(find.text('取消'));
    expect(cancelled, isTrue);
  });

  TransferEvent relay({TransferPhase phase = TransferPhase.downloading}) =>
      TransferEvent(
        seq: 9,
        direction: TransferDirection.relay,
        remotePath: '/etc/nginx/nginx.conf',
        destPath: '/etc/nginx/nginx.conf',
        fromServerName: 'web-1',
        toServerName: 'web-2',
        filename: 'nginx.conf',
        totalBytes: 100,
        bytesDone: 30,
        phase: phase,
      );

  testWidgets('中转下载段显示源机器名', (tester) async {
    await tester.pumpWidget(wrap(TransferCard(event: relay())));
    await tester.pump();
    expect(find.textContaining('web-1'), findsWidgets);
  });

  testWidgets('中转上传段显示目标机器名', (tester) async {
    await tester.pumpWidget(wrap(
        TransferCard(event: relay(phase: TransferPhase.uploading))));
    await tester.pump();
    expect(find.textContaining('web-2'), findsWidgets);
  });

  testWidgets('中转路径行显示 源 → 目标', (tester) async {
    await tester.pumpWidget(wrap(TransferCard(event: relay())));
    await tester.pump();
    expect(find.textContaining('web-1:/etc/nginx/nginx.conf'), findsOneWidget);
    expect(find.textContaining('web-2:/etc/nginx/nginx.conf'), findsOneWidget);
  });

  testWidgets('中转完成后不显示打开/让AI读完/分享 —— 临时文件已经删了',
      (tester) async {
    final ev = relay()
      ..status = TransferStatus.done
      ..bytesDone = 100
      ..localPath = null;
    await tester.pumpWidget(wrap(TransferCard(
      event: ev,
      onOpen: () {},
      onLetAiRead: () {},
      onShare: () {},
    )));
    await tester.pump();

    expect(find.text('打开'), findsNothing);
    expect(find.text('让 AI 读完'), findsNothing);
    expect(find.text('分享'), findsNothing);
  });

  testWidgets('传输完成走流水行', (t) async {
    final ev = downloading(done: 100)..status = TransferStatus.done;
    await t.pumpWidget(wrap(TransferCard(event: ev)));
    expect(find.byType(DenseEventRow), findsOneWidget);
  });

  testWidgets('传输中仍是完整卡', (t) async {
    await t.pumpWidget(
        wrap(TransferCard(event: downloading(), onCancel: () {})));
    expect(find.byType(DenseEventRow), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('完成后三个按钮收在展开区里', (t) async {
    final ev = downloading(done: 100)
      ..status = TransferStatus.done
      ..localPath = '/storage/Download/app.log';
    await t.pumpWidget(wrap(TransferCard(
      event: ev,
      onOpen: () {},
      onLetAiRead: () {},
      onShare: () {},
    )));
    expect(find.text('打开'), findsNothing);
    await t.tap(find.byIcon(Icons.expand_more));
    await t.pump();
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('让 AI 读完'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
  });

  testWidgets('凭据警告留在行上，收起时也看得见', (t) async {
    final ev = downloading(done: 100)
      ..status = TransferStatus.done
      ..credentialDeny = true;
    await t.pumpWidget(wrap(TransferCard(event: ev)));
    final txt = t.widget<SelectableText>(find.byType(SelectableText));
    expect(txt.textSpan!.toPlainText(), contains('凭据'));
  });
}
