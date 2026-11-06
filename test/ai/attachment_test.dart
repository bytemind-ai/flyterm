import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/attachment.dart';

void main() {
  group('Attachment 序列化', () {
    const img = Attachment(
      kind: AttachmentKind.image,
      relPath: 'srv-1/abc.png',
      mime: 'image/png',
      bytes: 12345,
      name: 'screenshot.png',
    );

    test('toJson / fromJson 往返', () {
      final back = Attachment.fromJson(img.toJson());
      expect(back, isNotNull);
      expect(back!.kind, AttachmentKind.image);
      expect(back.relPath, 'srv-1/abc.png');
      expect(back.mime, 'image/png');
      expect(back.bytes, 12345);
      expect(back.name, 'screenshot.png');
    });

    test('b64 不进 toJson —— 那会把 base64 写进归档', () {
      final withB64 = img.withB64('AAAA');
      expect(withB64.b64, 'AAAA');
      expect(withB64.toJson().containsKey('b64'), isFalse);
    });

    test('relPath 缺失或空 → fromJson 返回 null 而不是抛', () {
      // 归档是用户数据，一条坏记录不该让整段会话打不开。
      expect(Attachment.fromJson({'kind': 'image'}), isNull);
      expect(Attachment.fromJson({'kind': 'image', 'relPath': ''}), isNull);
    });

    test('未知 kind 退化为 text，不抛', () {
      final a = Attachment.fromJson({'kind': 'video', 'relPath': 'x/y.mp4'});
      expect(a?.kind, AttachmentKind.text);
    });

    test('name 为 null 时不出现在 json 里', () {
      const noName = Attachment(
          kind: AttachmentKind.text,
          relPath: 'a/b.log',
          mime: 'text/plain',
          bytes: 10);
      expect(noName.toJson().containsKey('name'), isFalse);
    });
  });

  group('imageCount', () {
    test('只有图片计入，text 不计', () {
      const image = Attachment(
          kind: AttachmentKind.image,
          relPath: 'a/1.png',
          mime: 'image/png',
          bytes: 1);
      const text = Attachment(
          kind: AttachmentKind.text,
          relPath: 'a/2.log',
          mime: 'text/plain',
          bytes: 1);
      expect(imageCount([image]), 1);
      expect(imageCount([image, image]), 2);
      expect(imageCount([text]), 0,
          reason: 'text 的正文已经进 content 了，再计一次是重复计费');
      expect(imageCount(null), 0);
    });

    test('kImageTokens 是 token 数，不是字符数', () {
      // 旧值 5600 是 1600 token × 3.5 折算出来的字符数。改完之后这个常量
      // 直接就是 token —— 这一条钉住它不会被人「顺手」改回字符口径。
      expect(kImageTokens, 1600);
    });
  });
}
