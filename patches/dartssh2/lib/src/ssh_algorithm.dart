import 'package:dartssh2/src/algorithm/ssh_cipher_type.dart';
import 'package:dartssh2/src/algorithm/ssh_hostkey_type.dart';
import 'package:dartssh2/src/algorithm/ssh_kex_type.dart';
import 'package:dartssh2/src/algorithm/ssh_mac_type.dart';

abstract class SSHAlgorithm {
  /// The name of the algorithm.
  String get name;

  const SSHAlgorithm();

  @override
  String toString() {
    return '$runtimeType($name)';
  }
}

extension SSHAlgorithmList<T extends SSHAlgorithm> on List<T> {
  List<String> toNameList() {
    return map((algorithm) => algorithm.name).toList();
  }

  T? getByName(String name) {
    for (var algorithm in this) {
      if (algorithm.name == name) {
        return algorithm;
      }
    }
    return null;
  }
}

class SSHAlgorithms {
  /// Algorithm used for the key exchange.
  final List<SSHKexType> kex;

  /// Algorithm used for the host key.
  final List<SSHHostkeyType> hostkey;

  /// Algorithm used for the encryption.
  final List<SSHCipherType> cipher;

  /// Algorithm used for the authentication.
  final List<SSHMacType> mac;

  /// Compression algorithms to advertise during key exchange, in
  /// preference order. Server-side picks the first mutual entry.
  /// Caller-controlled so the application can opt out (e.g. on a
  /// metered connection where the CPU cost of compression > the
  /// bandwidth savings, or for debugging). The protocol-required
  /// 'none' must always be included as a fallback.
  ///
  /// Default: `['zlib@openssh.com', 'zlib', 'none']` — prefers
  /// the OpenSSH-style delayed-activation variant (compression
  /// starts after authentication), falls back to plain zlib, then
  /// no compression.
  final List<String> compress;

  const SSHAlgorithms({
    this.kex = const [
      SSHKexType.x25519,
      SSHKexType.nistp521,
      SSHKexType.nistp384,
      SSHKexType.nistp256,
      SSHKexType.dhGexSha256,
      SSHKexType.dh14Sha256,
      SSHKexType.dh14Sha1,
      SSHKexType.dhGexSha1,
      SSHKexType.dh1Sha1,
    ],
    this.hostkey = const [
      SSHHostkeyType.ed25519,
      SSHHostkeyType.rsaSha512,
      SSHHostkeyType.rsaSha256,
      SSHHostkeyType.rsaSha1,
      SSHHostkeyType.ecdsa521,
      SSHHostkeyType.ecdsa384,
      SSHHostkeyType.ecdsa256,
    ],
    this.cipher = const [
      SSHCipherType.aes128ctr,
      SSHCipherType.aes128cbc,
      SSHCipherType.aes256ctr,
      SSHCipherType.aes256cbc,
    ],
    this.mac = const [
      SSHMacType.hmacSha256_96,
      SSHMacType.hmacSha512_96,
      SSHMacType.hmacSha256Etm,
      SSHMacType.hmacSha512Etm,
      SSHMacType.hmacSha1,
      SSHMacType.hmacSha256,
      SSHMacType.hmacSha512,
      SSHMacType.hmacMd5,
    ],
    this.compress = const ['zlib@openssh.com', 'zlib', 'none'],
  });
}
