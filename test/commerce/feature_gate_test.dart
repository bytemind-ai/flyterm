// test/commerce/feature_gate_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/commerce/entitlement_service.dart';
import 'package:flyterm/commerce/feature_flags.dart';
import 'package:flyterm/commerce/feature_gate.dart';

/// 用最小化的 PaywallScreen stub 避免引入完整 PurchaseService/l10n。
class _StubPaywall extends StatelessWidget {
  const _StubPaywall({required this.triggerReason});
  final String triggerReason;
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Text('paywall:$triggerReason'));
}

/// 构建一个注入了 EntitlementService 的 Widget 树并返回 future 结果。
Widget _wrap({
  required EntitlementService ent,
  required Widget child,
}) {
  return MaterialApp(
    home: ChangeNotifierProvider<EntitlementService>.value(
      value: ent,
      child: child,
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('FeatureGate.isEntitled', () {
    testWidgets('returns true when isPro', (tester) async {
      final ent = EntitlementService();
      await ent.load();
      await ent.markPro(DateTime.now());

      late bool result;
      await tester.pumpWidget(
        _wrap(
          ent: ent,
          child: Builder(builder: (ctx) {
            result = FeatureGate.isEntitled(ctx);
            return const SizedBox();
          }),
        ),
      );
      expect(result, isTrue);
    });

    testWidgets('returns false when free', (tester) async {
      final ent = EntitlementService();
      await ent.load(); // free

      late bool result;
      await tester.pumpWidget(
        _wrap(
          ent: ent,
          child: Builder(builder: (ctx) {
            result = FeatureGate.isEntitled(ctx);
            return const SizedBox();
          }),
        ),
      );
      expect(result, isFalse);
      // IAP 语义；需 --dart-define=FLYTERM_ENABLE_IAP=true 才执行。
      // 注意 testWidgets 的 skip 是 bool?（不同于 test 的 dynamic），
      // 不能传原因字符串。
    }, skip: !kEnableInAppPurchase);
  });

  group('FeatureGate.checkOrShow', () {
    testWidgets('returns true immediately when already Pro', (tester) async {
      final ent = EntitlementService();
      await ent.load();
      await ent.markPro(DateTime.now());

      late Future<bool> resultFuture;
      await tester.pumpWidget(
        _wrap(
          ent: ent,
          child: Builder(builder: (ctx) {
            return ElevatedButton(
              onPressed: () {
                resultFuture = FeatureGate.checkOrShow(ctx, reason: 'test');
              },
              child: const Text('tap'),
            );
          }),
        ),
      );

      await tester.tap(find.text('tap'));
      await tester.pump();

      // Pro → 直接返回 true，不 push 任何路由
      expect(await resultFuture, isTrue);
      // 不应有 paywall 界面
      expect(find.textContaining('paywall:'), findsNothing);
    });
  });
}
