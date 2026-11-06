// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../util/dlog.dart';

import 'package:flutter/foundation.dart';

import '../data/models/known_host.dart';
import '../data/repositories/known_host_repository.dart';

/// Contract for deciding whether to accept a host's public key during
/// SSH handshake. Plugged into [SSHConnection] so the connection
/// layer stays UI-agnostic.
///
/// Implementations must return true to accept the key (proceed with
/// the connection) and false to reject it (abort with auth failure).
abstract class HostKeyVerifier {
  Future<bool> verify({
    required String host,
    required int port,
    required String keyType,
    required String fingerprintMd5,
  });
}

/// Outcome the user (or other policy layer) returned for a TOFU /
/// mismatch dialog.
enum HostKeyDecision { accept, reject }

/// Function type for surfacing the policy decision to the user.
/// Implementations typically show a dialog and await the user's
/// choice. Lives outside this package (UI layer) and is registered
/// once at app startup.
typedef HostKeyPrompt = Future<HostKeyDecision> Function({
  required String host,
  required int port,
  required String keyType,
  required String fingerprintMd5,
  required HostKeyPromptKind kind,
  String? expectedFingerprintMd5,
});

enum HostKeyPromptKind {
  /// First time we see this (host, port, keyType) — no record exists.
  trustOnFirstUse,

  /// We have a record but the fingerprint differs — possible MITM.
  mismatch,
}

/// Default verifier: looks up the (host, port, keyType) tuple in the
/// known_hosts table.
///
///   • Hit + fingerprint matches → accept silently, refresh last_seen.
///   • Hit + fingerprint differs → ask the user (mismatch). If they
///     accept, replace the row. If not, reject.
///   • Miss → ask the user (TOFU). If they accept, insert. If not,
///     reject.
///
/// Without a registered [prompt] the verifier defaults to **rejecting**
/// in TOFU and mismatch cases — fail-closed is the safe behaviour for
/// a security-relevant check. Tests can pass a stub prompt that
/// auto-accepts.
class DefaultHostKeyVerifier implements HostKeyVerifier {
  final KnownHostRepository repo;
  final HostKeyPrompt? prompt;

  DefaultHostKeyVerifier({required this.repo, this.prompt});

  @override
  Future<bool> verify({
    required String host,
    required int port,
    required String keyType,
    required String fingerprintMd5,
  }) async {
    final existing = await repo.find(
      host: host,
      port: port,
      keyType: keyType,
    );

    if (existing == null) {
      return _handleTofu(host, port, keyType, fingerprintMd5);
    }

    if (existing.fingerprintMd5 == fingerprintMd5) {
      // Match: refresh last_seen so the management screen surfaces
      // recently-active hosts at the top.
      await repo.touch(host: host, port: port, keyType: keyType);
      return true;
    }

    return _handleMismatch(host, port, keyType, fingerprintMd5, existing);
  }

  Future<bool> _handleTofu(
      String host, int port, String keyType, String fp) async {
    final p = prompt;
    if (p == null) {
      dlog('HostKey',
          'TOFU rejected (no prompt registered) host=$host:$port type=$keyType fp=$fp');
      return false;
    }
    final decision = await p(
      host: host,
      port: port,
      keyType: keyType,
      fingerprintMd5: fp,
      kind: HostKeyPromptKind.trustOnFirstUse,
    );
    if (decision == HostKeyDecision.reject) return false;
    final now = DateTime.now();
    await repo.insert(KnownHost(
      host: host,
      port: port,
      keyType: keyType,
      fingerprintMd5: fp,
      firstSeen: now,
      lastSeen: now,
    ));
    return true;
  }

  Future<bool> _handleMismatch(
      String host, int port, String keyType, String fp, KnownHost old) async {
    final p = prompt;
    if (p == null) {
      dlog('HostKey',
          'MISMATCH rejected (no prompt) host=$host:$port type=$keyType '
          'expected=${old.fingerprintMd5} got=$fp');
      return false;
    }
    final decision = await p(
      host: host,
      port: port,
      keyType: keyType,
      fingerprintMd5: fp,
      kind: HostKeyPromptKind.mismatch,
      expectedFingerprintMd5: old.fingerprintMd5,
    );
    if (decision == HostKeyDecision.reject) return false;
    final now = DateTime.now();
    await repo.save(KnownHost(
      host: host,
      port: port,
      keyType: keyType,
      fingerprintMd5: fp,
      firstSeen: old.firstSeen,
      lastSeen: now,
    ));
    return true;
  }
}

/// Convenience adapter: turns a verifier into the dartssh2
/// onVerifyHostKey callback signature. Captures the host/port from
/// the connection context so the verifier doesn't need it stored.
FutureOr<bool> Function(String type, Uint8List md5)
    asDartsshHandler(HostKeyVerifier v, {required String host, required int port}) {
  return (String type, Uint8List md5) async {
    return v.verify(
      host: host,
      port: port,
      keyType: type,
      fingerprintMd5: KnownHost.formatMd5(md5),
    );
  };
}
