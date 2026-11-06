// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

// ── TransportBuffers::Instruction ──────────────────────────────────────────
// transportinstruction.proto:
//   field 1: protocol_version (uint32)  — always 2 (MOSH_PROTOCOL_VERSION)
//   field 2: old_num          (uint64)
//   field 3: new_num          (uint64)
//   field 4: ack_num          (uint64)
//   field 5: throwaway_num    (uint64)
//   field 6: diff             (bytes)   — serialized UserMessage or HostMessage
//   field 7: chaff            (bytes)   — random padding, ignored

class TransportInstruction {
  static const int kProtocolVersion = 2;

  final int oldNum;
  final int newNum;
  final int ackNum;
  final int throwawayNum;
  final Uint8List diff;
  final Uint8List? chaff; // field 7: random padding; ignored by server

  TransportInstruction({
    required this.oldNum,
    required this.newNum,
    required this.ackNum,
    required this.throwawayNum,
    Uint8List? diff,
    this.chaff,
  }) : diff = diff ?? Uint8List(0);

  Uint8List encode() {
    // BytesBuilder uses chunked storage and a single takeBytes() copy
    // at the end — avoids the dynamic List<int> growth + final
    // Uint8List.fromList copy.
    final bb = BytesBuilder(copy: false);
    _Proto.writeVarintField(bb, 1, kProtocolVersion);
    _Proto.writeVarintField(bb, 2, oldNum);
    _Proto.writeVarintField(bb, 3, newNum);
    _Proto.writeVarintField(bb, 4, ackNum);
    _Proto.writeVarintField(bb, 5, throwawayNum);
    if (diff.isNotEmpty) _Proto.writeBytesField(bb, 6, diff);
    if (chaff != null && chaff!.isNotEmpty) _Proto.writeBytesField(bb, 7, chaff!);
    return bb.takeBytes();
  }

  factory TransportInstruction.decode(Uint8List bytes) {
    int oldNum = 0, newNum = 0, ackNum = 0, throwawayNum = 0;
    Uint8List diff = Uint8List(0);

    int pos = 0;
    while (pos < bytes.length) {
      final (fieldNum, wireType, pos1) = _Proto.readTag(bytes, pos);
      pos = pos1;
      if (wireType == 0) {
        final (value, pos2) = _Proto.readVarint(bytes, pos);
        pos = pos2;
        switch (fieldNum) {
          case 2:
            oldNum = value;
          case 3:
            newNum = value;
          case 4:
            ackNum = value;
          case 5:
            throwawayNum = value;
        }
      } else if (wireType == 2) {
        final (length, pos3) = _Proto.readVarint(bytes, pos);
        pos = pos3;
        final data = Uint8List.sublistView(bytes, pos, pos + length);
        pos += length;
        if (fieldNum == 6) diff = data;
      } else {
        break; // unknown wire type
      }
    }
    return TransportInstruction(
      oldNum: oldNum,
      newNum: newNum,
      ackNum: ackNum,
      throwawayNum: throwawayNum,
      diff: diff,
    );
  }
}

// ── ClientBuffers::UserMessage (client → server diff) ──────────────────────
// userinput.proto:
//   UserMessage { repeated Instruction instruction = 1; }
//   extend Instruction { optional Keystroke keystroke = 2; }  → Keystroke { optional bytes keys = 4; }
//   extend Instruction { optional ResizeMessage resize = 3; } → ResizeMessage { width=5, height=6 }

class MoshUserMessage {
  /// Pack all input bytes into a single Keystroke within one Instruction.
  static Uint8List encodeKeystrokes(List<int> bytes) {
    if (bytes.isEmpty) return Uint8List(0);
    final keystroke = BytesBuilder(copy: false);
    _Proto.writeBytesField(
        keystroke, 4, bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    final inst = BytesBuilder(copy: false);
    _Proto.writeBytesField(inst, 2, keystroke.takeBytes());
    final msg = BytesBuilder(copy: false);
    _Proto.writeBytesField(msg, 1, inst.takeBytes());
    return msg.takeBytes();
  }

  /// Encode a terminal resize event.
  static Uint8List encodeResize(int width, int height) {
    final resize = BytesBuilder(copy: false);
    _Proto.writeVarintField(resize, 5, width);
    _Proto.writeVarintField(resize, 6, height);
    final inst = BytesBuilder(copy: false);
    _Proto.writeBytesField(inst, 3, resize.takeBytes());
    final msg = BytesBuilder(copy: false);
    _Proto.writeBytesField(msg, 1, inst.takeBytes());
    return msg.takeBytes();
  }
}

// ── HostBuffers::HostMessage (server → client diff) ────────────────────────
// hostinput.proto:
//   HostMessage { repeated Instruction instruction = 1; }
//   extend Instruction { optional HostBytes hostbytes = 2; }  → HostBytes { optional bytes hoststring = 4; }
//   extend Instruction { optional ResizeMessage resize = 3; } → ResizeMessage { width=5, height=6 }
//   extend Instruction { optional EchoAck echoack = 7; }

class MoshHostMessage {
  /// Extract concatenated raw VT100 bytes from all hoststring fields.
  /// These bytes come from Display::new_frame() and are fed directly to xterm.
  static Uint8List extractHostBytes(Uint8List diffBytes) {
    if (diffBytes.isEmpty) return Uint8List(0);
    final result = <int>[];
    int pos = 0;
    while (pos < diffBytes.length) {
      final (fieldNum, wireType, pos1) = _Proto.readTag(diffBytes, pos);
      pos = pos1;
      if (wireType == 0) {
        final (_, pos2) = _Proto.readVarint(diffBytes, pos);
        pos = pos2;
      } else if (wireType == 2) {
        final (length, pos3) = _Proto.readVarint(diffBytes, pos);
        pos = pos3;
        final data = Uint8List.sublistView(diffBytes, pos, pos + length);
        pos += length;
        if (fieldNum == 1) {
          // HostMessage.instruction — recurse into each Instruction
          result.addAll(_extractFromInstruction(data));
        }
      } else {
        break;
      }
    }
    return Uint8List.fromList(result);
  }

  static List<int> _extractFromInstruction(Uint8List bytes) {
    final result = <int>[];
    int pos = 0;
    while (pos < bytes.length) {
      final (fieldNum, wireType, pos1) = _Proto.readTag(bytes, pos);
      pos = pos1;
      if (wireType == 0) {
        final (_, pos2) = _Proto.readVarint(bytes, pos);
        pos = pos2;
      } else if (wireType == 2) {
        final (length, pos3) = _Proto.readVarint(bytes, pos);
        pos = pos3;
        final data = Uint8List.sublistView(bytes, pos, pos + length);
        pos += length;
        if (fieldNum == 2) {
          // Extension field 2 = HostBytes
          result.addAll(_extractHostString(data));
        }
      } else {
        break;
      }
    }
    return result;
  }

  static List<int> _extractHostString(Uint8List bytes) {
    int pos = 0;
    while (pos < bytes.length) {
      final (fieldNum, wireType, pos1) = _Proto.readTag(bytes, pos);
      pos = pos1;
      if (wireType == 0) {
        final (_, pos2) = _Proto.readVarint(bytes, pos);
        pos = pos2;
      } else if (wireType == 2) {
        final (length, pos3) = _Proto.readVarint(bytes, pos);
        pos = pos3;
        final data = Uint8List.sublistView(bytes, pos, pos + length);
        pos += length;
        if (fieldNum == 4) {
          // HostBytes.hoststring — the raw VT100 bytes
          return data;
        }
      } else {
        break;
      }
    }
    return [];
  }
}

// ── Minimal protobuf encoding/decoding helpers ─────────────────────────────

class _Proto {
  _Proto._();

  static void writeVarint(BytesBuilder buf, int value) {
    while (value >= 0x80) {
      buf.addByte((value & 0x7F) | 0x80);
      value >>= 7;
    }
    buf.addByte(value & 0x7F);
  }

  static void writeVarintField(BytesBuilder buf, int field, int value) {
    writeVarint(buf, (field << 3) | 0); // wire_type 0 = varint
    writeVarint(buf, value);
  }

  static void writeBytesField(BytesBuilder buf, int field, Uint8List value) {
    writeVarint(buf, (field << 3) | 2); // wire_type 2 = length-delimited
    writeVarint(buf, value.length);
    buf.add(value);
  }

  static (int fieldNum, int wireType, int pos) readTag(Uint8List bytes, int pos) {
    final (tag, newPos) = readVarint(bytes, pos);
    return (tag >> 3, tag & 0x07, newPos);
  }

  static (int value, int pos) readVarint(Uint8List bytes, int pos) {
    int value = 0, shift = 0;
    while (pos < bytes.length) {
      final b = bytes[pos++];
      value |= (b & 0x7F) << shift;
      shift += 7;
      if ((b & 0x80) == 0) break;
    }
    return (value, pos);
  }
}
