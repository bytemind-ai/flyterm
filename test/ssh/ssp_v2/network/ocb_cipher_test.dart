import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/network/ocb_cipher.dart';

void main() {
  // K = 000102030405060708090A0B0C0D0E0F
  final key = Uint8List.fromList(List.generate(16, (i) => i));

  test('OCB 空 plaintext 空 AD 生成正确 tag (RFC 7253 Test Vector #1)', () {
    final cipher = OcbCipher(key);
    // K = 000102030405060708090A0B0C0D0E0F
    // N = BBAA99887766554433221100, A = "", P = ""
    // Expected C = 785407BFFFC8AD9EDCC5520AC9111EE6
    final nonce = _hex('BBAA99887766554433221100');
    final result = cipher.encrypt(nonce, Uint8List(0), Uint8List(0));
    // Tag only (16 bytes), no ciphertext
    expect(result.length, 16);
    // RFC 7253 Appendix A known-answer check
    expect(result, _hex('785407BFFFC8AD9EDCC5520AC9111EE6'));
    // Verify round-trip: decrypt should return empty plaintext
    final plain = cipher.decrypt(nonce, result, Uint8List(0));
    expect(plain, Uint8List(0));
  });

  test('OCB 加解密 round-trip，16字节 plaintext', () {
    final cipher = OcbCipher(key);
    final nonce = Uint8List(12)..fillRange(0, 12, 0xAA);
    final plain = Uint8List.fromList(List.generate(16, (i) => i + 0x10));
    final ad = Uint8List.fromList([1, 2, 3, 4]);

    final ciphertext = cipher.encrypt(nonce, plain, ad);
    expect(ciphertext.length, 16 + 16); // plaintext + 16-byte tag

    final decrypted = cipher.decrypt(nonce, ciphertext, ad);
    expect(decrypted, plain);
  });

  test('OCB 错误 AD 解密返回 null（认证失败）', () {
    final cipher = OcbCipher(key);
    final nonce = Uint8List(12);
    final plain = Uint8List.fromList([1, 2, 3]);
    final ad = Uint8List.fromList([0xAA]);

    final ct = cipher.encrypt(nonce, plain, ad);
    // Tamper AD
    final badAd = Uint8List.fromList([0xBB]);
    expect(() => cipher.decrypt(nonce, ct, badAd), throwsA(isA<OcbAuthException>()));
  });

  test('OCB 篡改 ciphertext 解密抛异常', () {
    final cipher = OcbCipher(key);
    final nonce = Uint8List(12);
    final plain = Uint8List.fromList([1, 2, 3, 4, 5]);
    final ct = cipher.encrypt(nonce, plain, Uint8List(0));
    // Flip a bit
    final tampered = Uint8List.fromList(ct)..first ^= 0x01;
    expect(() => cipher.decrypt(nonce, tampered, Uint8List(0)),
        throwsA(isA<OcbAuthException>()));
  });
}

Uint8List _hex(String s) {
  final bytes = <int>[];
  for (int i = 0; i < s.length; i += 2) {
    bytes.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(bytes);
}
