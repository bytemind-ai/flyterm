import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ai/attachment.dart';
import 'package:flyterm/ui/ai/widgets/attachment_bar.dart';

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

  testWidgets('显示文件名与大小', (t) async {
    await t.pumpWidget(_host(AttachmentBar(
        attachment: txt, thumbnailFile: null, onRemove: () {})));
    expect(find.text('nginx.conf'), findsOneWidget);
    expect(find.textContaining('12'), findsOneWidget);
  });

  testWidgets('点 ✕ 触发 onRemove', (t) async {
    var removed = false;
    await t.pumpWidget(_host(AttachmentBar(
        attachment: img, thumbnailFile: null, onRemove: () => removed = true)));
    await t.tap(find.byIcon(Icons.close));
    await t.pump();
    expect(removed, isTrue);
  });

  testWidgets('缩略图文件不存在时不崩，显示占位图标', (t) async {
    await t.pumpWidget(_host(AttachmentBar(
        attachment: img, thumbnailFile: null, onRemove: () {})));
    expect(t.takeException(), isNull);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });
}
