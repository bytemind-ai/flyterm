import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ai/attachment.dart';
import 'package:flyterm/ui/ai/widgets/attachment_bubble.dart';

Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  const img = Attachment(
      kind: AttachmentKind.image,
      relPath: 's/1.png',
      mime: 'image/png',
      bytes: 2048,
      name: 'shot.png');
  const txt = Attachment(
      kind: AttachmentKind.text,
      relPath: 's/a.log',
      mime: 'text/plain',
      bytes: 12 * 1024,
      name: 'nginx.conf');

  testWidgets('图片文件不存在 → 显示「图片已不可用」占位', (t) async {
    await t.pumpWidget(
        _host(AttachmentBubble(attachment: img, fileFor: (_) => null)));
    expect(find.text('图片已不可用'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('text 类只显示文件名与大小，不渲染正文', (t) async {
    // 正文已经在 content 里由 markdown 渲染过了，这里再来一遍就是重复。
    await t.pumpWidget(
        _host(AttachmentBubble(attachment: txt, fileFor: (_) => null)));
    expect(find.text('nginx.conf'), findsOneWidget);
    expect(find.textContaining('12'), findsOneWidget);
    expect(find.text('图片已不可用'), findsNothing);
  });
}
