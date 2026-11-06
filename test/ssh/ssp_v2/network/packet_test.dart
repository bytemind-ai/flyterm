import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/network/ocb_cipher.dart';
import 'package:flyterm/ssh/ssp_v2/network/packet.dart';

void main() {
  test('encode->decode roundtrip preserves nonce + plaintext', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    // Wire format zeroes the leading 4 bytes; build nonce accordingly
    // so the roundtrip nonce comparison succeeds bit-for-bit.
    final nonce = Uint8List(12);
    nonce.setRange(4, 12, List.generate(8, (i) => i + 1));
    final cipher = OcbCipher(key);
    final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
    final wire =
        MoshPacket.encode(nonce: nonce, plaintext: payload, cipher: cipher);
    expect(wire.length, 8 + payload.length + 16);
    final p = MoshPacket.decode(wire, cipher: cipher);
    expect(p.plaintext, payload);
    expect(p.nonce, nonce);
  });

  test('decode rejects tampered ciphertext', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final nonce = Uint8List(12);
    nonce.setRange(4, 12, List.generate(8, (i) => i + 1));
    final cipher = OcbCipher(key);
    final wire = MoshPacket.encode(
      nonce: nonce,
      plaintext: Uint8List.fromList([9]),
      cipher: cipher,
    );
    wire[wire.length - 1] ^= 0x01;
    expect(() => MoshPacket.decode(wire, cipher: cipher),
        throwsA(isA<Object>()));
  });

  test('decode rejects packet shorter than 24 bytes', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final cipher = OcbCipher(key);
    expect(
      () => MoshPacket.decode(Uint8List(20), cipher: cipher),
      throwsA(isA<FormatException>()),
    );
  });

  test('encode rejects nonce of wrong length', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final cipher = OcbCipher(key);
    expect(
      () => MoshPacket.encode(
        nonce: Uint8List(8),
        plaintext: Uint8List(0),
        cipher: cipher,
      ),
      throwsArgumentError,
    );
  });
}
