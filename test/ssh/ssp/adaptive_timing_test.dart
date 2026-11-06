import 'package:flutter_test/flutter_test.dart';

// Mirror the formulas from SspTransport. These tests define the contract;
// the implementation in ssp_transport.dart must match exactly.

int _ackDelayMs(int srttMs) => (srttMs ~/ 4).clamp(10, 50);
int _retransmitPollMs(int srttMs) => (srttMs ~/ 2).clamp(50, 200);
int _flushDelayMs(Duration sinceLastRx) =>
    sinceLastRx < const Duration(milliseconds: 10) ? 16 : 4;

void main() {
  group('ACK debounce formula', () {
    test('srttMs=0 → clamp to 10ms', () => expect(_ackDelayMs(0), 10));
    test('srttMs=20 → 5ms → clamp to 10ms', () => expect(_ackDelayMs(20), 10));
    test('srttMs=40 → 10ms (boundary)', () => expect(_ackDelayMs(40), 10));
    test('srttMs=100 → 25ms', () => expect(_ackDelayMs(100), 25));
    test('srttMs=200 → 50ms (ceiling)', () => expect(_ackDelayMs(200), 50));
    test('srttMs=400 → 50ms (clamped)', () => expect(_ackDelayMs(400), 50));
  });

  group('Retransmit poll formula', () {
    test('srttMs=0 → clamp to 50ms', () => expect(_retransmitPollMs(0), 50));
    test('srttMs=40 → 20ms → clamp to 50ms', () => expect(_retransmitPollMs(40), 50));
    test('srttMs=100 → 50ms (boundary)', () => expect(_retransmitPollMs(100), 50));
    test('srttMs=200 → 100ms', () => expect(_retransmitPollMs(200), 100));
    test('srttMs=400 → 200ms (ceiling)', () => expect(_retransmitPollMs(400), 200));
    test('srttMs=600 → 200ms (clamped)', () => expect(_retransmitPollMs(600), 200));
  });

  group('Output flush mode', () {
    test('gap=5ms → burst → 16ms', () =>
        expect(_flushDelayMs(const Duration(milliseconds: 5)), 16));
    test('gap=9ms → burst (below threshold) → 16ms', () =>
        expect(_flushDelayMs(const Duration(milliseconds: 9)), 16));
    test('gap=10ms → interactive (at threshold) → 4ms', () =>
        expect(_flushDelayMs(const Duration(milliseconds: 10)), 4));
    test('gap=50ms → interactive → 4ms', () =>
        expect(_flushDelayMs(const Duration(milliseconds: 50)), 4));
    test('gap=500ms → interactive → 4ms', () =>
        expect(_flushDelayMs(const Duration(milliseconds: 500)), 4));
  });
}
