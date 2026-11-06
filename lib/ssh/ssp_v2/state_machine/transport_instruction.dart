// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::TransportBuffers::Instruction (transportinstruction.proto)
//   field 1: protocol_version (varint, always 2)
//   field 2: old_num          (varint)
//   field 3: new_num          (varint)
//   field 4: ack_num          (varint)
//   field 5: throwaway_num    (varint)
//   field 6: diff             (bytes)
//   field 7: chaff            (bytes, optional padding)
import 'dart:typed_data';

class TransportInstruction {
  static const int kProtocolVersion = 2;

  final int protocolVersion;
  final int oldNum;
  final int newNum;
  final int ackNum;
  final int throwawayNum;
  final Uint8List diff;
  final Uint8List chaff;

  TransportInstruction({
    this.protocolVersion = kProtocolVersion,
    required this.oldNum,
    required this.newNum,
    required this.ackNum,
    required this.throwawayNum,
    Uint8List? diff,
    Uint8List? chaff,
  })  : diff = diff ?? Uint8List(0),
        chaff = chaff ?? Uint8List(0);

  Uint8List encode() {
    final bb = BytesBuilder(copy: false);
    _writeVarint(bb, 1, protocolVersion);
    _writeVarint(bb, 2, oldNum);
    _writeVarint(bb, 3, newNum);
    _writeVarint(bb, 4, ackNum);
    _writeVarint(bb, 5, throwawayNum);
    if (diff.isNotEmpty) _writeBytes(bb, 6, diff);
    if (chaff.isNotEmpty) _writeBytes(bb, 7, chaff);
    return bb.takeBytes();
  }

  static TransportInstruction decode(Uint8List bytes) {
    int pv = kProtocolVersion, oldN = 0, newN = 0, ackN = 0, thN = 0;
    Uint8List diff = Uint8List(0);
    Uint8List chaff = Uint8List(0);
    int i = 0;
    while (i < bytes.length) {
      final tag = _readVarint(bytes, i);
      i = tag.next;
      final field = tag.value >> 3;
      final wire = tag.value & 7;
      if (wire == 0) {
        final v = _readVarint(bytes, i);
        i = v.next;
        switch (field) {
          case 1:
            pv = v.value;
            break;
          case 2:
            oldN = v.value;
            break;
          case 3:
            newN = v.value;
            break;
          case 4:
            ackN = v.value;
            break;
          case 5:
            thN = v.value;
            break;
        }
      } else if (wire == 2) {
        final len = _readVarint(bytes, i);
        i = len.next;
        final slice = Uint8List.sublistView(bytes, i, i + len.value);
        i += len.value;
        if (field == 6) diff = Uint8List.fromList(slice);
        if (field == 7) chaff = Uint8List.fromList(slice);
      } else {
        // Unknown wire type: stop parsing this message (match v1 break behavior).
        // v2 previously threw FormatException here; that made Stage-4 catch
        // increment protoFailCount for any future mosh field we don't know,
        // preventing _supervisor.onPacket from recording the packet.
        break;
      }
    }
    return TransportInstruction(
      protocolVersion: pv,
      oldNum: oldN,
      newNum: newN,
      ackNum: ackN,
      throwawayNum: thN,
      diff: diff,
      chaff: chaff,
    );
  }
}

void _writeVarint(BytesBuilder bb, int field, int value) {
  bb.addByte((field << 3));
  var v = value;
  while (v >= 0x80) {
    bb.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  bb.addByte(v & 0x7f);
}

void _writeBytes(BytesBuilder bb, int field, Uint8List data) {
  bb.addByte((field << 3) | 2);
  var v = data.length;
  while (v >= 0x80) {
    bb.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  bb.addByte(v & 0x7f);
  bb.add(data);
}

class _Varint {
  final int value;
  final int next;
  _Varint(this.value, this.next);
}

_Varint _readVarint(Uint8List b, int start) {
  int v = 0, shift = 0, i = start;
  while (true) {
    final byte = b[i++];
    v |= (byte & 0x7f) << shift;
    if ((byte & 0x80) == 0) break;
    shift += 7;
  }
  return _Varint(v, i);
}
