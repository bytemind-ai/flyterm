import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/agent_skill_manager.dart';
import 'package:flyterm/ai/agent/server_notes_manager.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/agent_settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late AgentSessionManager mgr;
  late AgentSkillManager skills;
  late ServerNotesManager notes;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // db 在 setUp 里 await，**不在 testWidgets 内** —— widget test 里 await
  // sqflite 会挂死十分钟而非报错（见项目既有教训）。
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    mgr = AgentSessionManager(await SharedPreferences.getInstance());
    skills = AgentSkillManager(AgentSkillRepository(db));
    // hub 的「助手记忆」行读 ServerNotesManager 的条数（2026-10-14 拆分后
    // 新增依赖），这个文件的焦点是权限档，起一个空笔记库即可。
    notes = ServerNotesManager(ServerNotesRepository(db));
    await notes.load();
  });

  tearDown(() async => db.close());

  Widget wrap() => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: mgr),
          ChangeNotifierProvider.value(value: skills),
          ChangeNotifierProvider.value(value: notes),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AgentSettingsScreen(),
        ),
      );

  Future<void> bigViewport(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => t.binding.setSurfaceSize(null));
  }

  testWidgets('默认选中「先问我」', (t) async {
    await bigViewport(t);
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();
    expect(mgr.defaultMode, PermissionMode.ask);
    expect(find.byKey(const Key('mode-seg-ask')), findsOneWidget);
  });

  testWidgets('页顶不再有状态横幅 —— 选中态承担了状态展示', (t) async {
    await bigViewport(t);
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    // 原 _StatusBanner 的三条标题都不该出现
    expect(find.text(l.agentBannerAskTitle), findsNothing);
    expect(find.text(l.agentBannerPlanTitle), findsNothing);
    expect(find.text(l.agentBannerBypassTitle), findsNothing);
  });

  testWidgets('点「全放行」弹二次确认，取消后档位不变', (t) async {
    await bigViewport(t);
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('mode-seg-bypass')));
    await t.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(mgr.defaultMode, PermissionMode.ask, reason: '取消后不该改档');
  });

  testWidgets('点「只读」不弹对话框', (t) async {
    await bigViewport(t);
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('mode-seg-readOnly')));
    await t.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(mgr.defaultMode, PermissionMode.readOnly);
  });

  testWidgets('切档后说明文字跟着变', (t) async {
    await bigViewport(t);
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l.agentPermAskDesc), findsOneWidget);

    await t.tap(find.byKey(const Key('mode-seg-readOnly')));
    await t.pumpAndSettle();
    expect(find.text(l.agentPermReadOnlyDesc), findsOneWidget);
    expect(find.text(l.agentPermAskDesc), findsNothing);
  });

  testWidgets('不再有独立的 App 控制节', (t) async {
    await bigViewport(t);
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l.appControlSection), findsNothing);
    expect(find.byKey(const Key('app-mode-ask')), findsNothing);
  });
}
