// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::Packet::tostring / Packet(string) in src/network/network.cc
//
// Wire layout: [8-byte nonce] [OCB ciphertext + 16-byte tag]
//
// Mosh historically reserved a 64-bit OCB sequence number on the wire.
// The 96-bit OCB nonce is reconstructed by zero-padding the leading
// 4 bytes (`{0,0,0,0} || 8-byte wire nonce`) — the v1 codepath does the
// same in `_makeNonce12`, and mosh-server enforces this layout. Sending
// the full 12-byte nonce on the wire (as v2 originally did) makes the
// real server treat the extra bytes as ciphertext and OCB authentication
// fails on the very first packet.
import 'dart:typed_data';
import 'ocb_cipher.dart';

class MoshPacket {
  /// 12-byte OCB nonce used by the cipher.
  final Uint8List nonce;
  final Uint8List plaintext;

  MoshPacket({required this.nonce, required this.plaintext});

  static Uint8List encode({
    required Uint8List nonce,
    required Uint8List plaintext,
    required OcbCipher cipher,
    Uint8List? associatedData,
  }) {
    if (nonce.length != 12) {
      throw ArgumentError('nonce must be 12 bytes, got ${nonce.length}');
    }
    final ad = associatedData ?? Uint8List(0);
    final ct = cipher.encrypt(nonce, plaintext, ad);
    final out = Uint8List(8 + ct.length);
    // Drop the leading 4 zero bytes of the 12-byte nonce — wire carries
    // only the trailing 8-byte sequence number, matching v1 + reference
    // mosh-server.
    out.setRange(0, 8, nonce, 4);
    out.setRange(8, out.length, ct);
    return out;
  }

  static MoshPacket decode(
    Uint8List wire, {
    required OcbCipher cipher,
    Uint8List? associatedData,
  }) {
    if (wire.length < 8 + 16) {
      throw FormatException('packet too short: ${wire.length}');
    }
    final ad = associatedData ?? Uint8List(0);
    // Reconstruct the 12-byte OCB nonce: 4 zero bytes || 8-byte wire nonce.
    final nonce = Uint8List(12);
    nonce.setRange(4, 12, Uint8List.sublistView(wire, 0, 8));
    final ct = Uint8List.sublistView(wire, 8);
    final pt = cipher.decrypt(nonce, ct, ad);
    return MoshPacket(nonce: nonce, plaintext: pt);
  }
}
