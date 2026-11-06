import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/attachment.dart';

Attachment _img(String n) => Attachment(
    kind: AttachmentKind.image,
    relPath: 's/$n.png',
    mime: 'image/png',
    bytes: 1,
    name: '$n.png');

void main() {
  // 这一条守的是**默认值**，不是某次调用传的参数。
  //
  // 其余用例都显式传 `max: 3`，于是 `kMaxHistoryImages` 这个常量没有任何测试
  // 覆盖 —— 而生产代码（`agent_loop` 里那处物化之前）调的正是不带 max 的
  // `capHistoryImages(_history)`，用的就是默认值。把常量改成 0 或 100，
  // 其余用例全绿，行为却全变了。mutation 验证时发现的缺口。
  test('默认上限是 3 —— 生产调用不传 max，走的是这个常量', () {
    expect(kMaxHistoryImages, 3);

    final four = <AIMessage>[
      for (final n in ['one', 'two', 'three', 'four'])
        AIMessage(role: 'user', content: n, attachments: [_img(n)]),
    ];
    // 不传 max
    final out = capHistoryImages(four);
    final kept = out.fold<int>(
        0,
        (s, m) =>
            s +
            (m.attachments ?? const [])
                .where((a) => a.kind == AttachmentKind.image)
                .length);
    expect(kept, 3, reason: '默认值若不是 3，这里就会变');
    expect(out.first.content, contains('image dropped'));
  });

  test('第 4 张进来时，最老的降级成 marker 且带文件名', () {
    final history = <AIMessage>[
      AIMessage(role: 'user', content: 'a', attachments: [_img('one')]),
      AIMessage(role: 'user', content: 'b', attachments: [_img('two')]),
      AIMessage(role: 'user', content: 'c', attachments: [_img('three')]),
      AIMessage(role: 'user', content: 'd', attachments: [_img('four')]),
    ];

    final out = capHistoryImages(history, max: 3);

    // 最老那条的图被摘掉，正文加了 marker
    expect(out[0].attachments, isEmpty);
    expect(out[0].content, contains('image dropped'));
    expect(out[0].content, contains('one.png'),
        reason: 'marker 不带文件名，模型不知道那里曾有什么');
    expect(out[0].content, startsWith('a'), reason: '原文要保留');

    // 其余三条不动
    expect(out[1].attachments, hasLength(1));
    expect(out[3].attachments, hasLength(1));
  });

  test('刚好 3 张时一个都不动', () {
    final history = <AIMessage>[
      AIMessage(role: 'user', content: 'a', attachments: [_img('1')]),
      AIMessage(role: 'user', content: 'b', attachments: [_img('2')]),
      AIMessage(role: 'user', content: 'c', attachments: [_img('3')]),
    ];
    final out = capHistoryImages(history, max: 3);
    expect(out.every((m) => (m.attachments ?? []).isNotEmpty), isTrue);
  });

  test('text 类附件不计入上限', () {
    const t = Attachment(
        kind: AttachmentKind.text,
        relPath: 's/a.log',
        mime: 'text/plain',
        bytes: 1);
    final history = <AIMessage>[
      AIMessage(role: 'user', content: 'a', attachments: [t, t, t, t]),
      AIMessage(role: 'user', content: 'b', attachments: [_img('1')]),
    ];
    final out = capHistoryImages(history, max: 3);
    expect(out[0].attachments, hasLength(4), reason: 'text 不占图片额度');
    expect(out[1].attachments, hasLength(1));
  });
}
