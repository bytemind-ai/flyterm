import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/direct_chat_view.dart';
import 'package:flyterm/ui/ai/global_ai_screen.dart';

/// 没有配任何 provider 时必须退回 direct —— 这是现有行为，不能因为接上
/// agent 就让用户在没配模型的情况下看到一个空的 agent 视图。
Widget _app(SharedPreferences prefs) => MultiProvider(
      providers: [
        Provider<SharedPreferences>.value(value: prefs),
        ChangeNotifierProvider<AIProviderService>.value(
          value: AIProviderService(prefs),
        ),
        ChangeNotifierProvider<VoiceInputService>.value(
          value: VoiceInputService(),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GlobalAIScreen(),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('没配 provider 时仍走 direct，空状态照旧', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_app(prefs));
    await tester.pump();

    expect(find.text('有什么可以帮你？'), findsOneWidget);
    expect(find.byType(ActionChip), findsNWidgets(3));
  });

  testWidgets('没配 provider 时点 chip 仍进 DirectChatView', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_app(prefs));
    await tester.pump();

    await tester.tap(find.text('解释这段报错'));
    await tester.pump();

    expect(find.byType(DirectChatView), findsOneWidget);
  });
}
