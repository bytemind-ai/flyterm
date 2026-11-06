import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/attachment.dart';

void main() {
  const img = Attachment(
    kind: AttachmentKind.image,
    relPath: 'srv/1.png',
    mime: 'image/png',
    bytes: 100,
  );

  test('attachments 进 toJson 并能读回', () {
    const m = AIMessage(role: 'user', content: '看这张图', attachments: [img]);
    final back = AIMessage.fromJson(m.toJson());
    expect(back.attachments, hasLength(1));
    expect(back.attachments!.first.relPath, 'srv/1.png');
  });

  test('旧归档没有 attachments 字段 → 读出来是 null，不崩', () {
    // 归档是用户数据，这条是兼容性的底线。
    final back = AIMessage.fromJson({'role': 'user', 'content': 'hi'});
    expect(back.attachments, isNull);
    expect(back.content, 'hi');
  });

  test('空列表不写进 json —— 与 toolCalls 的处理一致', () {
    const m = AIMessage(role: 'user', content: 'x', attachments: []);
    expect(m.toJson().containsKey('attachments'), isFalse);
  });

  test('坏的附件记录被丢弃，其余保留', () {
    final json = {
      'role': 'user',
      'content': 'x',
      'attachments': [
        {'kind': 'image'}, // 缺 relPath
        {'kind': 'image', 'relPath': 'srv/ok.png', 'mime': 'image/png'},
      ],
    };
    expect(AIMessage.fromJson(json).attachments, hasLength(1));
  });
}
