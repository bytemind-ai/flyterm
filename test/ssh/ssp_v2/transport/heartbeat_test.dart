import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/transport/heartbeat.dart';

void main() {
  test('initial interval is SEND_INTERVAL_MIN', () {
    final h = Heartbeat();
    expect(h.currentInterval, Heartbeat.kSendIntervalMin);
    expect(h.currentInterval.inMilliseconds, 20);
  });

  test('updateSrtt clamps to [MIN, MAX]', () {
    final h = Heartbeat();
    h.updateSrtt(const Duration(milliseconds: 10));
    expect(h.currentInterval, Heartbeat.kSendIntervalMin);

    h.updateSrtt(const Duration(seconds: 5));
    expect(h.currentInterval, Heartbeat.kSendIntervalMax);
  });

  test('updateSrtt within range yields half RTT', () {
    final h = Heartbeat();
    h.updateSrtt(const Duration(milliseconds: 200));
    expect(h.currentInterval.inMilliseconds, 100);
  });

  test('ack interval is exactly 3000ms', () {
    expect(Heartbeat.kAckInterval.inMilliseconds, 3000);
  });
}
