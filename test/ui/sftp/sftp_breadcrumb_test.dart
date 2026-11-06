import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/sftp/sftp_breadcrumb.dart';

void main() {
  group('segmentsOf', () {
    test('根目录', () {
      final s = SftpBreadcrumb.segmentsOf('/');
      expect(s.length, 1);
      expect(s.single.label, '/');
    });

    test('深路径逐段累积绝对路径', () {
      final s = SftpBreadcrumb.segmentsOf('/var/log/nginx');
      expect(s.map((e) => e.label).toList(), ['/', 'var', 'log', 'nginx']);
      expect(
        s.map((e) => e.path).toList(),
        ['/', '/var', '/var/log', '/var/log/nginx'],
      );
    });

    test('尾部斜杠不产生空段', () {
      final s = SftpBreadcrumb.segmentsOf('/var/log/');
      expect(s.map((e) => e.label).toList(), ['/', 'var', 'log']);
    });
  });

  testWidgets('点中间段回调该段的绝对路径，点当前段不回调', (tester) async {
    String? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SftpBreadcrumb(
            path: '/var/log',
            onSegmentTap: (p) => tapped = p,
          ),
        ),
      ),
    );
    await tester.tap(find.text('var'));
    expect(tapped, '/var');
    tapped = null;
    await tester.tap(find.text('log'));
    expect(tapped, isNull, reason: '当前段不可点');
  });

  // ── 回归：「上一级」必须随时可达 ──────────────────────────────────────
  testWidgets('根目录下没有「上一级」按钮', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SftpBreadcrumb(path: '/', onSegmentTap: (_) {}),
      ),
    ));
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
  });

  testWidgets('非根目录有常驻「上一级」按钮，点了能到父目录', (tester) async {
    String? tapped;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SftpBreadcrumb(
          path: '/var/log/nginx',
          onSegmentTap: (p) => tapped = p,
        ),
      ),
    ));
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    expect(tapped, '/var/log');
  });

  testWidgets('深路径下当前目录滚进可见范围（否则用户点不到它，会以为没反应）',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SftpBreadcrumb(
          path: '/very/deep/nested/directory/structure/leaf',
          onSegmentTap: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // 末尾段（当前目录）必须真的可见
    final leaf = find.text('leaf');
    expect(leaf, findsOneWidget);
    final rect = tester.getRect(leaf);
    final screen = tester.getRect(find.byType(SftpBreadcrumb));
    expect(rect.left, greaterThanOrEqualTo(screen.left - 0.1));
    expect(rect.right, lessThanOrEqualTo(screen.right + 0.1),
        reason: '当前段不该停在屏幕外');
  });
}
