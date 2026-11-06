// Verifies the chacha20-poly1305@openssh.com construction we wired
// into the patched dartssh2 transport. The send-side and receive-
// side helpers in SSHTransport are private, so this test mirrors the
// exact same primitive sequence (ChaCha20Engine + Poly1305 from
// pointycastle, OpenSSH key layout + nonce derivation) and asserts
// the bytes a sender would put on the wire decrypt back to the
// original plaintext on the receiver.
//
// The point isn't to retest pointycastle; it's to lock in the
// protocol-level details (key split order, block-counter offsets,
// padding alignment) so they don't silently regress.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

Uint8List _nonce8(int seq) {
  final n = Uint8List(8);
  ByteData.sublistView(n).setUint64(0, seq);
  return n;
}

Uint8List _xor(Uint8List key, Uint8List nonce, int initialBlock, Uint8List data) {
  final c = ChaCha20Engine();
  c.init(true, ParametersWithIV(KeyParameter(key), nonce));
  if (initialBlock > 0) {
    final skip = Uint8List(initialBlock * 64);
    c.processBytes(skip, 0, skip.length, skip, 0);
  }
  final out = Uint8List(data.length);
  c.processBytes(data, 0, data.length, out, 0);
  return out;
}

Uint8List _polyKey(Uint8List k2, Uint8List nonce) {
  final c = ChaCha20Engine();
  c.init(true, ParametersWithIV(KeyParameter(k2), nonce));
  final block0 = Uint8List(64);
  c.processBytes(block0, 0, block0.length, block0, 0);
  return Uint8List.sublistView(block0, 0, 32);
}

int _alignPadding(int payloadLen) {
  // 8-byte alignment per OpenSSH spec, min padding = 4.
  final p = 8 - ((payloadLen + 1) % 8);
  return p < 4 ? p + 8 : p;
}

void main() {
  test('polyKey deterministic on repeat calls', () {
    final keyBuf = Uint8List.fromList(List.generate(64, (i) => i & 0xff));
    final k2a = Uint8List.fromList(keyBuf.sublist(0, 32));
    final k2b = Uint8List.fromList(keyBuf.sublist(0, 32));
    final n = Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 42]);
    final pk1 = _polyKey(k2a, n);
    final pk2 = _polyKey(k2b, n);
    expect(pk1, pk2);
  });

  test('polyKey deterministic AFTER an _xor call with different key/nonce', () {
    final k2 = Uint8List.fromList(List.generate(32, (i) => i & 0xff));
    final k1 = Uint8List.fromList(List.generate(32, (i) => 100 + (i & 0xff)));
    final n = Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 5]);
    final pk1 = _polyKey(k2, n);
    final scratch = _xor(k1, n, 0, Uint8List(4));
    expect(scratch, isNotNull);
    final pk2 = _polyKey(k2, n);
    expect(pk2, pk1);
  });

  test('polyKey deterministic AFTER an _xor with SAME key', () {
    final k2 = Uint8List.fromList(List.generate(32, (i) => i & 0xff));
    final n = Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 5]);
    final pk1 = _polyKey(k2, n);
    final body = _xor(k2, n, 1, Uint8List(40));
    expect(body, isNotNull);
    final pk2 = _polyKey(k2, n);
    expect(pk2, pk1, reason: 'fresh engine per call must produce same key');
  });

  test('round-trip simplified: encrypt then re-derive key', () {
    // Goal: isolate why the full round-trip test fails on
    // "pk == pkVerify". Use independent fresh-allocated copies.
    final k2 = Uint8List.fromList(List.generate(32, (i) => i & 0xff));
    final nonce = Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 42]);
    final plaintext = Uint8List(24); // arbitrary-length body

    final pk1 = _polyKey(k2, nonce);
    final encBody = _xor(k2, nonce, 1, plaintext);
    expect(encBody, isNotNull);
    final pk2 = _polyKey(k2, nonce);
    expect(pk2, pk1);
  });

  test('chacha20-poly1305@openssh.com round-trips a basic packet', () {
    // 64-byte SSH key block: K_2 (body) || K_1 (length).
    final key = Uint8List.fromList(List.generate(64, (i) => i & 0xff));
    // Use independent copies (NOT sublistView) — sharing storage with
    // a downstream cipher operation can subtly alter buffer state.
    final k2 = Uint8List.fromList(key.sublist(0, 32));
    final k1 = Uint8List.fromList(key.sublist(32, 64));

    final payload = Uint8List.fromList('Hello, OpenSSH!'.codeUnits);
    const seq = 42;

    // ── encrypt ───────────────────────────────────────────────
    final paddingLen = _alignPadding(payload.length);
    final packetLen = 1 + payload.length + paddingLen;
    final plaintext = Uint8List(packetLen)
      ..[0] = paddingLen
      ..setRange(1, 1 + payload.length, payload);
    // Padding bytes deliberately deterministic for the test.
    for (var i = 0; i < paddingLen; i++) {
      plaintext[1 + payload.length + i] = i;
    }

    final nonce = _nonce8(seq);
    final lenBytes = Uint8List(4)..buffer.asByteData().setUint32(0, packetLen);
    final encLen = _xor(k1, nonce, 0, lenBytes);
    final encBody = _xor(k2, nonce, 1, plaintext);
    // Note: Poly1305.init() clamps the key bytes IN PLACE
    // (pointycastle/macs/poly1305.dart:115). Pass a copy so we can
    // still reason about the original keystream byte layout below.
    final pk = _polyKey(k2, nonce);
    final poly = Poly1305()..init(KeyParameter(Uint8List.fromList(pk)));
    poly.update(encLen, 0, encLen.length);
    poly.update(encBody, 0, encBody.length);
    final tag = Uint8List(16);
    poly.doFinal(tag, 0);

    // ── decrypt (mirror of receive path) ──────────────────────
    final decLenBytes = _xor(k1, nonce, 0, encLen);
    final decPacketLen = ByteData.sublistView(decLenBytes).getUint32(0);
    expect(decPacketLen, packetLen);

    final pkVerify = _polyKey(k2, nonce);
    expect(pkVerify, pk,
        reason: 'fresh derivations of the poly key must match');

    final polyVerify = Poly1305()..init(KeyParameter(Uint8List.fromList(pkVerify)));
    polyVerify.update(encLen, 0, encLen.length);
    polyVerify.update(encBody, 0, encBody.length);
    final tagVerify = Uint8List(16);
    polyVerify.doFinal(tagVerify, 0);
    expect(tagVerify, tag);

    final decBody = _xor(k2, nonce, 1, encBody);
    expect(decBody, plaintext, reason: 'body must round-trip');
    expect(decBody[0], paddingLen);
    expect(
      Uint8List.sublistView(decBody, 1, 1 + payload.length),
      payload,
      reason: 'extracted payload must equal original',
    );
  });

  test('different sequence numbers produce different ciphertexts', () {
    final key = Uint8List.fromList(List.generate(64, (i) => i & 0xff));
    final k2 = Uint8List.sublistView(key, 0, 32);
    final payload = Uint8List.fromList(List.filled(32, 0x41));

    final out1 = _xor(k2, _nonce8(1), 1, payload);
    final out2 = _xor(k2, _nonce8(2), 1, payload);
    expect(out1, isNot(out2),
        reason: 'distinct nonces must yield distinct keystreams');
  });

  test('tampered ciphertext changes Poly1305 tag', () {
    final key = Uint8List.fromList(List.generate(64, (i) => i & 0xff));
    final k2 = Uint8List.sublistView(key, 0, 32);
    final nonce = _nonce8(7);

    final body = Uint8List.fromList(List.generate(40, (i) => i));
    final encBody = _xor(k2, nonce, 1, body);
    final pk = _polyKey(k2, nonce);

    final poly = Poly1305()..init(KeyParameter(pk));
    poly.update(encBody, 0, encBody.length);
    final tag1 = Uint8List(16);
    poly.doFinal(tag1, 0);

    encBody[10] ^= 0x01; // flip a bit
    final poly2 = Poly1305()..init(KeyParameter(pk));
    poly2.update(encBody, 0, encBody.length);
    final tag2 = Uint8List(16);
    poly2.doFinal(tag2, 0);

    expect(tag2, isNot(tag1),
        reason: 'a one-bit change must alter the Poly1305 tag');
  });
}
