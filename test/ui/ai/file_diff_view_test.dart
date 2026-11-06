import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/file_diff_view.dart';

/// 本组测试断言的是 l10n 出来的中文文案，所以钉住 locale。
Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

String _lines(int n) => List.generate(n, (i) => 'line $i').join('\n');

void main() {
  testWidgets('短内容不触发折叠，也不显示展开入口', (t) async {
    await t.pumpWidget(_wrap(const FileDiffView(
      preview: FileEditPreview(path: '/etc/x.conf', newText: 'a\nb\n'),
    )));

    expect(find.text('显示全部'), findsNothing);
    final st = t.widget<SelectableText>(find.byType(SelectableText));
    // 没有超限就不该设 maxLines —— 设了反而可能裁掉本来能显示完的内容。
    expect(st.maxLines, isNull);
  });

  testWidgets('50 行的长内容显示展开入口，且渲染不溢出', (t) async {
    await t.pumpWidget(_wrap(FileDiffView(
      preview: FileEditPreview(path: '/etc/x.conf', newText: _lines(50)),
    )));
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.text('显示全部'), findsOneWidget);
    final st = t.widget<SelectableText>(find.byType(SelectableText));
    expect(st.maxLines, equals(12));
    // 折叠只是渲染上限，widget 持有的文本本身没有被截断。
    expect(st.data, contains('line 49'));
  });

  testWidgets('点击展开入口后取消行数上限，再点一次收回', (t) async {
    await t.pumpWidget(_wrap(FileDiffView(
      preview: FileEditPreview(path: '/etc/x.conf', newText: _lines(50)),
    )));

    await t.tap(find.text('显示全部'));
    await t.pumpAndSettle();

    expect(find.text('收起'), findsOneWidget);
    expect(find.text('显示全部'), findsNothing);
    var st = t.widget<SelectableText>(find.byType(SelectableText));
    expect(st.maxLines, isNull);

    await t.ensureVisible(find.text('收起'));
    await t.tap(find.text('收起'));
    await t.pumpAndSettle();

    expect(find.text('显示全部'), findsOneWidget);
    st = t.widget<SelectableText>(find.byType(SelectableText));
    expect(st.maxLines, equals(12));
  });

  testWidgets('oldText 与 newText 各自独立判断是否需要展开', (t) async {
    await t.pumpWidget(_wrap(FileDiffView(
      preview: FileEditPreview(
        path: '/etc/x.conf',
        oldText: 'short old',
        newText: _lines(50),
      ),
    )));

    // 只有超限的那一块（newText）才带展开入口，oldText 那块不受影响。
    expect(find.text('显示全部'), findsOneWidget);
    expect(find.textContaining('short old'), findsOneWidget);
  });
}
