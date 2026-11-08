import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ssh/aqt/aqt_route.dart';
import 'package:flyterm/ssh/aqt/aqt_ssh_relay.dart';
import 'package:flyterm/ssh/aqt/aqt_transport_factory.dart';
import 'package:flyterm/ssh/transport/transport_factory.dart';

/// Pumps a zh-localized scaffold and returns a context inside it.
Future<BuildContext> _zhContext(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })),
  ));
  return ctx;
}

void main() {
  testWidgets('a wrapped relay failure is shown in the user language',
      (tester) async {
    final ctx = await _zhContext(tester);
    final e = TransportConnectException(
      'AQT connect failed',
      AqtRouteException(
          TimeoutException('udp'), const AqtRelayUnsupportedException()),
    );
    expect(AqtTransportFactory.describeConnectError(ctx, e),
        '服务端版本过旧，不支持 SSH 通道，请升级。');
  });

  testWidgets('a failed server upgrade is reported, not swallowed',
      (tester) async {
    final ctx = await _zhContext(tester);
    AqtTransportFactory.reportUpgradeFailure(
        ctx, Exception('Unable to load asset: VERSION'));
    await tester.pump();
    expect(find.textContaining('无法更新此服务器上的 FlyTerm Server'),
        findsOneWidget);
    expect(find.textContaining('Unable to load asset'), findsOneWidget);
  });

  testWidgets('reporting without a context does not throw', (tester) async {
    AqtTransportFactory.reportUpgradeFailure(null, Exception('x'));
  });
}
