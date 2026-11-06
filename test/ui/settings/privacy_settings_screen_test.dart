import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Database;

import 'package:flyterm/consent/consent_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/keybar_settings.dart';
import 'package:flyterm/data/repositories/ai_provider_repository.dart';
import 'package:flyterm/data/repositories/favorite_command_repository.dart';
import 'package:flyterm/data/repositories/known_host_repository.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/repositories/ssh_key_repository.dart';
import 'package:flyterm/data/repositories/tunnel_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/privacy_settings_screen.dart';

/// 数据与隐私子页结构测试。
///
/// 2026-10-07 重排把首页「数据与隐私」段的 8 项收进本子页，并移出两项：
///   • 生物识别锁 → 安全子页（它是设备安全，不是隐私）
///   • 开源许可   → 关于页（语义归「关于本 app」）
/// 本文件锚定这两项**确实不在**本页，防止回归。
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
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<ConsentManager>.value(value: ConsentManager()),
        ChangeNotifierProvider<TerminalSettings>.value(
            value: TerminalSettings(SecureStorageService())),
        ChangeNotifierProvider<KeybarSettings>.value(value: KeybarSettings()),
        Provider<ServerRepository>(create: (_) => ServerRepository(db)),
        Provider<SSHKeyRepository>(create: (_) => SSHKeyRepository(db)),
        Provider<FavoriteCommandRepository>(
            create: (_) => FavoriteCommandRepository(db)),
        Provider<AIProviderRepository>(create: (_) => AIProviderRepository(db)),
        Provider<TunnelRepository>(create: (_) => TunnelRepository(db)),
        Provider<KnownHostRepository>(create: (_) => KnownHostRepository(db)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const PrivacySettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('渲染数据段与隐私段', (tester) async {
    await pump(tester);
    // 数据段：下载目录 + 配置备份（导出/导入两行）
    expect(find.text('下载目录'), findsOneWidget);
    expect(find.text('导出配置'), findsOneWidget);
    expect(find.text('导入配置'), findsOneWidget);
    // 隐私段：遥测开关 + 文档入口
    expect(find.text('崩溃报告'), findsOneWidget);
    expect(find.text('查看隐私政策'), findsOneWidget);
  });

  testWidgets('不再包含开源许可（已移至关于页）', (tester) async {
    await pump(tester);
    expect(find.text('开源许可'), findsNothing);
  });

  testWidgets('不再包含生物识别锁（已移至安全子页）', (tester) async {
    await pump(tester);
    expect(find.text('生物识别锁'), findsNothing);
  });
}
