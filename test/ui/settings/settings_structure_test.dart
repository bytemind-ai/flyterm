import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Database;

import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/consent/consent_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/keybar_settings.dart';
import 'package:flyterm/data/repositories/ai_provider_repository.dart';
import 'package:flyterm/data/repositories/favorite_command_repository.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/repositories/ssh_key_repository.dart';
import 'package:flyterm/data/repositories/tunnel_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/settings_screen.dart';

/// 设置首页结构测试。
///
/// 2026-10-07 重排后首页是 8 段 / 13 行的领域分段结构。本文件锚定三件事：
///   1. 段头集合与顺序 —— 防止有人把段合并/重排回去
///   2. 迁走的东西**确实不在首页** —— 防止回归（同类控件又摊回首页）
///   3. 首页唯一的内联开关（命令补全）仍在 —— 它是 D7 的例外，不是遗漏
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  late Database db;
  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
  });
  tearDown(() async {
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final storage = SecureStorageService();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<ConsentManager>.value(value: ConsentManager()),
        ChangeNotifierProvider<TerminalSettings>.value(
            value: TerminalSettings(storage)),
        ChangeNotifierProvider<AIProviderService>.value(
            value: AIProviderService(prefs)),
        ChangeNotifierProvider<AgentSessionManager>.value(
            value: AgentSessionManager(prefs)),
        ChangeNotifierProvider<KeybarSettings>.value(
            value: KeybarSettings()),
        Provider<SecureStorageService>.value(value: storage),
        Provider<ServerRepository>(create: (_) => ServerRepository(db)),
        Provider<SSHKeyRepository>(create: (_) => SSHKeyRepository(db)),
        Provider<FavoriteCommandRepository>(
            create: (_) => FavoriteCommandRepository(db)),
        Provider<AIProviderRepository>(create: (_) => AIProviderRepository(db)),
        Provider<TunnelRepository>(create: (_) => TunnelRepository(db)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('8 个段头按序存在', (tester) async {
    await pump(tester);
    const expected = ['外观', '输入', '连接', '安全', 'AI', '数据与隐私', '关于'];
    final ys = <double>[];
    for (final label in expected) {
      final f = find.text(label);
      expect(f, findsWidgets, reason: '缺少段头「$label」');
      ys.add(tester.getTopLeft(f.first).dy);
    }
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]),
          reason: '段头「${expected[i]}」应排在「${expected[i - 1]}」之后');
    }
  });

  testWidgets('外观控件已移出首页（进外观子页）', (tester) async {
    await pump(tester);
    expect(find.text('终端主题'), findsNothing);
    expect(find.text('光标样式'), findsNothing);
    expect(find.text('代码字体'), findsNothing);
    expect(find.text('行间距'), findsNothing);
  });

  testWidgets('危险命令保护已移出首页（进安全子页）', (tester) async {
    await pump(tester);
    expect(find.text('危险命令保护'), findsNothing);
  });

  testWidgets('生物识别锁已移出首页（进安全子页）', (tester) async {
    await pump(tester);
    expect(find.text('生物识别锁'), findsNothing);
  });

  testWidgets('命令补全作为唯一内联开关保留在首页', (tester) async {
    await pump(tester);
    expect(find.widgetWithText(SwitchListTile, '命令补全'), findsOneWidget);
  });

  testWidgets('导航行的 subtitle 反映当前设置值（动态 subtitle）', (tester) async {
    await pump(tester);
    // 默认值：SSH 压缩开、后台保活关
    expect(find.text('压缩 开 · 保活 关'), findsOneWidget);
  });

  testWidgets('首页不再有隧道行', (tester) async {
    await pump(tester);
    expect(find.widgetWithText(ListTile, '隧道'), findsNothing);
  });

}
