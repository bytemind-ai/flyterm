// test/ssh/reconnect_timeout_layered_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/reconnect_service.dart';

void main() {
  group('selectReconnectTimeout', () {
    test('first attempt → fast 15 s', () {
      expect(
        ReconnectService.debugSelectReconnectTimeout(firstAttempt: true),
        const Duration(seconds: 15),
      );
    });

    test('subsequent attempts → default 30 s', () {
      expect(
        ReconnectService.debugSelectReconnectTimeout(firstAttempt: false),
        const Duration(seconds: 30),
      );
    });

    test('both budgets are well under the legacy 90 s', () {
      final f = ReconnectService.debugSelectReconnectTimeout(firstAttempt: true);
      final d = ReconnectService.debugSelectReconnectTimeout(firstAttempt: false);
      expect(f.inSeconds, lessThan(90));
      expect(d.inSeconds, lessThan(90));
    });
  });
}
