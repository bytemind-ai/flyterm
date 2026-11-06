import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/attachment.dart';
import 'package:flyterm/ai/providers/ollama_provider.dart';

void main() {
  const img = Attachment(
    kind: AttachmentKind.image,
    relPath: 's/1.png',
    mime: 'image/png',
    bytes: 4,
    b64: 'QUJDRA==',
  );

  test('图片挂在消息级 images 数组，content 仍是字符串', () {
    // Ollama 的格式与另两家完全不同：不是 content 数组的一个元素。
    final msgs = buildOllamaMessages([
      AIMessage(role: 'user', content: '看这张', attachments: [img])
    ]);
    expect(msgs.single['content'], '看这张');
    expect(msgs.single['images'], ['QUJDRA==']);
  });

  test('没有图时不出现 images 键', () {
    final msgs =
        buildOllamaMessages([const AIMessage(role: 'user', content: 'hi')]);
    expect(msgs.single.containsKey('images'), isFalse);
  });

  test('b64 未物化 → 不出现 images 键', () {
    const noB64 = Attachment(
        kind: AttachmentKind.image,
        relPath: 's/2.png',
        mime: 'image/png',
        bytes: 4);
    final msgs = buildOllamaMessages([
      AIMessage(role: 'user', content: 'x', attachments: [noB64])
    ]);
    expect(msgs.single.containsKey('images'), isFalse);
  });
}
