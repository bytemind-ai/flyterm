// test/consent/consent_manager_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/consent/consent_manager.dart';
import 'package:flyterm/consent/consent_policy.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ConsentManager - default state', () {
    test('not agreed before load', () {
      final m = ConsentManager();
      expect(m.agreed, false);
      expect(m.needsConsent, true);
      expect(m.crashReportingEnabled, true);
      expect(m.analyticsEnabled, true);
    });

    test('not agreed after load with empty prefs', () async {
      final m = ConsentManager();
      await m.load();
      expect(m.agreed, false);
      expect(m.needsConsent, true);
    });
  });

  group('ConsentManager - accept flow', () {
    test('accept marks agreed and persists', () async {
      final m = ConsentManager();
      await m.load();
      expect(m.needsConsent, true);

      await m.accept();
      expect(m.agreed, true);
      expect(m.agreedVersion, ConsentPolicy.currentVersion);
      expect(m.agreedAt, isNotNull);
      expect(m.needsConsent, false);

      // 重新 load 验证持久化
      final m2 = ConsentManager();
      await m2.load();
      expect(m2.agreed, true);
      expect(m2.needsConsent, false);
    });

    test('version bump triggers needsConsent again', () async {
      SharedPreferences.setMockInitialValues({
        'consent.v1': 'true|v0|1700000000000|true|true',
      });
      final m = ConsentManager();
      await m.load();
      expect(m.agreed, true);
      expect(m.agreedVersion, 'v0');
      expect(m.needsConsent, true); // currentVersion='v1' != 'v0'
    });

    test('revoke resets all flags', () async {
      final m = ConsentManager();
      await m.load();
      await m.accept();
      await m.revoke();
      expect(m.agreed, false);
      expect(m.crashReportingEnabled, false);
      expect(m.analyticsEnabled, false);
    });

    test('toggle crash reporting persists', () async {
      final m = ConsentManager();
      await m.load();
      await m.accept();
      await m.setCrashReportingEnabled(false);
      expect(m.crashReportingEnabled, false);

      final m2 = ConsentManager();
      await m2.load();
      expect(m2.crashReportingEnabled, false);
    });
  });
}
