import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/consent/consent_manager.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/legal/consent_first_run_screen.dart';

/// Regression test for the "同意协议后点确定 → 纯黑" bug.
///
/// ConsentFirstRunScreen is NOT a pushed route — it is the *content* of the
/// app's single initial route (a Consumer<ConsentManager> in app.dart). The
/// designed transition is: accept() → notifyListeners() → Consumer rebuilds →
/// needsConsent==false → HomeScreen. Any Navigator.pop() inside _onAccept pops
/// that single route, leaving an empty Navigator → a pure-black screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'tapping Continue transitions to home instead of emptying the navigator',
    (tester) async {
      // The consent screen is tall; the primary button sits below the fold of
      // the default 800×600 test viewport, so give it a phone-sized surface.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // ConsentFirstRunScreen._onAccept mutates the SINGLETON
      // ConsentManager.instance (matching main.dart, which provides the same
      // singleton). Use and reset it so the Consumer and the screen agree.
      final consent = ConsentManager.instance;
      await consent.revoke(); // reset to a clean not-agreed state
      expect(consent.needsConsent, true);

      // Mirror app.dart's onGenerateInitialRoutes default branch: a single
      // route whose content is the Consumer that swaps consent → home.
      await tester.pumpWidget(
        ChangeNotifierProvider<ConsentManager>.value(
          value: consent,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            // Single-route navigator, exactly like app.dart's initial route:
            // the Consumer swaps consent → home in place. Popping this route
            // would empty the navigator (the black-screen bug).
            home: Consumer<ConsentManager>(
              builder: (context, manager, _) {
                if (manager.needsConsent) {
                  return const ConsentFirstRunScreen();
                }
                return const Scaffold(body: Text('HOME_MARKER'));
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Consent screen is shown first.
      expect(find.byType(ConsentFirstRunScreen), findsOneWidget);
      expect(find.text('HOME_MARKER'), findsNothing);

      // Tap the "Agree and Continue" primary button.
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      // After accepting, the Consumer must have rebuilt into the home marker.
      // If _onAccept pops the (only) route, the navigator is emptied and the
      // marker never appears — this is the black-screen regression.
      expect(consent.needsConsent, false);
      expect(find.byType(ConsentFirstRunScreen), findsNothing);
      expect(find.text('HOME_MARKER'), findsOneWidget);
    },
  );
}
