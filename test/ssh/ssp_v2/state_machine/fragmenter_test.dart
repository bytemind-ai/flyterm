import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/state_machine/fragmenter.dart';

void main() {
  test('payload <= MTU body produces single final fragment', () {
    final f = Fragmenter(mtu: 100);
    final frags = f.split(seq: 1, payload: Uint8List(50));
    expect(frags, hasLength(1));
    expect(frags.first.isFinal, true);
    expect(frags.first.index, 0);
  });

  test('payload > MTU splits and reassembles', () {
    final f = Fragmenter(mtu: 100);
    final payload =
        Uint8List(350)..setAll(0, List.generate(350, (i) => i & 0xff));
    final frags = f.split(seq: 7, payload: payload);
    expect(frags.length, greaterThan(1));
    expect(frags.last.isFinal, true);
    final asm = FragmentAssembler();
    Uint8List? out;
    for (final fr in frags) {
      out = asm.feed(fr);
    }
    expect(out, payload);
  });

  test('encode/decode fragment roundtrip', () {
    final f = Fragment(42, 3 | 0x8000, Uint8List.fromList([1, 2, 3]));
    final w = f.encode();
    final d = Fragment.decode(w);
    expect(d.seq, 42);
    expect(d.index, 3);
    expect(d.isFinal, true);
    expect(d.body, Uint8List.fromList([1, 2, 3]));
  });

  test('out-of-order fragments still reassemble', () {
    final f = Fragmenter(mtu: 30);
    final payload = Uint8List.fromList(List.generate(80, (i) => i));
    final frags = f.split(seq: 5, payload: payload);
    expect(frags.length, greaterThanOrEqualTo(3));
    final asm = FragmentAssembler();
    final reordered = [frags.last, frags.first, ...frags.sublist(1, frags.length - 1)];
    Uint8List? out;
    for (final fr in reordered) {
      out = asm.feed(fr);
    }
    expect(out, payload);
  });
}
