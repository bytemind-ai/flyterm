import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/state_machine/transport_instruction.dart';

void main() {
  test('encode/decode all 7 fields', () {
    final i = TransportInstruction(
      protocolVersion: 2,
      oldNum: 5,
      newNum: 7,
      ackNum: 3,
      throwawayNum: 2,
      diff: Uint8List.fromList([10, 20, 30]),
      chaff: Uint8List.fromList([99]),
    );
    final bytes = i.encode();
    final d = TransportInstruction.decode(bytes);
    expect(d.protocolVersion, 2);
    expect(d.oldNum, 5);
    expect(d.newNum, 7);
    expect(d.ackNum, 3);
    expect(d.throwawayNum, 2);
    expect(d.diff, Uint8List.fromList([10, 20, 30]));
    expect(d.chaff, Uint8List.fromList([99]));
  });

  test('omits empty diff/chaff and decodes back to empty', () {
    final i = TransportInstruction(
      oldNum: 0,
      newNum: 0,
      ackNum: 0,
      throwawayNum: 0,
    );
    final d = TransportInstruction.decode(i.encode());
    expect(d.diff, Uint8List(0));
    expect(d.chaff, Uint8List(0));
  });

  test('large varint values roundtrip', () {
    final i = TransportInstruction(
      oldNum: 0xFFFFFFFF,
      newNum: 0x1FFFFFFFFF,
      ackNum: 0,
      throwawayNum: 0,
    );
    final d = TransportInstruction.decode(i.encode());
    expect(d.oldNum, 0xFFFFFFFF);
    expect(d.newNum, 0x1FFFFFFFFF);
  });
}
