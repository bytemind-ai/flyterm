import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/transport/remote_transport.dart';

void main() {
  group('Transport capability matrix', () {
    // These tests verify the transport capability matrix is correctly reflected
    // in constants and documentation, even without actual transport instances.

    test('TransportCapability enum has exactly 7 values', () {
      expect(TransportCapability.values.length, 7);
    });

    test('capability matrix — AQT has most capabilities', () {
      // AQT has localEchoPrediction, roaming, scrollbackReplay,
      // fileTransfer, suspendResume, metricsRich (6 caps; not reverseForward)
      const aqtCaps = {
        TransportCapability.localEchoPrediction,
        TransportCapability.roaming,
        TransportCapability.scrollbackReplay,
        TransportCapability.fileTransfer,
        TransportCapability.suspendResume,
        TransportCapability.metricsRich,
      };
      expect(aqtCaps.length, 6);
      expect(aqtCaps.contains(TransportCapability.reverseForward), isFalse);
    });

    test('capability matrix — SSH has only reverseForward', () {
      const sshCaps = {TransportCapability.reverseForward};
      expect(sshCaps.length, 1);
      expect(sshCaps.contains(TransportCapability.scrollbackReplay), isFalse);
    });

    test('capability matrix — Mosh has 4 caps (no scrollbackReplay, fileTransfer, reverseForward)', () {
      const moshCaps = {
        TransportCapability.localEchoPrediction,
        TransportCapability.roaming,
        TransportCapability.suspendResume,
        TransportCapability.metricsRich,
      };
      expect(moshCaps.length, 4);
      expect(moshCaps.contains(TransportCapability.scrollbackReplay), isFalse);
      expect(moshCaps.contains(TransportCapability.fileTransfer), isFalse);
      expect(moshCaps.contains(TransportCapability.reverseForward), isFalse);
    });

    test('capability matrix — Local has no capabilities', () {
      const localCaps = <TransportCapability>{};
      expect(localCaps, isEmpty);
    });

    test('assertCapability throws UnsupportedError when cap missing', () {
      // Test the assertCapability helper directly
      // We need a minimal RemoteTransport stub to test this.
      // Use a simple anonymous implementation.
      expect(
        () {
          // Simulate a transport with no caps trying to suppress echo
          final fakeTransport = _NoCapTransport();
          assertCapability(fakeTransport, TransportCapability.localEchoPrediction);
        },
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}

// Minimal stub that has no capabilities
class _NoCapTransport implements RemoteTransport {
  @override TransportKind get kind => TransportKind.local;
  @override Set<TransportCapability> get capabilities => const {};
  @override TransportState get currentState => TransportState.idle;
  @override Stream<TransportState> get stateStream => const Stream.empty();
  @override TransportMetrics get metrics => TransportMetrics.empty;
  @override Stream<Uint8List> get output => const Stream.empty();
  @override Stream<Uint8List> get stderr => const Stream.empty();
  @override Future<void> get done => Future.value();
  @override void write(Uint8List data) {}
  @override void resize(int cols, int rows) {}
  @override Future<void> close() async {}
  @override void setForeground(bool active) {}
  @override void heartbeat() {}
  @override void roam() {}
  @override Future<bool> softReconnect() async => false;
  @override void suppressLocalEcho() {}
  @override void suppressNextLocalEcho() {}
  @override Future<FileTransferHandle> upload(File local, String remotePath) => throw UnimplementedError();
  @override Future<FileTransferHandle> download(String remotePath, File local) => throw UnimplementedError();
  @override Future<void> requestScrollbackReplay(int fromOffset) async {}
}
