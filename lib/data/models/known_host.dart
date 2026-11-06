// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

/// One row in the `known_hosts` table — a remembered (host, port, keyType)
/// → fingerprint mapping. Mirrors OpenSSH's known_hosts file but keyed
/// per-server in SQLite for portability and per-row metadata.
class KnownHost {
  final String host;
  final int port;
  /// Algorithm name as reported by dartssh2's verify callback, e.g.
  /// 'ssh-ed25519', 'rsa-sha2-256'. Stored as-is so cross-version match
  /// is exact.
  final String keyType;
  /// Hex-with-colons MD5 fingerprint of the host key, e.g.
  /// 'aa:bb:cc:dd:11:22:...'. dartssh2's onVerifyHostKey only exposes
  /// the MD5 fingerprint; we don't have access to the raw public key.
  final String fingerprintMd5;
  final DateTime firstSeen;
  final DateTime lastSeen;

  const KnownHost({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprintMd5,
    required this.firstSeen,
    required this.lastSeen,
  });

  Map<String, Object?> toMap() => {
        'host': host,
        'port': port,
        'key_type': keyType,
        'fingerprint_md5': fingerprintMd5,
        'first_seen': firstSeen.millisecondsSinceEpoch,
        'last_seen': lastSeen.millisecondsSinceEpoch,
      };

  factory KnownHost.fromMap(Map<String, Object?> m) => KnownHost(
        host: m['host'] as String,
        port: m['port'] as int,
        keyType: m['key_type'] as String,
        fingerprintMd5: m['fingerprint_md5'] as String,
        firstSeen: DateTime.fromMillisecondsSinceEpoch(m['first_seen'] as int),
        lastSeen: DateTime.fromMillisecondsSinceEpoch(m['last_seen'] as int),
      );

  KnownHost copyWith({
    String? fingerprintMd5,
    DateTime? lastSeen,
  }) =>
      KnownHost(
        host: host,
        port: port,
        keyType: keyType,
        fingerprintMd5: fingerprintMd5 ?? this.fingerprintMd5,
        firstSeen: firstSeen,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  /// Convenience: format raw MD5 bytes as the 'aa:bb:cc:...' form OpenSSH
  /// historically prints. dartssh2 hands back the binary digest.
  static String formatMd5(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
}
