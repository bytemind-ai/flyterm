import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/aqt/aqt_route.dart';
import 'package:flyterm/ssh/transport/transport.dart';
import 'package:flyterm/ui/home/home_screen.dart';

void main() {
  test('QUIC 服务器在本次运行中走 SSH 通道时显示 QUIC·SSH', () {
    expect(
      homeProtoLabel(
          transport: Transport.quic,
          isLocal: false,
          isLocalUnsupported: false,
          cachedRoute: AqtRoute.viaSsh),
      'QUIC·SSH',
    );
  });

  test('直连或尚未探测时仍是 QUIC；其它协议不受影响', () {
    String label(Transport t, [AqtRoute? r]) => homeProtoLabel(
        transport: t, isLocal: false, isLocalUnsupported: false, cachedRoute: r);
    expect(label(Transport.quic), 'QUIC');
    expect(label(Transport.quic, AqtRoute.direct), 'QUIC');
    expect(label(Transport.ssh, AqtRoute.viaSsh), 'SSH');
    expect(label(Transport.mosh), 'MOSH');
  });
}
