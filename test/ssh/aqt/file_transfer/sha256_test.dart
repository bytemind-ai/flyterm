import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/file_transfer/sha256_streaming.dart';
import 'package:crypto/crypto.dart';

void main() {
  test('computeFileSha256 matches known hash', () async {
    final f = File('/tmp/aqt_sha_test.txt');
    await f.writeAsString('hello world');
    final h = await computeFileSha256(f);
    final expected = sha256.convert('hello world'.codeUnits).bytes;
    expect(h, Uint8List.fromList(expected));
    await f.delete();
  });

  test('IncrementalSha256 matches single-shot', () {
    final inc = IncrementalSha256();
    inc.update('hello '.codeUnits);
    inc.update('world'.codeUnits);
    final got = inc.finalize();
    final expected = sha256.convert('hello world'.codeUnits).bytes;
    expect(got, Uint8List.fromList(expected));
  });
}
