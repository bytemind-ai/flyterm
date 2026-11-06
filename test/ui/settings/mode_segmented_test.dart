import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/widgets/mode_segmented.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      );

  testWidgets('三档都渲染', (t) async {
    await t.pumpWidget(wrap(ModeSegmented(
      value: PermissionMode.ask,
      onChanged: (_) {},
    )));
    await t.pumpAndSettle();
    // 三个段位各自的 Key
    for (final m in PermissionMode.values) {
      expect(find.byKey(Key('mode-seg-${m.name}')), findsOneWidget);
    }
  });

  testWidgets('点击触发 onChanged 并带正确值', (t) async {
    PermissionMode? got;
    await t.pumpWidget(wrap(ModeSegmented(
      value: PermissionMode.ask,
      onChanged: (v) => got = v,
    )));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('mode-seg-bypass')));
    await t.pumpAndSettle();
    expect(got, PermissionMode.bypass);
  });

  testWidgets('enabled=false 时点击不触发 onChanged', (t) async {
    var called = false;
    await t.pumpWidget(wrap(ModeSegmented(
      value: PermissionMode.ask,
      enabled: false,
      onChanged: (_) => called = true,
    )));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('mode-seg-bypass')));
    await t.pumpAndSettle();
    expect(called, isFalse);
  });

  testWidgets('只显示当前档的说明文字', (t) async {
    await t.pumpWidget(wrap(ModeSegmented(
      value: PermissionMode.readOnly,
      onChanged: (_) {},
    )));
    await t.pumpAndSettle();
    // 只读档的说明出现，另两档的说明不出现
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l.agentPermReadOnlyDesc), findsOneWidget);
    expect(find.text(l.agentPermAskDesc), findsNothing);
    expect(find.text(l.agentPermBypassDesc), findsNothing);
  });
}
