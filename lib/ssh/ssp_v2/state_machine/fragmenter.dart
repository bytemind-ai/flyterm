// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::Fragmenter / FragmentAssembly in src/network/transportfragment.cc
//
// Wire layout per fragment: [seq:8][index:2][body...]
// The high bit of `index` marks the final fragment of a sequence.
import 'dart:typed_data';

class Fragment {
  final int seq;
  final int rawIndex; // includes final-bit in 0x8000
  final Uint8List body;

  Fragment(this.seq, this.rawIndex, this.body);

  bool get isFinal => (rawIndex & 0x8000) != 0;
  int get index => rawIndex & 0x7FFF;

  Uint8List encode() {
    final h = ByteData(10);
    h.setUint64(0, seq);
    h.setUint16(8, rawIndex);
    final out = Uint8List(10 + body.length);
    out.setRange(0, 10, h.buffer.asUint8List());
    out.setRange(10, out.length, body);
    return out;
  }

  static Fragment decode(Uint8List wire) {
    if (wire.length < 10) {
      throw FormatException('fragment too short: ${wire.length}');
    }
    final h = ByteData.sublistView(wire, 0, 10);
    return Fragment(
      h.getUint64(0),
      h.getUint16(8),
      Uint8List.fromList(Uint8List.sublistView(wire, 10)),
    );
  }
}

class Fragmenter {
  final int mtu;
  Fragmenter({this.mtu = 500});

  List<Fragment> split({required int seq, required Uint8List payload}) {
    final body = mtu - 10;
    if (payload.length <= body) {
      return [Fragment(seq, 0 | 0x8000, payload)];
    }
    final out = <Fragment>[];
    var i = 0, idx = 0;
    while (i < payload.length) {
      final end = (i + body).clamp(0, payload.length);
      final isLast = end == payload.length;
      final chunk = Uint8List.fromList(Uint8List.sublistView(payload, i, end));
      out.add(Fragment(seq, idx | (isLast ? 0x8000 : 0), chunk));
      i = end;
      idx++;
    }
    return out;
  }
}

class FragmentAssembler {
  static const _kTtl = Duration(seconds: 30);

  final _bySeq = <int, List<Fragment?>>{};
  final _totals = <int, int>{};
  final _firstSeen = <int, DateTime>{};

  // Diagnostic counters (debug overlay).
  // fragmentsReceived: every individual fragment fed in (Stage 2 inputs).
  // assembliesCompleted: distinct seq values that fully reassembled.
  // assembliesPending: current count of in-flight (incomplete) seqs.
  int fragmentsReceived = 0;
  int assembliesCompleted = 0;
  int get assembliesPending => _bySeq.length;

  Uint8List? feed(Fragment fr) {
    fragmentsReceived++;
    _expire(DateTime.now());
    final list = _bySeq.putIfAbsent(fr.seq, () => []);
    _firstSeen.putIfAbsent(fr.seq, () => DateTime.now());
    while (list.length <= fr.index) {
      list.add(null);
    }
    list[fr.index] = fr;
    if (fr.isFinal) _totals[fr.seq] = fr.index + 1;
    final total = _totals[fr.seq];
    if (total == null) return null;
    if (list.length < total) return null;
    if (list.take(total).any((e) => e == null)) return null;
    final bb = BytesBuilder(copy: false);
    for (var i = 0; i < total; i++) {
      bb.add(list[i]!.body);
    }
    _bySeq.remove(fr.seq);
    _totals.remove(fr.seq);
    _firstSeen.remove(fr.seq);
    assembliesCompleted++;
    return bb.takeBytes();
  }

  void _expire(DateTime now) {
    final expired =
        _firstSeen.entries
            .where((e) => now.difference(e.value) > _kTtl)
            .map((e) => e.key)
            .toList();
    for (final seq in expired) {
      _bySeq.remove(seq);
      _totals.remove(seq);
      _firstSeen.remove(seq);
    }
  }
}
