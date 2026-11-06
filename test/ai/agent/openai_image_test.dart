import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/attachment.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';

void main() {
  const img = Attachment(
    kind: AttachmentKind.image,
    relPath: 's/1.jpg',
    mime: 'image/jpeg',
    bytes: 4,
    b64: 'QUJDRA==',
  );

  test('有图时 content 变数组，url 是 data: 前缀', () {
    final msgs = buildOpenAIContent([
      const AIMessage(role: 'user', content: '看这张', attachments: [img])
    ]);
    final content = msgs.single['content'] as List;
    expect(content.first['type'], 'image_url');
    expect(content.first['image_url']['url'],
        'data:image/jpeg;base64,QUJDRA==');
    expect(content.last['type'], 'text');
    expect(content.last['text'], '看这张');
  });

  test('没有图时 content 仍是字符串', () {
    final msgs =
        buildOpenAIContent([const AIMessage(role: 'user', content: 'hi')]);
    expect(msgs.single['content'], 'hi');
  });

  test('b64 未物化 → 跳过', () {
    const noB64 = Attachment(
        kind: AttachmentKind.image,
        relPath: 's/2.jpg',
        mime: 'image/jpeg',
        bytes: 4);
    final msgs = buildOpenAIContent([
      const AIMessage(role: 'user', content: 'x', attachments: [noB64])
    ]);
    expect(msgs.single['content'], 'x');
  });
}
