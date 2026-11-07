import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/commerce/entitlement_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/ssh_key_repository.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/design/fly_tokens.dart';
import 'package:flyterm/ui/home/server_form_screen.dart';

/// 「始终走 SSH 通道」打开后，「UDP 端口」字段不再出现 —— 端口段对经由
/// SSH 通道的连接没有意义，留着只会让人以为还需要放行 UDP。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('打开「始终走 SSH 通道」后隐藏「UDP 端口」', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: ServerRepository(db)),
          Provider.value(value: SSHKeyRepository(db)),
          Provider.value(value: SecureStorageService()),
          ChangeNotifierProvider.value(value: EntitlementService()),
          ChangeNotifierProvider.value(value: AIProviderService(prefs)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildFlyTermTheme(),
          home: const ServerFormScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('UDP ports'), findsOneWidget);
    final toggle = find.text('Always use the SSH channel');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('UDP ports'), findsNothing);
  });
}
