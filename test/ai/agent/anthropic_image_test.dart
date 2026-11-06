import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/attachment.dart';
import 'package:flyterm/ai/providers/anthropic_provider.dart';

void main() {
  const img = Attachment(
    kind: AttachmentKind.image,
    relPath: 's/1.png',
    mime: 'image/png',
    bytes: 4,
    b64: 'QUJDRA==',
  );

  test('有图时 content 变成数组，图在文字之前', () {
    final msgs = buildAnthropicMessages([
      const AIMessage(role: 'user', content: '看这张', attachments: [img])
    ]);
    final content = msgs.single['content'] as List;
    expect(content.first['type'], 'image');
    expect(content.first['source']['type'], 'base64');
    expect(content.first['source']['media_type'], 'image/png');
    expect(content.first['source']['data'], 'QUJDRA==');
    expect(content.last['type'], 'text');
    expect(content.last['text'], '看这张');
  });

  test('没有图时 content 仍是字符串 —— 不改变既有请求体', () {
    final msgs =
        buildAnthropicMessages([const AIMessage(role: 'user', content: 'hi')]);
    expect(msgs.single['content'], 'hi');
  });

  test('b64 未物化的图片被跳过，不发半截请求', () {
    const noB64 = Attachment(
        kind: AttachmentKind.image,
        relPath: 's/2.png',
        mime: 'image/png',
        bytes: 4);
    final msgs = buildAnthropicMessages([
      const AIMessage(role: 'user', content: 'x', attachments: [noB64])
    ]);
    expect(msgs.single['content'], 'x');
  });

  test('text 类附件不进 content 数组', () {
    const t = Attachment(
        kind: AttachmentKind.text,
        relPath: 's/a.log',
        mime: 'text/plain',
        bytes: 1);
    final msgs = buildAnthropicMessages([
      const AIMessage(role: 'user', content: '日志正文在这里', attachments: [t])
    ]);
    expect(msgs.single['content'], '日志正文在这里');
  });
}
