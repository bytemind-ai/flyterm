import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/data/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('TerminalSettings FET defaults', () {
    test('fetY defaults to 0.5', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.fetY, 0.5);
    });
    test('fetHidden defaults to false', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.fetHidden, false);
    });
    test('fetOpacity defaults to 0.6', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.fetOpacity, closeTo(0.6, 0.001));
    });
    test('fetAutoFade defaults to true', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.fetAutoFade, true);
    });
    test('fetEnabled defaults to true', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.fetEnabled, true);
    });
    test('fetOnboardingShown defaults to false', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.fetOnboardingShown, false);
    });
  });

  group('TerminalSettings FET clamping', () {
    test('setFetY clamps to [0.0, 1.0]', () async {
      final s = TerminalSettings(SecureStorageService());
      await s.setFetY(-0.5);
      expect(s.fetY, 0.0);
      await s.setFetY(1.5);
      expect(s.fetY, 1.0);
      await s.setFetY(0.3);
      expect(s.fetY, closeTo(0.3, 0.001));
    });

    test('setFetOpacity clamps to [0.4, 0.8]', () async {
      final s = TerminalSettings(SecureStorageService());
      await s.setFetOpacity(0.2);
      expect(s.fetOpacity, closeTo(0.4, 0.001));
      await s.setFetOpacity(0.9);
      expect(s.fetOpacity, closeTo(0.8, 0.001));
      await s.setFetOpacity(0.5);
      expect(s.fetOpacity, closeTo(0.5, 0.001));
    });
  });

  group('TerminalSettings FET persistence', () {
    test('round-trip via storage', () async {
      final storage = SecureStorageService();
      final s1 = TerminalSettings(storage);
      await s1.setFetY(0.75);
      await s1.setFetOpacity(0.7);
      await s1.setFetHidden(true);
      await s1.setFetAutoFade(false);
      await s1.setFetEnabled(false);
      await s1.setFetOnboardingShown(true);

      final s2 = TerminalSettings(storage);
      await s2.load();
      expect(s2.fetY, closeTo(0.75, 0.001));
      expect(s2.fetOpacity, closeTo(0.7, 0.001));
      expect(s2.fetHidden, true);
      expect(s2.fetAutoFade, false);
      expect(s2.fetEnabled, false);
      expect(s2.fetOnboardingShown, true);
    });

    test('missing storage keys use defaults', () async {
      final s = TerminalSettings(SecureStorageService());
      await s.load(); // storage is empty (setUp clears it)
      expect(s.fetY, 0.5);
      expect(s.fetHidden, false);
      expect(s.fetAutoFade, true);
      expect(s.fetEnabled, true);
    });
  });
}
