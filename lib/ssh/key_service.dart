// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as nacl;
import 'package:pointycastle/export.dart';

class SSHKeyPairResult {
  final String publicKeyOpenSSH;
  final String privateKeyPem;

  const SSHKeyPairResult({
    required this.publicKeyOpenSSH,
    required this.privateKeyPem,
  });
}

class KeyService {
  /// Generate an Ed25519 key pair. Returns PEM + OpenSSH public key string.
  static Future<SSHKeyPairResult> generateEd25519() async {
    final signingKey = nacl.SigningKey.generate();

    // Public key: 32-byte ed25519 verify key
    final publicKeyBytes = Uint8List.fromList(signingKey.verifyKey);
    // Private key in OpenSSH format: 64 bytes = seed (32) + public (32)
    final privateKeyBytes = Uint8List.fromList(signingKey);

    final pair =
        OpenSSHEd25519KeyPair(publicKeyBytes, privateKeyBytes, '');
    final pem = pair.toPem();
    final publicKeyOpenSSH = _toOpenSSH(pair);

    return SSHKeyPairResult(
        publicKeyOpenSSH: publicKeyOpenSSH, privateKeyPem: pem);
  }

  /// Generate an RSA 4096-bit key pair.
  static Future<SSHKeyPairResult> generateRSA() async {
    final rng = FortunaRandom();
    final secureRandom = Random.secure();
    final seeds = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      seeds[i] = secureRandom.nextInt(256);
    }
    rng.seed(KeyParameter(seeds));

    final keyGen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.parse('65537'), 4096, 64),
        rng,
      ));

    final keyPair = keyGen.generateKeyPair();
    final rsaPub = keyPair.publicKey;
    final rsaPriv = keyPair.privateKey;

    final n = rsaPriv.n!;
    final e = rsaPub.exponent!;
    final d = rsaPriv.privateExponent!;
    final p = rsaPriv.p!;
    final q = rsaPriv.q!;
    final iqmp = q.modInverse(p);

    final pair = OpenSSHRsaKeyPair(n, e, d, iqmp, p, q, '');
    final pem = pair.toPem();
    final publicKeyOpenSSH = _toOpenSSH(pair);

    return SSHKeyPairResult(
        publicKeyOpenSSH: publicKeyOpenSSH, privateKeyPem: pem);
  }

  /// Import a private key from PEM and return its public key in OpenSSH format.
  static Future<SSHKeyPairResult> importFromPem(
    String pem, {
    String? passphrase,
  }) async {
    final pairs = SSHKeyPair.fromPem(pem, passphrase);
    final pair = pairs.first;
    return SSHKeyPairResult(
      publicKeyOpenSSH: _toOpenSSH(pair),
      privateKeyPem: pem,
    );
  }

  /// Convert an SSHKeyPair's public key to OpenSSH authorized_keys format.
  /// Format: "<type> <base64(wire-encoded-public-key)>"
  static String _toOpenSSH(SSHKeyPair pair) {
    final encoded = pair.toPublicKey().encode();
    return '${pair.name} ${base64.encode(encoded)}';
  }
}
