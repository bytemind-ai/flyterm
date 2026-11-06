// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::Nonce in src/network/network.h
//
// Nonce wire layout (8 bytes on the wire, padded to 12 for OCB):
//   bytes[0..4] always zero (mosh historical reserve, not transmitted).
//   bytes[4..12] = 64-bit big-endian sequence number whose top bit is
//                  the direction flag (0 = client→server, 1 = server→client).
//                  This matches mosh-server's `Nonce::cc_str()` /
//                  `Nonce::val()` and the reflection-attack guard in
//                  `Connection::recv_one`.
//
// Earlier drafts wrote 0x80 to `out[0]` to encode direction; that byte
// gets stripped before the wire (only out[4..12] travels) so the flag
// was effectively zero on every packet. Real mosh-server then dropped
// our packets either as "wrong direction" or via OCB tag mismatch.
import 'dart:math';
import 'dart:typed_data';

enum NonceDirection { client, server }

class NonceGenerator {
  static final _rand = Random.secure();
  final NonceDirection direction;
  int _counter;

  NonceGenerator({required this.direction})
      : _counter = _rand.nextInt(1 << 31);

  Uint8List next() {
    final out = Uint8List(12);
    final c = _counter++;
    // High bit of byte[4] = direction flag (server = 1).
    final dirBit = direction == NonceDirection.server ? 0x80 : 0x00;
    out[4] = ((c >> 56) & 0x7f) | dirBit;
    out[5] = (c >> 48) & 0xff;
    out[6] = (c >> 40) & 0xff;
    out[7] = (c >> 32) & 0xff;
    out[8] = (c >> 24) & 0xff;
    out[9] = (c >> 16) & 0xff;
    out[10] = (c >> 8) & 0xff;
    out[11] = c & 0xff;
    return out;
  }
}
