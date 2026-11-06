import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/reconnect_service.dart';

void main() {
  group('classifyNetwork', () {
    test('all WiFi → wifi', () {
      expect(ReconnectService.classifyNetwork(
        [ConnectivityResult.wifi]), 'wifi');
    });
    test('cellular → cellular', () {
      expect(ReconnectService.classifyNetwork(
        [ConnectivityResult.mobile]), 'cellular');
    });
    test('vpn + wifi → vpn', () {
      expect(ReconnectService.classifyNetwork(
        [ConnectivityResult.vpn, ConnectivityResult.wifi]), 'vpn');
    });
    test('none / empty → none', () {
      expect(ReconnectService.classifyNetwork([]), 'none');
      expect(ReconnectService.classifyNetwork(
        [ConnectivityResult.none]), 'none');
    });
    test('repeat same type returns same string', () {
      final a = ReconnectService.classifyNetwork([ConnectivityResult.wifi]);
      final b = ReconnectService.classifyNetwork([ConnectivityResult.wifi]);
      expect(a, b);
    });
  });
}
