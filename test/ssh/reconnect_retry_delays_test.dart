// test/ssh/reconnect_retry_delays_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/reconnect_service.dart';

void main() {
  group('retry delay tables', () {
    test('default retry has 4 steps, monotonically increasing', () {
      final ds = ReconnectService.debugRetryDelays;
      expect(ds, hasLength(4));
      for (var i = 1; i < ds.length; i++) {
        expect(
          ds[i].inMilliseconds,
          greaterThan(ds[i - 1].inMilliseconds),
          reason: 'step $i must exceed step ${i - 1}',
        );
      }
      expect(ds.first.inMilliseconds, 50);
      expect(ds.last.inSeconds, 3);
    });

    test('fast retry has 3 steps, all shorter than default', () {
      final fast = ReconnectService.debugFastRetryDelays;
      final def = ReconnectService.debugRetryDelays;
      expect(fast, hasLength(3));
      for (var i = 0; i < fast.length; i++) {
        expect(
          fast[i].inMilliseconds,
          lessThanOrEqualTo(def[i].inMilliseconds),
        );
      }
    });

    test('total wait across all retry delays stays under 5s', () {
      final total = ReconnectService.debugRetryDelays
          .fold<int>(0, (a, d) => a + d.inMilliseconds);
      expect(total, lessThan(5000),
          reason: 'spending >5s in sleeps before any retry attempt = bad UX');
    });
  });
}
