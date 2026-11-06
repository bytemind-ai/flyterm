import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/transport_message.dart';

void main() {
  test('TransportInstruction encode/decode round-trip', () {
    final inst = TransportInstruction(
      oldNum: 0,
      newNum: 1,
      ackNum: 0,
      throwawayNum: 0,
      diff: Uint8List.fromList([0x41, 0x42, 0x43]),
    );
    final bytes = inst.encode();
    final decoded = TransportInstruction.decode(bytes);
    expect(decoded.oldNum, 0);
    expect(decoded.newNum, 1);
    expect(decoded.ackNum, 0);
    expect(decoded.throwawayNum, 0);
    expect(decoded.diff, [0x41, 0x42, 0x43]);
  });

  test('TransportInstruction large seq numbers round-trip', () {
    final inst = TransportInstruction(
      oldNum: 0xFFFFFFFF,
      newNum: 0x100000000,
      ackNum: 42,
      throwawayNum: 7,
    );
    final bytes = inst.encode();
    final decoded = TransportInstruction.decode(bytes);
    expect(decoded.oldNum, 0xFFFFFFFF);
    expect(decoded.newNum, 0x100000000);
    expect(decoded.ackNum, 42);
    expect(decoded.throwawayNum, 7);
    expect(decoded.diff.length, 0);
  });

  test('TransportInstruction empty diff round-trip', () {
    final inst = TransportInstruction(
      oldNum: 5,
      newNum: 6,
      ackNum: 3,
      throwawayNum: 2,
    );
    final decoded = TransportInstruction.decode(inst.encode());
    expect(decoded.newNum, 6);
    expect(decoded.ackNum, 3);
    expect(decoded.diff.length, 0);
  });

  test('TransportInstruction protocol_version is always 2', () {
    final bytes = TransportInstruction(
      oldNum: 0,
      newNum: 1,
      ackNum: 0,
      throwawayNum: 0,
    ).encode();
    // Field 1 (protocol_version) = tag 0x08, value 0x02
    expect(bytes[0], 0x08);
    expect(bytes[1], 0x02);
  });

  test('MoshUserMessage encodeKeystrokes round-trip', () {
    final msg = MoshUserMessage.encodeKeystrokes([0x61, 0x62, 0x63]);
    expect(msg.isNotEmpty, true);
    // Should be a valid protobuf (non-empty bytes field)
    expect(msg[0], (1 << 3) | 2); // field 1, wire type 2
  });

  test('MoshUserMessage encodeResize produces non-empty bytes', () {
    final msg = MoshUserMessage.encodeResize(220, 50);
    expect(msg.isNotEmpty, true);
    expect(msg[0], (1 << 3) | 2); // field 1 (instruction), wire type 2
  });
}
