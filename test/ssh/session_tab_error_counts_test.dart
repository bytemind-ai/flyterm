// test/ssh/session_tab_error_counts_test.dart
//
// Unit tests for ErrCategory + classifyConnectError + recordError
// (debug overlay `errCnt` row).
//
// SessionTab itself has heavy dependencies (xterm Terminal, SSHConnection,
// AIEngine) so we don't instantiate it; we test the pure-function
// classifier + Map-style counters as separate units.

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/session_manager.dart';

void main() {
  group('classifyConnectError', () {
    test('SSHChannelOpenError → sshChannel', () {
      expect(
        classifyConnectError(
            'SSHChannelOpenError: connection refused channel'),
        ErrCategory.sshChannel,
      );
    });

    test('Nested TransportConnectException wrapping SSHChannelOpenError', () {
      // Real-world chain from f.jpg.
      expect(
        classifyConnectError(
            'TransportConnectException: TransportConnectException: '
            'AQT connect failed: SSHChannelOpenError(server '
            'rejected)'),
        ErrCategory.sshChannel,
      );
    });

    test('AqtServerNotInstalledException → notInstalled', () {
      expect(
        classifyConnectError(
            'AqtServerNotInstalledException: binary missing'),
        ErrCategory.notInstalled,
      );
    });

    test('AqtDaemonStartFailedException → daemonFail', () {
      expect(
        classifyConnectError(
            'AqtDaemonStartFailedException: daemon.info not written '
            'within 5s'),
        ErrCategory.daemonFail,
      );
    });

    test('QUIC connect timed out → quicTimeout', () {
      expect(
        classifyConnectError(
            'AqtBootstrapException: QUIC connect timed out after '
            'bootstrap'),
        ErrCategory.quicTimeout,
      );
    });

    test('AqtBootstrapException with timeout text → bootTimeout', () {
      expect(
        classifyConnectError(
            'AqtBootstrapException: pkill/sleep exec timed out '
            'after 5s'),
        ErrCategory.bootTimeout,
      );
    });

    test('AqtBootstrapException with non-timeout text → other', () {
      expect(
        classifyConnectError(
            'AqtBootstrapException: parse: invalid AQT_PORT'),
        ErrCategory.other,
      );
    });

    test('Plain TimeoutException → other (no specific QUIC/boot keyword)', () {
      expect(
        classifyConnectError(TimeoutException('SSH authentication timed out')),
        ErrCategory.other,
      );
    });

    test('Random unknown exception → other', () {
      expect(
        classifyConnectError(StateError('unexpected state')),
        ErrCategory.other,
      );
    });

    test('SSHChannelOpenError beats other patterns when both appear', () {
      // Defensive: ordering in classify matters.
      expect(
        classifyConnectError(
            'wrapped exception: SSHChannelOpenError + QUIC connect timed out'),
        ErrCategory.sshChannel,
      );
    });
  });

  group('ErrCategory enum surface', () {
    test('all 6 expected variants exist', () {
      expect(ErrCategory.values, hasLength(6));
      expect(ErrCategory.values, containsAll([
        ErrCategory.sshChannel,
        ErrCategory.bootTimeout,
        ErrCategory.quicTimeout,
        ErrCategory.notInstalled,
        ErrCategory.daemonFail,
        ErrCategory.other,
      ]));
    });
  });
}

// Local copy to avoid pulling dart:async into the test file just for one
// TimeoutException constructor signature.
class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  @override
  String toString() => 'TimeoutException: $message';
}
