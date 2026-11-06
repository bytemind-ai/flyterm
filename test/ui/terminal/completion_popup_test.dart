import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/completion_suggestion.dart';
import 'package:flyterm/ui/terminal/completion_popup.dart';

Widget _wrap(Widget child, {Size size = const Size(400, 800)}) => MaterialApp(
      locale: const Locale('zh'),
      home: Scaffold(
        body: SizedBox(
          width: size.width,
          height: size.height,
          child: Stack(children: [child]),
        ),
      ),
    );

/// Flutter's `Text.rich` wraps the given span in an extra
/// `TextSpan(style: ..., children: [span])` whenever a `DefaultTextStyle` is
/// in scope (it always is), so the root `RichText.text` has one child — the
/// span this widget actually built. This collects the leaf `TextSpan`s (the
/// ones carrying actual text, not just grouping children) regardless of how
/// deep that wrapping goes.
List<TextSpan> _leafSpans(InlineSpan root) {
  final leaves = <TextSpan>[];
  void visit(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text != null) {
        leaves.add(span);
      }
      span.children?.forEach(visit);
    }
  }

  visit(root);
  return leaves;
}

void main() {
  const anchor = Rect.fromLTWH(100, 400, 10, 20);

  testWidgets('empty suggestions renders nothing', (tester) async {
    await tester.pumpWidget(_wrap(const CompletionPopup(
      suggestions: [],
      input: '',
      anchor: anchor,
      onAccept: _noop,
    )));

    expect(find.byType(SizedBox), findsWidgets);
    expect(find.byType(RichText), findsNothing);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('prefix highlight splits matched suggestion into two spans',
      (tester) async {
    await tester.pumpWidget(_wrap(const CompletionPopup(
      suggestions: [
        CompletionSuggestion(
            text: 'git commit', source: CompletionSource.shell),
      ],
      input: 'git co',
      anchor: anchor,
      onAccept: _noop,
    )));
    await tester.pump();

    final richTextFinder = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == 'git commit',
    );
    expect(richTextFinder, findsOneWidget);

    final richText = tester.widget<RichText>(richTextFinder);
    final leaves = _leafSpans(richText.text);
    expect(leaves.length, 2);

    expect(leaves[0].text, 'git co');
    expect(leaves[1].text, 'mmit');
    expect(leaves[0].style!.color, isNot(equals(leaves[1].style!.color)));
  });

  testWidgets('non-matching prefix renders single-color span',
      (tester) async {
    await tester.pumpWidget(_wrap(const CompletionPopup(
      suggestions: [
        CompletionSuggestion(
            text: 'ls -la', source: CompletionSource.history),
      ],
      input: 'git co',
      anchor: anchor,
      onAccept: _noop,
    )));
    await tester.pump();

    final richTextFinder = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == 'ls -la',
    );
    expect(richTextFinder, findsOneWidget);

    final richText = tester.widget<RichText>(richTextFinder);
    final leaves = _leafSpans(richText.text);
    expect(leaves.length, 1);
    expect(leaves[0].text, 'ls -la');
  });

  testWidgets('tapping a row invokes onAccept with that suggestion',
      (tester) async {
    CompletionSuggestion? accepted;
    const suggestions = [
      CompletionSuggestion(text: 'git commit', source: CompletionSource.shell),
      CompletionSuggestion(text: 'git checkout', source: CompletionSource.history),
    ];

    await tester.pumpWidget(_wrap(CompletionPopup(
      suggestions: suggestions,
      input: 'git co',
      anchor: anchor,
      onAccept: (s) => accepted = s,
    )));
    await tester.pump();

    final target = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == 'git checkout',
    );
    expect(target, findsOneWidget);
    await tester.tap(target, warnIfMissed: false);
    await tester.pump();

    expect(accepted, suggestions[1]);
  });

  testWidgets('panel height is clamped when suggestions exceed max visible',
      (tester) async {
    final suggestions = List.generate(
      10,
      (i) => CompletionSuggestion(
          text: 'cmd-$i', source: CompletionSource.shell),
    );

    await tester.pumpWidget(_wrap(CompletionPopup(
      suggestions: suggestions,
      input: '',
      anchor: anchor,
      onAccept: _noop,
    )));
    await tester.pump();

    final constrainedBox = tester.widgetList<ConstrainedBox>(
      find.byType(ConstrainedBox),
    );
    final matching = constrainedBox.where(
      (c) => c.constraints.maxHeight <= kCompletionMaxVisible * kCompletionRowHeight,
    );
    expect(matching, isNotEmpty);

    final listViewFinder = find.byType(ListView);
    expect(listViewFinder, findsOneWidget);
    final renderedHeight = tester.getSize(listViewFinder).height;
    expect(renderedHeight,
        lessThanOrEqualTo(kCompletionMaxVisible * kCompletionRowHeight));
  });

  testWidgets('long text does not use ellipsis overflow', (tester) async {
    const longText =
        'git commit --amend --no-edit --author "someone <someone@example.com>"';
    await tester.pumpWidget(_wrap(const CompletionPopup(
      suggestions: [
        CompletionSuggestion(text: longText, source: CompletionSource.shell),
      ],
      input: 'git commit',
      anchor: anchor,
      onAccept: _noop,
    )));
    await tester.pump();

    final richTextFinder = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == longText,
    );
    expect(richTextFinder, findsOneWidget);
    final richText = tester.widget<RichText>(richTextFinder);
    expect(richText.overflow, isNot(TextOverflow.ellipsis));
  });
}

void _noop(CompletionSuggestion _) {}
