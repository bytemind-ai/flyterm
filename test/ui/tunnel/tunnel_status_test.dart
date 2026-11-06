import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/tunnel/tunnel_entry.dart';
import 'package:flyterm/ui/design/fly_tokens.dart';
import 'package:flyterm/ui/tunnel/tunnel_status.dart';

Server _server() => Server(
      id: const Uuid().v4(),
      name: 's',
      host: 'h',
      port: 22,
      username: 'u',
      authType: 'password',
    );

TunnelEntry _entry(TunnelStatus status, {int retry = 0}) {
  final e = TunnelEntry(
    server: _server(),
    direction: TunnelDirection.local,
    localPort: 1,
    remoteHost: 'r',
    remotePort: 2,
    label: 't',
  );
  e.status = status;
  e.retryCount = retry;
  return e;
}

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

Finder _dotFade() => find.descendant(
      of: find.byType(TunnelStatusLabel),
      matching: find.byType(FadeTransition),
    );

void main() {
  group('tunnelStatusColor', () {
    test('四态映射到 FlyColors', () {
      expect(tunnelStatusColor(TunnelStatus.active), FlyColors.active);
      expect(tunnelStatusColor(TunnelStatus.connecting), FlyColors.pending);
      expect(tunnelStatusColor(TunnelStatus.error), FlyColors.danger);
      expect(tunnelStatusColor(TunnelStatus.stopped), FlyColors.textTertiary);
    });
  });

  group('tunnelStatusLabel', () {
    test('基本文案', () {
      expect(tunnelStatusLabel(_entry(TunnelStatus.active)), 'ACTIVE');
      expect(tunnelStatusLabel(_entry(TunnelStatus.connecting)), 'CONNECTING');
      expect(tunnelStatusLabel(_entry(TunnelStatus.error)), 'ERROR');
      expect(tunnelStatusLabel(_entry(TunnelStatus.stopped)), 'STOPPED');
    });

    test('error 达到最大重试 → FAILED', () {
      expect(
        tunnelStatusLabel(
            _entry(TunnelStatus.error, retry: TunnelEntry.maxRetries)),
        'FAILED',
      );
    });

    test('connecting 重试中 → RETRY n/max', () {
      expect(
        tunnelStatusLabel(_entry(TunnelStatus.connecting, retry: 2)),
        'RETRY 2/${TunnelEntry.maxRetries}',
      );
    });
  });

  testWidgets('静止态圆点全亮（不呼吸）', (tester) async {
    await tester.pumpWidget(_wrap(const TunnelStatusLabel(
      color: FlyColors.active,
      label: 'ACTIVE',
      breathing: false,
    )));
    final fade = tester.widget<FadeTransition>(_dotFade());
    expect(fade.opacity.value, 1.0);
  });

  testWidgets('connecting 时圆点呼吸（透明度随时间变化）', (tester) async {
    await tester.pumpWidget(_wrap(const TunnelStatusLabel(
      color: FlyColors.pending,
      label: 'CONNECTING',
      breathing: true,
    )));
    final o1 = tester.widget<FadeTransition>(_dotFade()).opacity.value;
    await tester.pump(const Duration(milliseconds: 400));
    final o2 = tester.widget<FadeTransition>(_dotFade()).opacity.value;
    expect((o1 - o2).abs() > 0.05, isTrue,
        reason: '呼吸动画应改变圆点透明度 o1=$o1 o2=$o2');

    // 切回静止 → 圆点动画停止且全亮（顺带验证 didUpdateWidget）。
    await tester.pumpWidget(_wrap(const TunnelStatusLabel(
      color: FlyColors.pending,
      label: 'CONNECTING',
      breathing: false,
    )));
    final o3 = tester.widget<FadeTransition>(_dotFade()).opacity.value;
    expect(o3, 1.0);
  });
}
