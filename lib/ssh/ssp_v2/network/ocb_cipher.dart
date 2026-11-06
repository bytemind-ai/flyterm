// SPDX-License-Identifier: GPL-3.0-or-later
// DEVIATION: physically copied from lib/ssh/ssp/ocb_cipher.dart so that
// ssp_v2/ has zero dependency on ssp/. The OCB-AES algorithm itself does not
// deviate.
// mirrors mosh::ocb_encrypt/ocb_decrypt in src/crypto/ocb.cc
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

class OcbAuthException implements Exception {
  const OcbAuthException();
  @override
  String toString() => 'OcbAuthException: authentication tag mismatch';
}

/// AES-128 in OCB3 mode (RFC 7253).
/// Key must be exactly 16 bytes. Nonce must be 1–15 bytes (mosh uses 12).
/// Output of encrypt = ciphertext || 16-byte tag.
/// decrypt throws [OcbAuthException] on tag mismatch.
class OcbCipher {
  final Uint8List _key;
  late final Uint8List _lStar;   // AES(K, 0^128)
  late final Uint8List _lDollar; // double(L*)
  final _lTable = <Uint8List>[];  // L[0], L[1], ...
  // Cached cipher instances — initialised once, reused on every encrypt/decrypt
  // call. Avoids per-block object allocation + AES key-schedule re-expansion
  // (11 rounds × 16 bytes each) that dominates CPU time in high-throughput
  // terminal output scenarios.
  late final ECBBlockCipher _encCipher;
  late final ECBBlockCipher _decCipher;
  // Scratch buffer shared across encrypt/decrypt inner loops for the
  // (block XOR offset) intermediate. Dart is single-threaded, so this is safe.
  final _tmp16 = Uint8List(16);

  OcbCipher(Uint8List key) : _key = Uint8List.fromList(key) {
    assert(key.length == 16, 'OcbCipher requires a 16-byte key');
    // Must initialise ciphers before _aesBlock is called below.
    _encCipher = ECBBlockCipher(AESEngine())..init(true, KeyParameter(_key));
    _decCipher = ECBBlockCipher(AESEngine())..init(false, KeyParameter(_key));
    _lStar = _aesBlock(Uint8List(16));
    _lDollar = _double(_lStar);
    // Pre-compute L[0..15] — enough for all practical message sizes
    _lTable.add(_double(_lDollar));
    for (int i = 1; i < 16; i++) {
      _lTable.add(_double(_lTable[i - 1]));
    }
  }

  // ── Public API ──────────────────────────────────────────────────────────

  /// Encrypt [plaintext] with [nonce] and [ad].
  /// Returns ciphertext || 16-byte authentication tag.
  Uint8List encrypt(Uint8List nonce, Uint8List plaintext, Uint8List ad) {
    final offset0 = _initOffset(nonce);
    final hash = _hash(ad);

    final ct = Uint8List(plaintext.length + 16);
    var offset = Uint8List.fromList(offset0);
    var checksum = Uint8List(16);
    int i = 1;
    int pos = 0;

    // Full 16-byte blocks.
    // _xorInPlace + _tmp16 scratch eliminate ~3 Uint8List allocations per block.
    while (pos + 16 <= plaintext.length) {
      _xorInPlace(offset, _l(i));
      final block = Uint8List.sublistView(plaintext, pos, pos + 16);
      for (int j = 0; j < 16; j++) { _tmp16[j] = block[j] ^ offset[j]; }
      final enc = _aesBlock(_tmp16); // fresh buffer from _aesBlock
      _xorInPlace(enc, offset);      // enc ^= offset in-place (enc is freshly allocated)
      ct.setRange(pos, pos + 16, enc);
      _xorInPlace(checksum, block);
      pos += 16;
      i++;
    }

    // Final (possibly partial) block — RFC 7253 guards with if bitlen(P*) > 0
    final lastLen = plaintext.length - pos;
    if (lastLen > 0) {
      _xorInPlace(offset, _lStar);
      final pad = _aesBlock(offset);
      for (int j = 0; j < lastLen; j++) {
        ct[pos + j] = plaintext[pos + j] ^ pad[j];
      }
      final lastBlock = Uint8List(16);
      lastBlock.setRange(0, lastLen, plaintext.sublist(pos));
      lastBlock[lastLen] = 0x80;
      _xorInPlace(checksum, lastBlock);
    }

    // Tag: AES(checksum ^ offset ^ lDollar) ^ hash
    _xorInPlace(checksum, offset);
    _xorInPlace(checksum, _lDollar);
    final tag = _xor(_aesBlock(checksum), hash);
    ct.setRange(plaintext.length, plaintext.length + 16, tag);
    return ct;
  }

  /// Decrypt [ciphertext] (includes 16-byte tag at end).
  /// Returns plaintext. Throws [OcbAuthException] on tag mismatch.
  Uint8List decrypt(Uint8List nonce, Uint8List ciphertext, Uint8List ad) {
    if (ciphertext.length < 16) throw const OcbAuthException();
    final ctLen = ciphertext.length - 16;
    final tag = ciphertext.sublist(ctLen);
    final ct = ciphertext.sublist(0, ctLen);

    final offset0 = _initOffset(nonce);
    final hash = _hash(ad);

    final plain = Uint8List(ctLen);
    var offset = Uint8List.fromList(offset0);
    var checksum = Uint8List(16);
    int i = 1;
    int pos = 0;

    // Full 16-byte blocks — same in-place optimisations as encrypt.
    while (pos + 16 <= ctLen) {
      _xorInPlace(offset, _l(i));
      final block = Uint8List.sublistView(ct, pos, pos + 16);
      for (int j = 0; j < 16; j++) { _tmp16[j] = block[j] ^ offset[j]; }
      final dec = _aesBlockInv(_tmp16); // fresh buffer
      _xorInPlace(dec, offset);         // dec = plaintext block (in-place)
      plain.setRange(pos, pos + 16, dec);
      _xorInPlace(checksum, dec);       // checksum ^= plaintext block
      pos += 16;
      i++;
    }

    // Final (possibly partial) block — RFC 7253 guards with if bitlen(C*) > 0
    final lastLen = ctLen - pos;
    if (lastLen > 0) {
      _xorInPlace(offset, _lStar);
      final pad = _aesBlock(offset);
      for (int j = 0; j < lastLen; j++) {
        plain[pos + j] = ct[pos + j] ^ pad[j];
      }
      final lastBlock = Uint8List(16);
      lastBlock.setRange(0, lastLen, plain.sublist(pos));
      lastBlock[lastLen] = 0x80;
      _xorInPlace(checksum, lastBlock);
    }

    // Verify tag: AES(checksum ^ offset ^ lDollar) ^ hash
    _xorInPlace(checksum, offset);
    _xorInPlace(checksum, _lDollar);
    final expectedTag = _xor(_aesBlock(checksum), hash);
    if (!_constantTimeEqual(tag, expectedTag)) throw const OcbAuthException();
    return plain;
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  /// Compute initial offset from nonce (RFC 7253 §4).
  ///
  /// Per RFC 7253:
  ///   Nonce = num2str(TAGLEN mod 128, 7) || 1 || zeros(127-8*NONCELEN) || nonce_bytes
  ///   bottom = last 6 bits of nonce
  ///   Ktop = AES(K, Nonce with last 6 bits zeroed)
  ///   Stretch = Ktop || (Ktop[0..63] XOR Ktop[8..71])  (byte-level: Ktop || first8(Ktop) XOR Ktop[1..8])
  ///   Offset_0 = Stretch[bottom..bottom+127]
  Uint8List _initOffset(Uint8List nonce) {
    assert(nonce.isNotEmpty && nonce.length <= 15);
    final nLen = nonce.length;
    final bottom = nonce[nLen - 1] & 0x3F;

    // Build 128-bit block for Ktop computation
    // Format: [TAGLEN_mod128 (7 bits) | 1 | 0^(127-8*nLen) | nonce | 0^6]
    // TAGLEN = 128 bits, so TAGLEN mod 128 = 0
    // First byte structure: 0b0000000_1 = 0x01 (7 bits of taglen=0, then 1 bit)
    // Then zero-padding until nonce starts, then nonce (last byte has bottom 6 bits zeroed)
    final block = Uint8List(16);
    // RFC 7253 §4: Nonce block layout for ENCIPHER(K, ...) computation.
    // The 128-bit block is: zeros || 0x01 (separator) || nonce (last byte with bottom 6 bits zeroed)
    // byte (16-nLen-1) = 0x01  (separator bit, zero-padded in MSBs)
    // bytes (16-nLen)..(14) = nonce[0..nLen-2]
    // byte 15 = nonce[nLen-1] & 0xC0  (bottom 6 bits are the "bottom" field, zeroed here)
    block[16 - nLen - 1] = 0x01;
    for (int j = 0; j < nLen - 1; j++) {
      block[16 - nLen + j] = nonce[j];
    }
    // Last nonce byte with bottom 6 bits zeroed
    block[15] = nonce[nLen - 1] & 0xC0;

    final ktop = _aesBlock(block);

    // Stretch = ktop (16 bytes) || (ktop[0..7] XOR ktop[1..8]) (8 bytes) = 24 bytes total
    final stretch = Uint8List(24);
    stretch.setRange(0, 16, ktop);
    for (int j = 0; j < 8; j++) {
      stretch[16 + j] = ktop[j] ^ ktop[j + 1];
    }

    // Offset_0 = stretch[bottom : bottom+128] as bit-string
    final result = Uint8List(16);
    for (int j = 0; j < 16; j++) {
      final bitPos = bottom + j * 8;
      final byteIdx = bitPos ~/ 8;
      final bitShift = bitPos % 8;
      if (bitShift == 0) {
        result[j] = stretch[byteIdx];
      } else {
        result[j] = ((stretch[byteIdx] << bitShift) |
            (stretch[byteIdx + 1] >> (8 - bitShift))) &
            0xFF;
      }
    }
    return result;
  }

  /// HASH function for associated data (RFC 7253 §4).
  Uint8List _hash(Uint8List ad) {
    if (ad.isEmpty) return Uint8List(16);
    var offset = Uint8List(16);
    var sum = Uint8List(16);
    int i = 1;
    int pos = 0;
    while (pos + 16 <= ad.length) {
      offset = _xor(offset, _l(i));
      sum = _xor(sum, _aesBlock(_xor(ad.sublist(pos, pos + 16), offset)));
      pos += 16;
      i++;
    }
    if (pos < ad.length) {
      offset = _xor(offset, _lStar);
      final block = Uint8List(16);
      block.setRange(0, ad.length - pos, ad.sublist(pos));
      block[ad.length - pos] = 0x80;
      sum = _xor(sum, _aesBlock(_xor(block, offset)));
    }
    return sum;
  }

  /// double(x) in GF(2^128) with polynomial x^128 + x^7 + x^2 + x + 1.
  Uint8List _double(Uint8List x) {
    final result = Uint8List(16);
    int carry = 0;
    for (int i = 15; i >= 0; i--) {
      final b = x[i];
      result[i] = ((b << 1) | carry) & 0xFF;
      carry = b >> 7;
    }
    if (carry != 0) result[15] ^= 0x87;
    return result;
  }

  /// L[i] from pre-computed table (indexed by ntz(i)).
  Uint8List _l(int i) {
    final ntz = _ntz(i);
    while (_lTable.length <= ntz) {
      _lTable.add(_double(_lTable.last));
    }
    return _lTable[ntz];
  }

  /// Number of trailing zero bits in i.
  int _ntz(int i) {
    if (i == 0) return 0;
    int n = 0;
    while ((i & 1) == 0) {
      i >>= 1;
      n++;
    }
    return n;
  }

  Uint8List _xor(Uint8List a, Uint8List b) {
    assert(a.length == 16 && b.length == 16);
    final r = Uint8List(16);
    for (int i = 0; i < 16; i++) { r[i] = a[i] ^ b[i]; }
    return r;
  }

  // In-place XOR: a[i] ^= b[i]. Avoids heap allocation in hot OCB loops where
  // the old value of [a] is not needed after the operation.
  static void _xorInPlace(Uint8List a, Uint8List b) {
    for (int i = 0; i < 16; i++) { a[i] ^= b[i]; }
  }

  Uint8List _aesBlock(Uint8List block) {
    final out = Uint8List(16);
    _encCipher.processBlock(block, 0, out, 0);
    return out;
  }

  Uint8List _aesBlockInv(Uint8List block) {
    final out = Uint8List(16);
    _decCipher.processBlock(block, 0, out, 0);
    return out;
  }

  bool _constantTimeEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) { diff |= a[i] ^ b[i]; }
    return diff == 0;
  }
}
