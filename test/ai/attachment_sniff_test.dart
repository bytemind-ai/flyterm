import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/attachment.dart';
import 'package:flyterm/ai/attachment_sniff.dart';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  group('sniffAttachment', () {
    test('PNG 魔数 → image', () {
      final r = sniffAttachment(
          head: _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
          totalBytes: 2048,
          fileName: 'a.png');
      expect(r.kind, AttachmentKind.image);
      expect(r.mime, 'image/png');
      expect(r.rejectReason, isNull);
    });

    test('JPEG 魔数 → image', () {
      final r = sniffAttachment(
          head: _bytes([0xFF, 0xD8, 0xFF, 0xE0]),
          totalBytes: 2048,
          fileName: 'a.jpg');
      expect(r.kind, AttachmentKind.image);
      expect(r.mime, 'image/jpeg');
    });

    test('纯文本 → text，mime 统一 text/plain', () {
      final r = sniffAttachment(
          head: _bytes('worker_processes 4;\n'.codeUnits),
          totalBytes: 512,
          fileName: 'nginx.conf');
      expect(r.kind, AttachmentKind.text);
      expect(r.mime, 'text/plain',
          reason: '不按扩展名区分 conf/log/json —— 对模型侧没有意义');
    });

    test('含 NUL 且不是已知图片 → 拒绝', () {
      final r = sniffAttachment(
          head: _bytes([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01]),
          totalBytes: 999,
          fileName: 'a.out');
      expect(r.kind, isNull);
      expect(r.rejectReason, AttachmentReject.binary);
    });

    test('图片超过 3.5MB → 标记需要降采样，不是拒绝', () {
      final r = sniffAttachment(
          head: _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
          totalBytes: 5 * 1024 * 1024,
          fileName: 'big.png');
      expect(r.kind, AttachmentKind.image);
      expect(r.needsDownscale, isTrue);
      expect(r.rejectReason, isNull);
    });

    test('文本超过 64 KiB → 标记需要截断，不是拒绝', () {
      final r = sniffAttachment(
          head: _bytes('log line\n'.codeUnits),
          totalBytes: 200 * 1024,
          fileName: 'big.log');
      expect(r.kind, AttachmentKind.text);
      expect(r.needsTruncate, isTrue);
      expect(r.rejectReason, isNull);
    });

    test('空文件 → 拒绝', () {
      final r = sniffAttachment(
          head: _bytes([]), totalBytes: 0, fileName: 'empty.txt');
      expect(r.rejectReason, AttachmentReject.empty);
    });

    test('GIF/WebP 也认作 image', () {
      expect(
          sniffAttachment(
                  head: _bytes('GIF89a'.codeUnits),
                  totalBytes: 100,
                  fileName: 'a.gif')
              .mime,
          'image/gif');
      final webp = _bytes([
        0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, // RIFF + size
        0x57, 0x45, 0x42, 0x50, // WEBP
      ]);
      expect(
          sniffAttachment(head: webp, totalBytes: 100, fileName: 'a.webp')
              .mime,
          'image/webp');
    });
  });
}
