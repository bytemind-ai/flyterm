import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_install_dialog.dart';

void main() {
  testWidgets('Install button returns AqtInstallChoice.install', (tester) async {
    AqtInstallChoice? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await showAqtInstallDialog(ctx),
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('安装'), findsOneWidget);
    await tester.tap(find.text('安装'));
    await tester.pumpAndSettle();
    expect(result, AqtInstallChoice.install);
  });

  testWidgets('"稍后" returns postpone', (tester) async {
    AqtInstallChoice? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await showAqtInstallDialog(ctx),
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(result, AqtInstallChoice.postpone);
  });
}
