// PanelInputRow 的回归测试。
//
// 这个文件原本覆盖麦克风按钮的命中区、位置，以及语音失败路径的可见性。
// 语音输入已于 2026-10 从面板整体移除（见 `PanelInputRow` 的类文档），那批
// 用例随之删除——`lib/ui/voice/voice_input_prompt.dart` 本身的失败反馈仍由
// `test/ui/voice/voice_input_prompt_test.dart` 覆盖，映射关系没有断。
//
// 现在这里守两件事：
//   1. 输入行不再渲染麦克风（防止有人回头把按钮加回来）。
//   2. 附件按钮仍然「灰但可点」——置灰不能退化成 `onPressed: null`，否则
//      用户永远读不到原因（tooltip 在手机上要长按才出）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/panel_chrome.dart';

Widget _wrap(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('输入行不再渲染麦克风', (tester) async {
    await tester.pumpWidget(
      _wrap(PanelInputRow(ctrl: TextEditingController(), onSubmit: () {})),
    );
    await tester.pump();

    expect(find.byKey(const Key('panelInputRow.micHitArea')), findsNothing);
    expect(find.byIcon(Icons.mic_none), findsNothing);
    expect(find.byIcon(Icons.mic_off), findsNothing);
    expect(find.byIcon(Icons.mic), findsNothing);

    // 麦克风也不该改头换面藏进输入框内部。
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.decoration?.suffixIcon, isNull);
  });

  testWidgets('附件按钮置灰时仍然可点 —— 点下去要能说清为什么', (tester) async {
    var blockedTaps = 0;
    await tester.pumpWidget(
      _wrap(
        PanelInputRow(
          ctrl: TextEditingController(),
          onSubmit: () {},
          onAttachTap: () {},
          attachEnabled: false,
          onAttachBlockedTap: () => blockedTaps++,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();

    expect(
      blockedTaps,
      1,
      reason: '置灰不能退化成 onPressed: null —— tooltip 在手机上要长按，'
          '点一下没反应与「App 坏了」无法区分',
    );
  });

  testWidgets('没有 onAttachTap 时不渲染附件按钮', (tester) async {
    await tester.pumpWidget(
      _wrap(PanelInputRow(ctrl: TextEditingController(), onSubmit: () {})),
    );
    await tester.pump();

    expect(find.byIcon(Icons.attach_file), findsNothing);
  });

  testWidgets('提交按钮始终在，enabled=false 时置灰', (tester) async {
    await tester.pumpWidget(
      _wrap(
        PanelInputRow(
          ctrl: TextEditingController(),
          onSubmit: () {},
          enabled: false,
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.send), findsOneWidget);
  });
}
