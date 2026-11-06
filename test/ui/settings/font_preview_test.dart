import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/settings/font_preview.dart';

/// The sample-code [Text], located by content.
///
/// `find.byType(Text).first` used to be used here, but FontPreview renders the
/// family-name label above the sample and that label carries no fontFamily —
/// so every assertion below saw `null`. Matching on content survives further
/// changes to the widget tree.
Text _sample(WidgetTester tester) =>
    tester.widget<Text>(find.textContaining('const x = 42;'));

Future<void> _pump(
  WidgetTester tester, {
  required String fontFamily,
  required double fontSize,
  required double height,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FontPreview(
          fontFamily: fontFamily,
          fontSize: fontSize,
          height: height,
        ),
      ),
    ));

void main() {
  testWidgets('renders sample text in given fontFamily + fontSize + height',
      (tester) async {
    await _pump(tester, fontFamily: 'JetBrainsMono', fontSize: 16, height: 1.4);
    final txt = _sample(tester);
    expect(txt.style?.fontFamily, 'JetBrainsMono');
    expect(txt.style?.fontSize, 16);
    expect(txt.style?.height, 1.4);
  });

  testWidgets('system fontFamily maps to "monospace" (matches TerminalWidget)',
      (tester) async {
    await _pump(tester, fontFamily: 'system', fontSize: 14, height: 1.2);
    expect(_sample(tester).style?.fontFamily, 'monospace');
  });

  testWidgets('fallback chain includes Noto symbols', (tester) async {
    await _pump(tester, fontFamily: 'JetBrainsMono', fontSize: 14, height: 1.2);
    expect(
        _sample(tester).style?.fontFamilyFallback, contains('NotoSansSymbols2'));
  });

  testWidgets('monospaced symbol font precedes the proportional one',
      (tester) async {
    // Regression guard. NotoSansSymbols2 is proportional: ☐/☒ (U+2610/U+2612)
    // are 0.821 em and ✔ (U+2714) is 0.930 em, against a 0.600 em cell. When
    // it wins the fallback race those glyphs overflow and get clipped —
    // Claude Code's `☒ … ☐ … ✔ Submit` header bar rendered as ⌧/⌐ garbage.
    // DejaVuSansMono carries the same coverage at a uniform 0.602 em, so it
    // has to come first. Order here, not mere membership, is the fix.
    await _pump(tester, fontFamily: 'JetBrainsMono', fontSize: 14, height: 1.2);
    final chain = _sample(tester).style?.fontFamilyFallback;
    expect(chain, isNotNull);
    expect(chain, contains('DejaVuSansMono'));
    expect(
      chain!.indexOf('DejaVuSansMono'),
      lessThan(chain.indexOf('NotoSansSymbols2')),
      reason: 'DejaVuSansMono must outrank NotoSansSymbols2 — see comment',
    );
  });

  testWidgets('sample text exercises the symbols that used to clip',
      (tester) async {
    // These are the exact codepoints neither primary font covers, so they are
    // the ones that go through the fallback chain. Keeping them in the preview
    // makes the settings screen a spot-check: if the chain regresses, the
    // clipping is visible there without reproducing it in a live session.
    await _pump(tester, fontFamily: 'JetBrainsMono', fontSize: 14, height: 1.2);
    final data = _sample(tester).data!;
    for (final ch in ['☐', '☒', '✔']) {
      expect(
        data,
        contains(ch),
        reason: 'preview should render U+${ch.codeUnitAt(0).toRadixString(16)}',
      );
    }
  });
}
