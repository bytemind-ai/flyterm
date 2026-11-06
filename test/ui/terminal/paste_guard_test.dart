import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/terminal/paste_guard.dart';

void main() {
  group('classifyPaste', () {
    test('null clipboard → empty', () {
      expect(classifyPaste(null, connected: true), PasteRejection.empty);
    });

    test('empty string → empty', () {
      expect(classifyPaste('', connected: true), PasteRejection.empty);
    });

    test('not connected → disconnected', () {
      expect(classifyPaste('ls', connected: false), PasteRejection.disconnected);
    });

    test('normal text while connected → none', () {
      expect(classifyPaste('ls -la', connected: true), PasteRejection.none);
    });

    test('exactly at the byte limit → none', () {
      expect(
        classifyPaste('abcd', connected: true, maxBytes: 4),
        PasteRejection.none,
      );
    });

    test('one byte over the limit → tooLarge', () {
      expect(
        classifyPaste('abcd', connected: true, maxBytes: 3),
        PasteRejection.tooLarge,
      );
    });

    // The important one: the limit is UTF-8 BYTES, not UTF-16 code units.
    // '中' is 1 code unit but 3 bytes, so a String.length check would let
    // through 3x more data than intended.
    test('CJK is measured in utf8 bytes, not String.length', () {
      final cjk = '中' * 10; // length 10, 30 utf8 bytes
      expect(cjk.length, 10);
      expect(
        classifyPaste(cjk, connected: true, maxBytes: 20),
        PasteRejection.tooLarge,
      );
      expect(
        classifyPaste(cjk, connected: true, maxBytes: 30),
        PasteRejection.none,
      );
    });

    test('empty is reported before disconnected', () {
      expect(classifyPaste('', connected: false), PasteRejection.empty);
    });

    test('disconnected is reported before tooLarge', () {
      expect(
        classifyPaste('abcd', connected: false, maxBytes: 3),
        PasteRejection.disconnected,
      );
    });

    test('default limit is 256 KiB', () {
      expect(kMaxPasteBytes, 256 * 1024);
    });
  });

  group('pasteByteSize', () {
    test('ASCII is 1 byte per character', () {
      expect(pasteByteSize('ab'), 2);
    });

    test('CJK is 3 bytes per character', () {
      expect(pasteByteSize('中'), 3);
    });

    test('mixed ASCII and CJK', () {
      expect(pasteByteSize('a中'), 4); // 1 + 3
    });
  });
}
