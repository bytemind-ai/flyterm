import 'dart:typed_data';

import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flyterm/ssh/aqt/aqt_transport_factory.dart';
import 'package:flyterm/ssh/transport/remote_transport.dart';
import 'package:flyterm/ssh/transport/transport_factory.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AqtTransportFactory race', () {
    test('RESUME wins fast — bootstrap never starts', () async {
      final winnerTransport = _fakeTransport();
      final factory = _RaceableFactory(
        resumeDelay: const Duration(milliseconds: 500),
        resumeResult: AqtResumeSuccess(winnerTransport),
        bootstrapDelay: const Duration(seconds: 30),
      );
      final result = await factory.reconnect(
        server: _server(),
        creds: const ReconnectCredentials(),
        previous: _prev(),
      );
      expect(identical(result, winnerTransport), isTrue);
      expect(factory.bootstrapStarted, isFalse,
          reason: 'RESUME finished within 3s — bootstrap must not have launched');
    });

    test('RESUME stalls > 3s but eventually succeeds — bootstrap started then discarded',
        () async {
      final resumeTransport = _fakeTransport();
      final factory = _RaceableFactory(
        resumeDelay: const Duration(milliseconds: 4500),
        resumeResult: AqtResumeSuccess(resumeTransport),
        bootstrapDelay: const Duration(seconds: 30),
      );
      final result = await factory.reconnect(
        server: _server(),
        creds: const ReconnectCredentials(),
        previous: _prev(),
      );
      expect(identical(result, resumeTransport), isTrue);
      expect(factory.bootstrapStarted, isTrue);
    });

    test('RESUME stalls then fails — bootstrap wins', () async {
      final bootstrapTransport = _fakeTransport();
      final factory = _RaceableFactory(
        resumeDelay: const Duration(milliseconds: 10000),
        resumeResult: const AqtResumeFailed(
            AqtResumeFailReason.networkTimeout, detail: 'r-fail'),
        bootstrapDelay: const Duration(milliseconds: 4000),
        bootstrapResult: bootstrapTransport,
      );
      final result = await factory.reconnect(
        server: _server(),
        creds: const ReconnectCredentials(),
        previous: _prev(),
      );
      expect(identical(result, bootstrapTransport), isTrue);
    });

    test('both fail — exception propagates', () async {
      final factory = _RaceableFactory(
        resumeDelay: const Duration(milliseconds: 4500),
        resumeResult: const AqtResumeFailed(
            AqtResumeFailReason.networkTimeout, detail: 'r-fail'),
        bootstrapDelay: const Duration(milliseconds: 4000),
        bootstrapError: 'b-fail',
      );
      expect(
        () => factory.reconnect(
          server: _server(),
          creds: const ReconnectCredentials(),
          previous: _prev(),
        ),
        throwsA(isA<Object>()),
      );
    });
  });
}

class _RaceableFactory extends AqtTransportFactory {
  final Duration resumeDelay;
  final AqtResumeResult resumeResult;
  final Duration bootstrapDelay;
  final AqtTransport? bootstrapResult;
  final String? bootstrapError;

  bool bootstrapStarted = false;

  _RaceableFactory({
    required this.resumeDelay,
    required this.resumeResult,
    required this.bootstrapDelay,
    this.bootstrapResult,
    this.bootstrapError,
  });

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
    await Future.delayed(resumeDelay);
    return resumeResult;
  }

  @override
  Future<RemoteTransport> connectWithCredentialsForTest(
    Server server, {
    String? password,
    String? privateKeyPem,
    dynamic reuseClient,
    BuildContext? dialogContext,
  }) async {
    bootstrapStarted = true;
    await Future.delayed(bootstrapDelay);
    if (bootstrapResult != null) return bootstrapResult!;
    throw bootstrapError ?? 'no result';
  }
}

AqtTransport _fakeTransport() => AqtTransport.testStub(
      port: 12345,
      spki: Uint8List(32),
      token: Uint8List(32),
      tabId: 1,
    );

AqtTransport _prev() => AqtTransport.testStub(
      port: 12345,
      spki: Uint8List(32),
      token: Uint8List(32),
      tabId: 1,
    );

Server _server() => const Server(
      id: 'test',
      name: 'test',
      host: 'invalid.invalid.invalid',
      port: 22,
      username: 'u',
      authType: 'password',
      transport: Transport.quic,
    );
