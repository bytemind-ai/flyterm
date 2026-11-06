// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Compute file sha256 in chunks (no full in-memory load).
Future<Uint8List> computeFileSha256(File file) async {
  final controller = StreamController<Digest>();
  final input = sha256.startChunkedConversion(controller.sink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  final digest = await controller.stream.first;
  return Uint8List.fromList(digest.bytes);
}

/// Incremental sha256 for streaming (e.g. while downloading).
class IncrementalSha256 {
  final _chunks = <List<int>>[];

  void update(List<int> bytes) => _chunks.add(bytes);

  Uint8List finalize() {
    final controller = StreamController<Digest>(sync: true);
    Digest? result;
    controller.stream.listen((d) => result = d);
    final input = sha256.startChunkedConversion(controller.sink);
    for (final c in _chunks) {
      input.add(c);
    }
    input.close();
    return Uint8List.fromList(result!.bytes);
  }
}
