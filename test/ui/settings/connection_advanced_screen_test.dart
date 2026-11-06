import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/connection_advanced_screen.dart';

/// 高级连接页的**结构契约**。
///
/// 重点守「通知权限」这一行真的接进来了 —— 它是最容易被漏掉的：tile 组件
/// 写好了、单元测试也绿了，但页面里忘了挂，结果用户根本看不到。这种「组件
/// 存在但没人用」的差异只能靠宿主页面断言守住。
///
/// 权限查询本身在 tile 内部走 `NotificationService.permissionState()`，测试
/// 宿主（linux）上 `resolvePlatformSpecificImplementation` 返回 null，归约为
/// `unknown` —— 不断言具体状态，只断言这一行存在。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  late TerminalSettings settings;

  setUp(() async {
    settings = TerminalSettings(SecureStorageService());
  });

  testWidgets('高级连接页渲染通知权限行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider<TerminalSettings>.value(
        value: settings,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ConnectionAdvancedScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('通知权限'), findsOneWidget);
  });
}
