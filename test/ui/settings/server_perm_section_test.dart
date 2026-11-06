import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/widgets/mode_segmented.dart';
import 'package:flyterm/ui/settings/widgets/server_perm_section.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AgentSessionManager mgr;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mgr = AgentSessionManager(await SharedPreferences.getInstance());
  });

  const serverId = 'srv-test';

  Widget wrap() => ChangeNotifierProvider.value(
        value: mgr,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ServerPermSection(serverId: serverId),
          ),
        ),
      );

  testWidgets('默认跟随全局，分段置灰', (t) async {
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();

    expect(mgr.modeOverrideFor(serverId), isNull);
    // 置灰时点击无效
    final before = mgr.defaultMode;
    await t.tap(find.byKey(const Key('mode-seg-bypass')));
    await t.pumpAndSettle();
    expect(mgr.modeOverrideFor(serverId), isNull);
    expect(mgr.defaultMode, before, reason: '跟随态下点击不该改任何东西');
  });

  testWidgets('关掉跟随 → 分段可点 → 写入覆盖', (t) async {
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('server-perm-follow-switch')));
    await t.pumpAndSettle();
    expect(mgr.modeOverrideFor(serverId), isNot(null),
        reason: '关掉跟随应立刻写入一个具体档');

    await t.tap(find.byKey(const Key('mode-seg-bypass')));
    await t.pumpAndSettle();
    // bypass 会弹确认
    expect(find.byType(AlertDialog), findsOneWidget);
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(mgr.modeOverrideFor(serverId), PermissionMode.bypass);
  });

  testWidgets('重新打开跟随 → 清除覆盖', (t) async {
    SharedPreferences.setMockInitialValues({'agent_mode_$serverId': 'bypass'});
    mgr = AgentSessionManager(await SharedPreferences.getInstance());

    await t.pumpWidget(wrap());
    await t.pumpAndSettle();
    expect(mgr.modeOverrideFor(serverId), PermissionMode.bypass);

    await t.tap(find.byKey(const Key('server-perm-follow-switch')));
    await t.pumpAndSettle();

    expect(mgr.modeOverrideFor(serverId), isNull, reason: '选「跟随」= 清除覆盖');
    expect(find.byType(ModeSegmented), findsOneWidget,
        reason: '跟随态仍显示分段（置灰），用户要看到自己在跟随什么');
  });
}
