import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/token_estimate.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/attachment.dart';

void main() {
  const img = Attachment(
      kind: AttachmentKind.image,
      relPath: 'a/1.png',
      mime: 'image/png',
      bytes: 1);
  const txt = Attachment(
      kind: AttachmentKind.text,
      relPath: 'a/2.log',
      mime: 'text/plain',
      bytes: 1);

  test('带一张图比不带图多算 kImageTokens', () {
    const plain = AIMessage(role: 'user', content: 'hello');
    const withImg =
        AIMessage(role: 'user', content: 'hello', attachments: [img]);
    expect(estimateMessageTokens(withImg) - estimateMessageTokens(plain),
        kImageTokens,
        reason: '不加这一项，预算熔断会在最该停的时候不停');
  });

  test('text 类附件不额外计费 —— 正文已在 content 里', () {
    const plain = AIMessage(role: 'user', content: 'hello');
    const withTxt =
        AIMessage(role: 'user', content: 'hello', attachments: [txt]);
    expect(estimateMessageTokens(withTxt), estimateMessageTokens(plain));
  });

  test('两张图翻倍', () {
    const two =
        AIMessage(role: 'user', content: '', attachments: [img, img]);
    expect(estimateMessageTokens(two), kImageTokens * 2);
  });
}
