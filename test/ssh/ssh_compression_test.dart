// Sanity round-trip test for the same RawZLibFilter contract that
// dartssh2's SSHTransport uses (Z_SYNC_FLUSH-per-packet, stateful
// dictionary). Verifies that
//
//   1. Repeated identical payloads compress significantly (the
//      shared dictionary lets the second copy reduce to near-zero).
//   2. Multiple chunks compressed-then-decompressed in order
//      reproduce the original bytes — i.e. the filter pair survives
//      the streaming SSH packet pattern.
//
// We don't drive a real SSHTransport here (would need a mock socket
// and full KEX); the codec primitive is the load-bearing piece.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SSH-style zlib (sync-flush) round-trips multi-packet streams', () {
    final compress = RawZLibFilter.deflateFilter(level: 6, raw: false);
    final decompress = RawZLibFilter.inflateFilter(raw: false);

    Uint8List compressOne(Uint8List data) {
      compress.process(data, 0, data.length);
      final out = <int>[];
      while (true) {
        final c = compress.processed(flush: true);
        if (c == null) break;
        out.addAll(c);
      }
      return Uint8List.fromList(out);
    }

    Uint8List decompressOne(Uint8List data) {
      decompress.process(data, 0, data.length);
      final out = <int>[];
      while (true) {
        final c = decompress.processed(flush: false);
        if (c == null) break;
        out.addAll(c);
      }
      return Uint8List.fromList(out);
    }

    final packets = [
      Uint8List.fromList(utf8.encode('hello world\n')),
      Uint8List.fromList(utf8.encode('hello world\n')), // repeated
      Uint8List.fromList(utf8.encode('total 12\ndrwxr-xr-x foo\n')),
      Uint8List.fromList(utf8.encode('drwxr-xr-x bar\ndrwxr-xr-x baz\n')),
    ];

    final compressed = packets.map(compressOne).toList();
    final decompressed = compressed.map(decompressOne).toList();

    for (var i = 0; i < packets.length; i++) {
      expect(decompressed[i], packets[i],
          reason: 'packet $i must round-trip');
    }

    // The second identical packet should be much smaller than the
    // first — proving the dictionary is shared across packets.
    expect(compressed[1].length, lessThan(compressed[0].length),
        reason: 'shared zlib dictionary should compress the repeat');
  });

  test('high-redundancy payload compresses to a small fraction', () {
    final compress = RawZLibFilter.deflateFilter(level: 6, raw: false);
    final big = Uint8List.fromList(
        utf8.encode('drwxr-xr-x  10 root  root  4096 ' * 200));
    compress.process(big, 0, big.length);
    final out = <int>[];
    while (true) {
      final c = compress.processed(flush: true);
      if (c == null) break;
      out.addAll(c);
    }
    expect(out.length, lessThan(big.length ~/ 5),
        reason: 'highly repetitive ls output should compress >5×');
  });
}
