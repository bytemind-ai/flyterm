// test/commerce/oss_defaults_test.dart
//
// 锁住「源码构建默认全解锁」这条语义。不传任何 --dart-define 时，本文件
// 全部通过；传 --dart-define=FLYTERM_ENABLE_IAP=true 时整个文件 skip
// （那是商店构建语义，由 test/commerce/ 下其余文件覆盖）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/commerce/entitlement_service.dart';
import 'package:flyterm/commerce/feature_flags.dart';
import 'package:flyterm/commerce/feature_gate.dart';
import 'package:flyterm/commerce/purchase_service.dart';

Widget _wrap({required EntitlementService ent, required Widget child}) {
  return MaterialApp(
    home: ChangeNotifierProvider<EntitlementService>.value(
      value: ent,
      child: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('开源构建默认态', () {
    test('kEnableInAppPurchase 默认为 false', () {
      expect(kEnableInAppPurchase, isFalse);
    });

    test('EntitlementService.load() 不读 prefs，直接进 Pro 态', () async {
      final ent = EntitlementService();
      await ent.load();
      expect(ent.isPro, isTrue);
      expect(ent.status, EntitlementStatus.pro);
    });

    // 这条断言有判别力，不是摆设：短路生效时 init() 立即返回；一旦短路失效，
    // 会走到 in_app_purchase 插件并抛
    // PlatformException(channel-error, ...startConnection)。
    test('PurchaseService.init() 短路，不触碰 IAP 插件', () async {
      final ent = EntitlementService();
      await ent.load();
      final svc = PurchaseService(entitlement: ent);
      await svc.init();
      expect(svc.isAvailable, isFalse);
    });

    testWidgets('FeatureGate.isEntitled 恒真', (tester) async {
      final ent = EntitlementService();
      await ent.load();

      late bool result;
      await tester.pumpWidget(_wrap(
        ent: ent,
        child: Builder(builder: (ctx) {
          result = FeatureGate.isEntitled(ctx);
          return const SizedBox();
        }),
      ));
      expect(result, isTrue);
    });

    testWidgets('FeatureGate.checkOrShow 直接放行，不弹 Paywall',
        (tester) async {
      final ent = EntitlementService();
      await ent.load();

      late Future<bool> resultFuture;
      await tester.pumpWidget(_wrap(
        ent: ent,
        child: Builder(builder: (ctx) {
          resultFuture = FeatureGate.checkOrShow(ctx, reason: 'test');
          return const SizedBox();
        }),
      ));
      await tester.pumpAndSettle();
      expect(await resultFuture, isTrue);
    });
  },
      skip: kEnableInAppPurchase
          ? '商店构建语义，由 test/commerce/ 其余文件覆盖'
          : null);
}
