// test/commerce/entitlement_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/commerce/entitlement_service.dart';
import 'package:flyterm/commerce/feature_flags.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('EntitlementService - default state', () {
    test('starts as unknown before load', () {
      final s = EntitlementService();
      expect(s.status, EntitlementStatus.unknown);
      expect(s.isPro, false);
      expect(s.purchasedAt, null);
    });

    test('empty prefs → free after load', () async {
      final s = EntitlementService();
      await s.load();
      expect(s.status, EntitlementStatus.free);
      expect(s.isPro, false);
    },
        skip: kEnableInAppPurchase
            ? null
            : 'IAP 语义；需 --dart-define=FLYTERM_ENABLE_IAP=true');

    test('cached pro in prefs → pro after load', () async {
      SharedPreferences.setMockInitialValues({
        'entitlement.v1': 'pro|1700000000000',
      });
      final s = EntitlementService();
      await s.load();
      expect(s.status, EntitlementStatus.pro);
      expect(s.isPro, true);
      expect(s.purchasedAt, isNotNull);
    });
  });

  group('EntitlementService - mark flow', () {
    test('markPro persists and notifies', () async {
      final s = EntitlementService();
      await s.load();
      expect(s.isPro, false);

      var notified = 0;
      s.addListener(() => notified++);

      final ts = DateTime.now();
      await s.markPro(ts);
      expect(s.isPro, true);
      expect(s.purchasedAt?.millisecondsSinceEpoch, ts.millisecondsSinceEpoch);
      expect(notified, 1);

      final s2 = EntitlementService();
      await s2.load();
      expect(s2.isPro, true);
    },
        skip: kEnableInAppPurchase
            ? null
            : 'IAP 语义；需 --dart-define=FLYTERM_ENABLE_IAP=true');

    test('markFree resets and notifies', () async {
      final s = EntitlementService();
      await s.load();
      await s.markPro(DateTime.now());

      var notified = 0;
      s.addListener(() => notified++);
      await s.markFree();
      expect(s.isPro, false);
      expect(notified, 1);
    });

    test('markPro twice with same timestamp is idempotent', () async {
      final s = EntitlementService();
      await s.load();
      final ts = DateTime.now();
      await s.markPro(ts);

      var notified = 0;
      s.addListener(() => notified++);
      await s.markPro(ts);
      expect(notified, 0);
    });
  });
}
