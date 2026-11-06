import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ui/settings/widgets/settings_section_header.dart';

void main() {
  Future<void> pump(WidgetTester tester, String label) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsSectionHeader(label)),
        ),
      );

  testWidgets('ASCII label 用 JetBrainsMono 且转大写', (tester) async {
    await pump(tester, 'documents');
    final txt = tester.widget<Text>(find.text('DOCUMENTS'));
    expect(txt.style?.fontFamily, 'JetBrainsMono');
    expect(txt.style?.letterSpacing, 1.2);
    expect(txt.style?.fontSize, 11);
  });

  testWidgets('CJK label 不转大写、不用等宽字体', (tester) async {
    await pump(tester, '文档');
    final txt = tester.widget<Text>(find.text('文档'));
    expect(txt.style?.fontFamily, isNull);
    expect(txt.style?.letterSpacing, 0);
  });

  testWidgets('中英混排（含非 ASCII）走 CJK 分支', (tester) async {
    // 「AI 设置」含全角空格/汉字 → _isAscii 为 false
    await pump(tester, 'AI 设置');
    final txt = tester.widget<Text>(find.text('AI 设置'));
    expect(txt.style?.fontFamily, isNull);
  });
}
