import 'dart:typed_data';

import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flyterm/ssh/aqt/aqt_transport_factory.dart';
import 'package:flyterm/ssh/transport/transport_factory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AqtTransportFactory.reconnect onPurgeSession', () {
    test('triggers onPurgeSession when RESUME fails with sessionNotFound',
        () async {
      var purgeCalled = 0;
      Future<void> purge() async {
        purgeCalled++;
      }

      final factory = _StubResultFactory(
        const AqtResumeFailed(
            AqtResumeFailReason.sessionNotFound, detail: 'server lost session'),
      );
      final prev = AqtTransport.testStub(
        port: 12345,
        spki: Uint8List(32),
        token: Uint8List(32),
        tabId: 7,
      );

      // connectWithCredentials will fail because we point at an unreachable
      // host with no SSH path — that's fine. We only assert purge fired.
      try {
        await factory.reconnect(
          server: _server(),
          creds: const ReconnectCredentials(),
          previous: prev,
          onPurgeSession: purge,
        );
      } on Object catch (_) {/* expected */}

      expect(factory.resumeCalled, 1,
          reason: 'RESUME branch must execute');
      expect(purgeCalled, 1,
          reason: 'sessionNotFound must trigger onPurgeSession');
    });

    test('does NOT trigger onPurgeSession on networkTimeout', () async {
      var purgeCalled = 0;
      Future<void> purge() async {
        purgeCalled++;
      }

      final factory = _StubResultFactory(
        const AqtResumeFailed(
            AqtResumeFailReason.networkTimeout, detail: 'timeout'),
      );
      final prev = AqtTransport.testStub(
        port: 12345,
        spki: Uint8List(32),
        token: Uint8List(32),
        tabId: 7,
      );

      try {
        await factory.reconnect(
          server: _server(),
          creds: const ReconnectCredentials(),
          previous: prev,
          onPurgeSession: purge,
        );
      } on Object catch (_) {/* expected */}

      expect(factory.resumeCalled, 1,
          reason: 'RESUME branch must execute');
      expect(purgeCalled, 0,
          reason: 'transient errors must not purge store');
    });

    test('triggers onPurgeSession when RESUME fails with handshakeFailed',
        () async {
      var purgeCalled = 0;
      Future<void> purge() async { purgeCalled++; }

      final factory = _StubResultFactory(
        const AqtResumeFailed(
            AqtResumeFailReason.handshakeFailed, detail: 'SPKI mismatch'),
      );
      final prev = AqtTransport.testStub(
        port: 12345,
        spki: Uint8List(32),
        token: Uint8List(32),
        tabId: 7,
      );

      try {
        await factory.reconnect(
          server: _server(),
          creds: const ReconnectCredentials(),
          previous: prev,
          onPurgeSession: purge,
        );
      } on Object catch (_) {/* expected */}

      expect(factory.resumeCalled, 1,
          reason: 'RESUME branch must execute');
      expect(purgeCalled, 1,
          reason: 'handshakeFailed must purge for symmetry with cold-resume');
    });

    test('does NOT trigger onPurgeSession when previous has no resume metadata',
        () async {
      var purgeCalled = 0;
      Future<void> purge() async {
        purgeCalled++;
      }

      final factory = _StubResultFactory(
        const AqtResumeFailed(
            AqtResumeFailReason.sessionNotFound, detail: 'should not be reached'),
      );
      // testStub with all-null metadata — reconnect must skip RESUME entirely.
      final prev = AqtTransport.testStub(
        port: null,
        spki: null,
        token: null,
        tabId: null,
      );

      try {
        await factory.reconnect(
          server: _server(),
          creds: const ReconnectCredentials(),
          previous: prev,
          onPurgeSession: purge,
        );
      } on Object catch (_) {/* expected */}

      expect(factory.resumeCalled, 0,
          reason: 'no metadata → RESUME must be skipped');
      expect(purgeCalled, 0,
          reason: 'no resume metadata → RESUME skipped → no purge');
    });
  });
}

class _StubResultFactory extends AqtTransportFactory {
  final AqtResumeResult stubbed;
  int resumeCalled = 0;
  _StubResultFactory(this.stubbed);

  @override
  Future<AqtResumeResult> tryResumeWithInfoDetailedForTest({
    required String host,
    required int port,
    required Uint8List spki,
    required Uint8List sessionToken,
    required int tabId,
    int lastOutOff = 0,
    int ringTailHash = 0,
    Duration? budget,
  }) async {
    resumeCalled++;
    return stubbed;
  }
}

Server _server() => const Server(
      id: 'test',
      name: 'test',
      host: 'invalid.invalid.invalid',
      port: 22,
      username: 'u',
      authType: 'password',
      transport: Transport.quic,
    );
