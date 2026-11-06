import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/ai/widgets/dense_event_row.dart';
import 'package:flutter/material.dart';
import 'package:flyterm/l10n/app_localizations.dart';

void main() {
  group('countLines', () {
    test('末尾换行不多算一行', () {
      expect(countLines('a\n'), 1);
    });

    test('多行', () {
      expect(countLines('a\nb\nc'), 3);
    });

    test('多行且末尾换行', () {
      expect(countLines('a\nb\n'), 2);
    });

    test('空串是 0', () {
      expect(countLines(''), 0);
    });

    test('只有空白也是 0', () {
      expect(countLines('  \n\n'), 0);
    });
  });

  Widget wrap(Widget child) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  group('DenseEventRow', () {
    testWidgets('渲染 spans 与计数标签', (t) async {
      await t.pumpWidget(wrap(DenseEventRow(
        leading: const Icon(Icons.check, size: 16),
        spans: const [TextSpan(text: 'cat /etc/nginx/nginx.conf')],
        trailingLabel: '12 行',
      )));
      expect(find.text('cat /etc/nginx/nginx.conf'), findsOneWidget);
      expect(find.text('12 行'), findsOneWidget);
    });

    testWidgets('expanded 为 null 时不渲染展开钮', (t) async {
      await t.pumpWidget(wrap(DenseEventRow(
        leading: const Icon(Icons.check, size: 16),
        spans: const [TextSpan(text: 'ls')],
      )));
      expect(find.byIcon(Icons.expand_more), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('点展开钮就地展开，内容可见', (t) async {
      await t.pumpWidget(wrap(DenseEventRow(
        leading: const Icon(Icons.check, size: 16),
        spans: const [TextSpan(text: 'ls')],
        expanded: (_) => const Text('active (running)'),
      )));
      expect(find.text('active (running)'), findsNothing);
      await t.tap(find.byIcon(Icons.expand_more));
      await t.pump();
      expect(find.text('active (running)'), findsOneWidget);
    });

    testWidgets('计数标签也在热区里 —— 点数字就能展开', (t) async {
      // 真机反馈「不好点」之后把标签一起纳进热区。用户本来就会去点那个
      // 数字，点了没反应比按钮小更让人困惑。
      await t.pumpWidget(wrap(DenseEventRow(
        leading: const Icon(Icons.check, size: 16),
        spans: const [TextSpan(text: 'ls')],
        trailingLabel: '12 行',
        expanded: (_) => const Text('active (running)'),
      )));

      await t.tap(find.text('12 行'));
      await t.pump();
      expect(find.text('active (running)'), findsOneWidget);
    });

    testWidgets('热区宽度够手指点 —— 但不把行撑高', (t) async {
      // 压到 28×20 的图标钮真机上不好点（推荐触摸目标是 48×48）。纵向不能
      // 加，加了行高就回去了；横向是免费的，行高由内容决定。
      await t.pumpWidget(wrap(SizedBox(
        width: 360,
        child: DenseEventRow(
          leading: const Icon(Icons.check, size: 16),
          spans: const [TextSpan(text: 'ls')],
          trailingLabel: '12 行',
          expanded: (_) => const Text('x'),
        ),
      )));

      final hit = t.getSize(find.byType(InkWell));
      expect(hit.width, greaterThanOrEqualTo(48),
          reason: '热区宽度 ${hit.width}px，手指点不中');
      expect(t.getSize(find.byType(DenseEventRow)).height, lessThan(32),
          reason: '热区不该把行撑高');
    });

    testWidgets('长文本折行而不截断', (t) async {
      const long =
          'sed -n \'1,200p\' -- /root/.flyterm-server/logs.backup.20260909';
      await t.pumpWidget(wrap(SizedBox(
        width: 360,
        child: DenseEventRow(
          leading: const Icon(Icons.check, size: 16),
          spans: const [TextSpan(text: long)],
        ),
      )));
      final txt = t.widget<SelectableText>(find.byType(SelectableText));
      expect(txt.textSpan!.toPlainText(), long);
      expect(txt.maxLines, isNull);
    });

    testWidgets('展开钮不把行撑到 48px', (t) async {
      await t.pumpWidget(wrap(SizedBox(
        width: 360,
        child: DenseEventRow(
          leading: const Icon(Icons.check, size: 16),
          spans: const [TextSpan(text: 'ls')],
          expanded: (_) => const Text('x'),
        ),
      )));
      expect(t.getSize(find.byType(DenseEventRow)).height, lessThan(32));
    });
  });
}
