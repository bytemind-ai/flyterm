// SessionTab.swallowUntilAltEnter 的纯函数单测。
//
// 背景见 test/ssh/cold_start_prelude_render_test.dart 里的
// "alt-buffer swallow discards the server cold-RESUME snapshot" group：
// 服务端在 alt 场景组装的恢复负载被客户端整段吞掉，屏幕恢复不出来。
// 修复是"吞到 ?1049h 为止"，本文件锁住这个边界判定的各种形态。
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/session_manager.dart';

/// `\x1b[?1049h`
const _mark = SessionTab.kAltScreenEnter;

List<int> _ascii(String s) => s.codeUnits;

void main() {
  group('无标记时保持修复前的行为', () {
    test('预算充足 → 整个 chunk 被吞掉，预算递减', () {
      final r = SessionTab.swallowUntilAltEnter(_ascii('hello'), 100, 0);
      expect(r.kept, isEmpty);
      expect(r.swallowRemaining, 95);
      expect(r.altEnterMatched, 0);
    });

    test('预算在 chunk 中间用尽 → 放行剩余字节', () {
      final r = SessionTab.swallowUntilAltEnter(_ascii('AAAABBBB'), 4, 0);
      expect(r.kept, _ascii('BBBB'));
      expect(r.swallowRemaining, 0);
    });

    test('预算恰好等于 chunk 长度 → 全吞，无剩余', () {
      final r = SessionTab.swallowUntilAltEnter(_ascii('AAAA'), 4, 0);
      expect(r.kept, isEmpty);
      expect(r.swallowRemaining, 0);
    });

    test('预算用尽处落在 UTF-8 字符中间时对齐到字符边界', () {
      // "啊" = E5 95 8A，预算在它的第 2 个字节处用尽。不对齐的话剩余流以
      // continuation byte 开头，Utf8Decoder 会吐 U+FFFD 方块。
      final bytes = <int>[0x41, 0xE5, 0x95, 0x8A, 0x42];
      final r = SessionTab.swallowUntilAltEnter(bytes, 2, 0);
      expect(r.kept.first, isNot(0x95),
          reason: '不能以 continuation byte 开头');
      expect(r.kept, [0x42]);
    });
  });

  group('标记出现在单个 chunk 内', () {
    test('标记连同其后的字节一起放行', () {
      final bytes = [..._ascii('history'), ..._mark, ..._ascii('SNAPSHOT')];
      final r = SessionTab.swallowUntilAltEnter(bytes, 1000, 0);
      expect(r.kept, [..._mark, ..._ascii('SNAPSHOT')],
          reason: '标记本身必须放行——xterm 要靠它进 alt 屏，'
              '紧随其后的 2J 才能把屏幕清干净再画快照');
      expect(r.swallowRemaining, 0);
      expect(r.altEnterMatched, 0);
    });

    test('标记位于 chunk 末尾 → 只放行标记', () {
      final bytes = [..._ascii('history'), ..._mark];
      final r = SessionTab.swallowUntilAltEnter(bytes, 1000, 0);
      expect(r.kept, _mark);
    });

    test('标记在预算耗尽之前出现，预算即刻清零', () {
      final bytes = [..._ascii('ab'), ..._mark, ..._ascii('rest')];
      final r = SessionTab.swallowUntilAltEnter(bytes, 500, 0);
      expect(r.swallowRemaining, 0,
          reason: '找到标记后不应再吞任何东西');
    });
  });

  group('标记被 QUIC 分片劈开（这次修复的关键场景）', () {
    test('劈成两半仍能识别，并补出完整标记', () {
      // chunk 1 以 `\x1b[?10` 结尾，chunk 2 以 `49h` 开头。
      final head = _mark.sublist(0, 5);
      final tail = _mark.sublist(5);

      final r1 = SessionTab.swallowUntilAltEnter(
          [..._ascii('hist'), ...head], 1000, 0);
      expect(r1.kept, isEmpty);
      expect(r1.altEnterMatched, 5, reason: '匹配进度必须跨 chunk 保留');

      final r2 = SessionTab.swallowUntilAltEnter(
          [...tail, ..._ascii('SNAPSHOT')], r1.swallowRemaining, r1.altEnterMatched);
      expect(r2.kept, [..._mark, ..._ascii('SNAPSHOT')],
          reason: '标记的前半段已在上个 chunk 被吞掉，必须用常量补回来，'
              '否则 xterm 收到的是残缺的 `49h`');
      expect(r2.swallowRemaining, 0);
    });

    test('逐字节投递（最坏分片）同样能识别', () {
      final bytes = [..._ascii('xy'), ..._mark, ..._ascii('OK')];
      var remaining = 1000;
      var matched = 0;
      final kept = <int>[];
      for (final b in bytes) {
        if (remaining <= 0) {
          kept.add(b);
          continue;
        }
        final r = SessionTab.swallowUntilAltEnter([b], remaining, matched);
        remaining = r.swallowRemaining;
        matched = r.altEnterMatched;
        kept.addAll(r.kept);
      }
      expect(kept, [..._mark, ..._ascii('OK')]);
    });
  });

  group('部分匹配的失配处理', () {
    test('失配后重置，不影响后续真标记的识别', () {
      // `\x1b[?10X` 是假警报，紧跟着才是真标记。
      final bytes = [
        ..._mark.sublist(0, 5), 0x58, // ESC [ ? 1 0 X
        ..._mark,
        ..._ascii('SNAP'),
      ];
      final r = SessionTab.swallowUntilAltEnter(bytes, 1000, 0);
      expect(r.kept, [..._mark, ..._ascii('SNAP')]);
    });

    test('失配字节本身是 ESC 时，作为新一轮起点', () {
      // `\x1b\x1b[?1049h`：第二个 ESC 在 matched==1 时失配，但它自己就是
      // 新的起点。若简单归零会吃掉这个 ESC，真标记就再也匹配不上。
      final bytes = [0x1b, ..._mark, ..._ascii('SNAP')];
      final r = SessionTab.swallowUntilAltEnter(bytes, 1000, 0);
      expect(r.kept, [..._mark, ..._ascii('SNAP')],
          reason: '失配重置时必须重新检查当前字节是否为 ESC');
    });

    test('chunk 结束时的部分匹配被带到下一个 chunk 并可失配', () {
      final r1 = SessionTab.swallowUntilAltEnter(_mark.sublist(0, 3), 1000, 0);
      expect(r1.altEnterMatched, 3);

      // 下一个 chunk 不是标记的延续 → 应失配归零，继续吞。
      final r2 = SessionTab.swallowUntilAltEnter(
          _ascii('ZZZZ'), r1.swallowRemaining, r1.altEnterMatched);
      expect(r2.kept, isEmpty);
      expect(r2.altEnterMatched, 0);
    });
  });

  group('边界输入', () {
    test('空 chunk 不改变任何状态', () {
      final r = SessionTab.swallowUntilAltEnter(const [], 50, 3);
      expect(r.kept, isEmpty);
      expect(r.swallowRemaining, 50);
      expect(r.altEnterMatched, 3);
    });

    test('预算为 0 时原样放行（调用方已在此前 early-return）', () {
      final r = SessionTab.swallowUntilAltEnter(_ascii('abc'), 0, 0);
      expect(r.kept, _ascii('abc'));
    });

    test('预算在标记中途用尽时，预算优先——标记不被补全', () {
      // 预算只剩 4，标记要 8 个字节 → 预算先用尽，走对齐分支放行剩余，
      // 吐给 xterm 的是残缺的后半截标记。
      //
      // 这个组合在真实链路上到不了：预算就是 lastResumeReplayBytes，
      // 即整段 prelude（标记和快照都在里面）的长度，标记必然落在预算之内。
      // 锁在这里只是把边界行为写死，避免以后改动时无声地变成别的样子。
      final bytes = [..._mark, ..._ascii('SNAP')];
      final r = SessionTab.swallowUntilAltEnter(bytes, 4, 0);
      expect(r.swallowRemaining, 0);
      expect(r.kept, [..._mark.sublist(4), ..._ascii('SNAP')]);
    });
  });
}
