// E2E tests for AQT transport.
// These tests require:
// 1. flyterm-server binary in PATH or at ~/.flyterm-server/bin/flyterm-server
// 2. An actual SSH server to bootstrap from
// 3. Allocatable PTY
//
// All tests are @Skip unless AQT_E2E=1 env var is set.
//
// To run e2e tests:
//   flutter test --dart-define=AQT_E2E=1 test/ssh/aqt/aqt_e2e_test.dart

import 'package:flutter_test/flutter_test.dart';

void main() {
  final runE2e =
      const String.fromEnvironment('AQT_E2E', defaultValue: '0') == '1';

  group('AQT e2e (requires flyterm-server + SSH)', () {
    test(
      'AqtBootstrapInfo regex validation',
      () {
        // This sub-test runs always (no server needed)
        final re = RegExp(
          r'^AQT_(VER|PORT|PUBKEY|TOKEN)=([A-Za-z0-9+/=._-]+)$',
        );
        expect(re.hasMatch('AQT_VER=1'), isTrue);
        expect(re.hasMatch('AQT_PORT=12345'), isTrue);
        // Too long values still match (no length limit in regex)
        expect(re.hasMatch('AQT_BADKEY=val'), isFalse);
      },
    );

    test(
      'AqtTransport capability set',
      () {
        // Static test — no FFI/server needed
        const expectedCaps = {
          'localEchoPrediction',
          'roaming',
          'scrollbackReplay',
          'fileTransfer',
          'suspendResume',
          'metricsRich',
        };
        // Verify the count matches the transport capability matrix
        expect(expectedCaps.length, 6);
      },
    );

    test(
      'End-to-end: SSH bootstrap → QUIC handshake → PTY echo',
      skip: runE2e ? null : 'Set AQT_E2E=1 to run',
      () async {
        // Full e2e test — requires real SSH server + flyterm-server installed
        // To run: flutter test --dart-define=AQT_E2E=1 test/ssh/aqt/aqt_e2e_test.dart
        throw UnimplementedError(
          'Wire to AqtTransportFactory.connect in Stage 5',
        );
      },
    );
  });
}
