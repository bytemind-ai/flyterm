import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/reconnect_service.dart';

void main() {
  group('Seamless recovery constants', () {
    test('probe wait is 150 ms', () {
      expect(
        ReconnectService.kProbeWaitDuration,
        const Duration(milliseconds: 150),
      );
    });

    test('banner delay is 1500 ms', () {
      expect(
        ReconnectService.kBannerDelay,
        const Duration(milliseconds: 1500),
      );
    });
  });
}
