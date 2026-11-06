import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/config_import/config_draft.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/home/widgets/config_paste_sheet.dart';

Widget _host({
  required void Function(ServerDraft) onApply,
  Future<String> Function(String)? llm,
}) =>
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ConfigPasteSheet(onApplyServer: onApply, llmComplete: llm),
      ),
    );

void main() {
  testWidgets('粘贴 ssh 命令后点识别，回调拿到 draft', (tester) async {
    ServerDraft? applied;
    await tester.pumpWidget(_host(onApply: (d) => applied = d));

    await tester.enterText(
        find.byType(TextField), 'ssh -p 2222 root@example.com');
    await tester.tap(find.text('识别'));
    await tester.pumpAndSettle();

    expect(applied, isNotNull);
    expect(applied!.host, 'example.com');
    expect(applied!.port, 2222);
  });

  testWidgets('认不出时显示提示与格式示例，不清空输入', (tester) async {
    await tester.pumpWidget(_host(onApply: (_) {}));

    await tester.enterText(find.byType(TextField), '这是一段日志');
    await tester.tap(find.text('识别'));
    await tester.pumpAndSettle();

    expect(find.text('没认出服务器信息'), findsOneWidget);
    // 不清空：用户要能看到自己粘了什么、好手动改。
    expect(find.text('这是一段日志'), findsOneWidget);
  });

  testWidgets('没有 llmComplete 时不显示「用 AI 试试」', (tester) async {
    await tester.pumpWidget(_host(onApply: (_) {}));

    await tester.enterText(find.byType(TextField), '这是一段日志');
    await tester.tap(find.text('识别'));
    await tester.pumpAndSettle();

    expect(find.text('用 AI 试试'), findsNothing);
  });

  testWidgets('有 llmComplete 时显示按钮，但不自动调用', (tester) async {
    var called = false;
    await tester.pumpWidget(_host(
      onApply: (_) {},
      llm: (_) async {
        called = true;
        return '{"host":"1.2.3.4"}';
      },
    ));

    await tester.enterText(find.byType(TextField), '服务器在 1.2.3.4');
    await tester.tap(find.text('识别'));
    await tester.pumpAndSettle();

    expect(find.text('用 AI 试试'), findsOneWidget);
    expect(called, isFalse, reason: 'D3：必须等用户点');
  });

  testWidgets('点「用 AI 试试」才调用 LLM 并回调', (tester) async {
    ServerDraft? applied;
    await tester.pumpWidget(_host(
      onApply: (d) => applied = d,
      llm: (_) async => '{"host":"1.2.3.4","port":2222}',
    ));

    await tester.enterText(find.byType(TextField), '服务器在 1.2.3.4');
    await tester.tap(find.text('识别'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用 AI 试试'));
    await tester.pumpAndSettle();

    expect(applied!.host, '1.2.3.4');
  });

  testWidgets('识别到多台时列出来让用户选', (tester) async {
    ServerDraft? applied;
    await tester.pumpWidget(_host(onApply: (d) => applied = d));

    await tester.enterText(
      find.byType(TextField),
      'Host web-1\n  HostName 10.0.0.5\n\nHost db-1\n  HostName 10.0.0.6',
    );
    await tester.tap(find.text('识别'));
    await tester.pumpAndSettle();

    expect(find.text('识别到多台机器，选一台导入'), findsOneWidget);
    expect(applied, isNull, reason: '没选之前不该回调');

    await tester.tap(find.text('db-1'));
    await tester.pumpAndSettle();
    expect(applied!.host, '10.0.0.6');
  });

  testWidgets('粘贴内容含私钥时显示已忽略的提示', (tester) async {
    await tester.pumpWidget(_host(onApply: (_) {}));

    await tester.enterText(
      find.byType(TextField),
      'Host web\n  HostName 10.0.0.5\n'
          '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n'
          '-----END OPENSSH PRIVATE KEY-----',
    );
    await tester.tap(find.text('识别'));
    await tester.pumpAndSettle();

    expect(find.textContaining('私钥已被忽略'), findsOneWidget);
  });
}
