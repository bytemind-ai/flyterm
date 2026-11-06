import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/attachment.dart';

void main() {
  const img = Attachment(
    kind: AttachmentKind.image,
    relPath: 'srv/1.png',
    mime: 'image/png',
    bytes: 100,
    name: 'shot.png',
  );

  test('UserTurnEvent 带附件，序列化往返', () {
    final e = UserTurnEvent('看这张', attachments: const [img]);
    final json = agentEventToJson(e);
    final back = agentEventsFromJson([json]).single as UserTurnEvent;
    expect(back.text, '看这张');
    expect(back.attachments, hasLength(1));
    expect(back.attachments!.first.name, 'shot.png');
  });

  test('旧归档的 user 事件没有 attachments → null，不崩', () {
    final back =
        agentEventsFromJson([{'t': 'user', 'text': 'hi'}]).single
            as UserTurnEvent;
    expect(back.attachments, isNull);
    expect(back.text, 'hi');
  });

  test('supersededByEdit 与 attachments 能共存', () {
    final e = UserTurnEvent('x', attachments: const [img])
      ..supersededByEdit = true;
    final back = agentEventsFromJson([agentEventToJson(e)]).single
        as UserTurnEvent;
    expect(back.supersededByEdit, isTrue);
    expect(back.attachments, hasLength(1));
  });
}
