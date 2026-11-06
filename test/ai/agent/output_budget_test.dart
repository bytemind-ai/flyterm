import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/ai/agent/server_targets.dart';

void main() {
  group('pickTruncateMode —— 同质输出不该从中间挖洞', () {
    test('折叠压缩比高 → 改用 head', () {
      expect(
        pickTruncateMode(
          original: 'x' * 1000,
          folded: 'x' * 100, // 10x 压缩 = 高度同质
          requested: TruncateMode.middle,
        ),
        TruncateMode.head,
      );
    });

    test('压缩不明显 → 保持请求的模式', () {
      expect(
        pickTruncateMode(
          original: 'x' * 1000,
          folded: 'x' * 950,
          requested: TruncateMode.middle,
        ),
        TruncateMode.middle,
      );
    });

    test('请求 head 时不改', () {
      expect(
        pickTruncateMode(
          original: 'x' * 1000,
          folded: 'x' * 10,
          requested: TruncateMode.head,
        ),
        TruncateMode.head,
      );
    });

    test('折叠结果为空时不崩（除零保护）', () {
      expect(
        pickTruncateMode(
          original: 'abc',
          folded: '',
          requested: TruncateMode.middle,
        ),
        TruncateMode.middle,
      );
    });
  });

  group('withAliases —— 同主机的条目互相标注', () {
    ServerListEntry e(String name, String host) =>
        ServerListEntry(id: name, name: name, host: host, credsOk: true);

    // 实测现场：dk 与 gcproot 同 IP，模型各跑一遍 df -h 拿回两份相同输出。
    test('同 host 的两个条目互相标注', () {
      final out = withAliases([e('dk', '1.2.3.4'), e('gcproot', '1.2.3.4')]);
      expect(out[0].sameHostAs, ['gcproot']);
      expect(out[1].sameHostAs, ['dk']);
    });

    test('标注进 toJson —— 模型第一次看清单就知道', () {
      final out = withAliases([e('dk', '1.2.3.4'), e('gcproot', '1.2.3.4')]);
      expect(out[0].toJson()['same_host_as'], ['gcproot']);
    });

    test('独占 host 的条目不带这个字段 —— 不浪费 token', () {
      final out = withAliases([e('a', '1.1.1.1'), e('b', '2.2.2.2')]);
      expect(out[0].sameHostAs, isNull);
      expect(out[0].toJson().containsKey('same_host_as'), isFalse);
    });

    test('三个同 host 时各自列出另外两个', () {
      final out = withAliases([
        e('a', '1.1.1.1'),
        e('b', '1.1.1.1'),
        e('c', '1.1.1.1'),
      ]);
      expect(out[0].sameHostAs, containsAll(['b', 'c']));
      expect(out[0].sameHostAs, hasLength(2));
    });

    test('空列表安全', () {
      expect(withAliases([]), isEmpty);
    });
  });
}
