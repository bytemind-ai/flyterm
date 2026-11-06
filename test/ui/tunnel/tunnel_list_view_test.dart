import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/tunnel/tunnel_manager.dart';
import 'package:flyterm/ui/tunnel/tunnel_list_screen.dart';

void main() {
  testWidgets('TunnelListView 空态可无 Scaffold 嵌入', (tester) async {
    final mgr = TunnelManager(); // 无 repo：不加载任何条目
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider<TunnelManager>.value(value: mgr)],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: TunnelListView()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('暂无隧道'), findsOneWidget);
  });

  testWidgets('TunnelListScreen 自带 AppBar 与新建 FAB', (tester) async {
    final mgr = TunnelManager();
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider<TunnelManager>.value(value: mgr)],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: TunnelListScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('隧道'), findsOneWidget);
    expect(find.text('新建隧道'), findsWidgets);
  });
}
