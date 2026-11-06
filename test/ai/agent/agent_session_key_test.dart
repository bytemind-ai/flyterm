import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

void main() {
  // `provider` 是 makeLoop 的必填具名参数（没有默认值），这几个测试不会
  // 触发任何 provider 调用，脚本给空列表即可。
  test('同一个 loop 的 sessionKey 恒定 —— 变了就等于每轮换一条缓存分组',
      () {
    final loop = makeLoop(provider: FakeProvider([]));

    final first = loop.sessionKey;

    expect(loop.sessionKey, first);
    expect(first, isNotEmpty);
  });

  /// 这条是多 tab 串号的回归防线：provider 实例长存且被多个面板共用，
  /// 两个 loop 若拿到同一个 key，两条毫不相干的历史就会被归进同一个缓存
  /// 分组，命中率比不发还差。
  test('两个 loop 的 sessionKey 不同', () {
    final a = makeLoop(provider: FakeProvider([]));
    final b = makeLoop(provider: FakeProvider([]));

    expect(a.sessionKey, isNot(b.sessionKey));
  });

  test('sessionKey 不超过 OpenAI 的 64 字符上限', () {
    expect(
        makeLoop(provider: FakeProvider([])).sessionKey.length,
        lessThanOrEqualTo(64));
  });

  /// 防的是「加了字段却忘了在调用点传参」——那是个静默失败：
  /// 上面三条断言字段本身的测试会照常全绿，provider 那头却什么也没收到。
  test('provider 实际收到的 sessionKey 与 loop.sessionKey 一致', () async {
    final provider = FakeProvider([const AIResponse(text: 'done')]);
    final loop = makeLoop(provider: provider);

    await loop.send('hi');

    expect(provider.lastSessionKey, loop.sessionKey);
  });
}
