import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/attachment.dart';

import '_fakes.dart';

// 复用同目录既有的 fake provider / helper（`makeLoop`），照 agent_loop_test.dart
// 的方式构造 AgentLoop —— 计划里的 `makeTestLoop()` 只是占位名字，实际不存在。
void main() {
  const img = Attachment(
    kind: AttachmentKind.image,
    relPath: 's/1.png',
    mime: 'image/png',
    bytes: 4,
  );

  test('send 带附件时，_history 与 _events 两边都挂上', () async {
    final p = FakeProvider([const AIResponse(text: 'all good')]);
    final loop = makeLoop(provider: p);

    await loop.send('看这张', attachments: const [img]);

    final userMsg =
        loop.debugHistory.firstWhere((m) => m.role == 'user');
    expect(userMsg.attachments, hasLength(1));

    final userEvent = loop.events.whereType<UserTurnEvent>().last;
    expect(userEvent.attachments, hasLength(1),
        reason: '_history 与 _events 并行维护，少一边就是 UI 或归档缺数据');
  });

  test('不带附件时两边都是 null，不造空列表', () async {
    final p = FakeProvider([const AIResponse(text: 'all good')]);
    final loop = makeLoop(provider: p);

    await loop.send('普通一句话');

    expect(loop.debugHistory.firstWhere((m) => m.role == 'user').attachments,
        isNull);
    expect(loop.events.whereType<UserTurnEvent>().last.attachments, isNull);
  });
}
