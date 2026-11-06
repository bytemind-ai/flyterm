import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 幂等性在**客户端渲染器**上的验证。
///
/// `rust/flyterm-server/tests/resume_idempotence_e2e.rs` 已经验证了服务端那
/// 一侧：同一份快照喂进 vt100 两次、乱序喂、六路并发取，结果都相同。但真正
/// 消费快照的是 xterm.dart，两个终端实现对同一段字节的处理**不一定一致**，
/// 而差异会以「重连几次之后 scrollback 里出现重复历史」的形式显形 —— 那种
/// 现象很难归因，等到用户报上来时已经隔了很多次重连。
///
/// 尤其要盯住 `\x1b[2J`：它是快照前缀的一部分。如果 xterm 把被清掉的内容
/// 推进 scrollback（有些实现是这么做的，模拟"滚上去"），那么每应用一次快照
/// 就多一份历史副本。
///
/// 另外记录一个已知差异：xterm.dart **不认 `\x1bc`（RIS）**——parser 里那
/// 行是注释掉的。快照前缀里它是空操作，靠后面的 DECSTR / ?1049l / 2J / H /
/// SGR reset 把终端拉回确定状态。
///
/// ## 2026-08-26：这份测试曾经放过一个真 bug，记下为什么
///
/// 恢复负载从「只有当前屏」改成「历史 + 当前屏」（见 `2d3e48d` / `eaf65d1`）
/// 之后，负载行数经常
/// 远超一屏，超出的部分写进去会把前面的行**顶进 scrollback**。而 `2J` 在
/// xterm.dart 上只擦可见区（`buffer.dart::eraseDisplay` 只遍历 viewHeight
/// 行），RIS 又是空操作 —— 于是每应用一次负载就在 scrollback 里多留一整份
/// 副本。真机症状：app 每切走再切回来一次，往上翻就多看到一遍同样的内容。
///
/// 这份测试当时是绿的，因为它的 body 只有一两行、装得进一屏 —— `2J` + `H`
/// 原地覆盖，buffer 压根不会变长。**测试用例的规模落在了 bug 的判据之外**：
/// 要暴露它，负载必须超过一屏。下面 [`preludeWithHistory`] 就是按真实形状
/// （40 行历史 + 20 行当前屏，屏高 24）构造的。
///
/// 修复在服务端：负载前缀补 `\x1b[3J`（清 scrollback），见
/// `snapshot.rs::serialize_resume` 的文档。
///
/// ## 2026-08-27：alt 与 primary 合并成一条路径
///
/// 曾经 alt 走单独的 `serialize`（只画 alt 屏、**不**发 3J，理由是「alt 负载
/// 不带 primary 历史，清了只是白白抹掉用户那份」）。代价是客户端冷启动时
/// 本地 primary 本来就是空的，退出 TUI 后一片空白。
///
/// 现在只有 `serialize_resume` 一条路：primary 历史 + 可见屏永远都发，alt
/// 只是在后面**叠加**一层 alt 屏快照。于是 3J 对两者都发 —— 清完立刻用权威
/// 版本填回来。下面的 alt 用例断言的正是这个新形状。
void main() {
  /// 服务端 `snapshot::HARD_RESET_AND_SAFE_MODES` 的原文。
  const hardReset = '\x1bc\x1b[!p\x1b[?1049l\x1b[2J\x1b[H\x1b[0m'
      '\x1b[?25h\x1b[?7h\x1b[?12l\x1b[?1006l\x1b[?1004l\x1b[?2004l';

  /// 恢复负载（`serialize_resume`）的前缀：共享前缀 + 清 scrollback。
  /// alt 与 primary 用的是同一个 —— 只有一条路径。
  const primaryPreamble = '$hardReset\x1b[3J';

  /// 一份典型的 RESUME 快照：前缀 + 当前屏内容（装得进一屏）。
  String snapshot(String body) => '$primaryPreamble$body';

  /// 真实形状的 primary 负载：历史逐行 + 当前屏逐行，总行数远超一屏。
  /// 与 `serialize_resume` 的输出结构一致（行间 `\x1b[0m\r\n`，
  /// 最后一行不带换行）。
  String preludeWithHistory({int history = 40, int screen = 20}) {
    final b = StringBuffer(primaryPreamble);
    for (var i = 0; i < history; i++) {
      b.write('history line $i\x1b[0m\r\n');
    }
    for (var i = 0; i < screen; i++) {
      b.write('screen row $i');
      if (i < screen - 1) b.write('\x1b[0m\r\n');
    }
    return b.toString();
  }

  /// alt 会话的负载形状：primary 段照发，后面叠一层 alt 屏快照。
  /// 与 `serialize_resume` 在 `screen.alternate_screen()` 为真时的输出一致。
  String altPayload() =>
      '${preludeWithHistory()}\x1b[?1049h\x1b[2J\x1b[H'
      'TUI 画面\x1b[0m';

  List<String> visibleLines(Terminal t) => [
        for (var i = 0; i < t.viewHeight; i++)
          t.buffer.lines[t.buffer.height - t.viewHeight + i]
              .getText(0, t.viewWidth)
              .trimRight(),
      ].where((l) => l.isNotEmpty).toList();

  /// 整个 buffer（含 scrollback）里包含 [needle] 的行数。
  int occurrences(Terminal t, String needle) {
    var n = 0;
    for (var i = 0; i < t.buffer.lines.length; i++) {
      if (t.buffer.lines[i].getText(0, t.viewWidth).contains(needle)) n++;
    }
    return n;
  }

  group('快照在 xterm 上是幂等的', () {
    test('应用两次与应用一次，可见屏相同', () {
      final once = Terminal(maxLines: 1000)..resize(80, 24);
      once.write(snapshot('hello from resume'));

      final twice = Terminal(maxLines: 1000)..resize(80, 24);
      twice.write(snapshot('hello from resume'));
      twice.write(snapshot('hello from resume'));

      expect(visibleLines(twice), visibleLines(once));
    });

    test('应用两次不会让 scrollback 长出第二份历史', () {
      // 这是最要命的那条：`2J` 若把被清内容推进 scrollback，每次重连都会
      // 多一份副本，用户往上翻就看到同样的内容一遍遍重复。
      final t = Terminal(maxLines: 1000)..resize(80, 24);
      t.write(snapshot('line A\r\nline B'));
      final afterFirst = t.buffer.height;

      t.write(snapshot('line A\r\nline B'));
      expect(t.buffer.height, afterFirst,
          reason: '第二次应用快照不该让 buffer 变长');
    });

    test('超过一屏的负载应用两次也不重复 —— app 切走再切回来的真实形状', () {
      // 上一条用的 body 装得进一屏，`2J` + `H` 原地覆盖就够了，因此它对
      // 「负载溢出到 scrollback」这个失效模式是免疫的。这一条按真实负载
      // 构造：40 行历史 + 20 行当前屏，屏高 24 → 必然溢出。
      final t = Terminal(maxLines: 1000)..resize(80, 24);
      t.write(preludeWithHistory());
      final afterFirst = t.buffer.height;

      t.write(preludeWithHistory());

      expect(t.buffer.height, afterFirst,
          reason: '第二次应用不该让 buffer 变长（每次 RESUME 多一份副本）');
      expect(occurrences(t, 'history line 7'), 1,
          reason: '历史行在整个 buffer 里只该出现一次');
      expect(occurrences(t, 'screen row 3'), 1,
          reason: '当前屏行在整个 buffer 里只该出现一次');
    });

    test('连切五次也不累积 —— 副本是每次 +1 的，一次不重复不代表收敛', () {
      final t = Terminal(maxLines: 1000)..resize(80, 24);
      t.write(preludeWithHistory());
      final afterFirst = t.buffer.height;
      for (var i = 0; i < 4; i++) {
        t.write(preludeWithHistory());
      }
      expect(t.buffer.height, afterFirst);
      expect(occurrences(t, 'history line 0'), 1);
    });

    test('从脏状态收敛 —— 客户端可能刚 rehydrate 过本地快照', () {
      // 冷启动的真实时序：先写本地离线快照，再收到服务端的 RESUME 快照。
      final dirty = Terminal(maxLines: 1000)..resize(80, 24);
      dirty.write('本地快照的旧内容\r\n');
      dirty.write(snapshot('服务端权威内容'));

      final fresh = Terminal(maxLines: 1000)..resize(80, 24);
      fresh.write(snapshot('服务端权威内容'));

      expect(visibleLines(dirty), visibleLines(fresh),
          reason: '快照必须能从任意先前状态收敛到同一可见屏');
    });

    test('alt 屏下收到快照也能收敛', () {
      // 断开时停在 TUI 里（vim/tmux），恢复时服务端给的是 primary 快照。
      final inAlt = Terminal(maxLines: 1000)..resize(80, 24);
      inAlt.write('\x1b[?1049h\x1b[44mTUI 画面\x1b[0m');
      inAlt.write(snapshot('shell prompt\$ '));

      final fresh = Terminal(maxLines: 1000)..resize(80, 24);
      fresh.write(snapshot('shell prompt\$ '));

      expect(visibleLines(inAlt), visibleLines(fresh));
      expect(inAlt.isUsingAltBuffer, isFalse,
          reason: '快照前缀里的 ?1049l 必须把终端拉回 primary');
    });

    test('primary 负载会清掉客户端已有的 scrollback —— 它自带权威历史', () {
      // 这条**取代**了原来那条「rehydrate 的历史留在 scrollback 里，不被
      // 快照清掉」。那个不变量属于上一版模型：客户端有自己的本地历史缓存，
      // 负载只带当前屏，两者互补所以不能互相清。
      //
      // 那份本地缓存已经删掉了（`149ee26`，commit 标题就叫「它在制造重复」），
      // 负载也改成自带历史。现在客户端 scrollback 的唯一真相来源是服务端
      // ring：负载画出最近一段，更早的由 `FetchScrollback` 按行号取回来前插
      // （`_backfillScrollback`）。保留旧不变量就等于允许两份历史并存 ——
      // 而"并存"在流式终端里就是"重复"。
      final t = Terminal(maxLines: 1000)..resize(80, 24);
      for (var i = 0; i < 40; i++) {
        t.write('stale local line $i\r\n');
      }
      expect(occurrences(t, 'stale local line 0'), 1, reason: '前置条件');

      t.write(preludeWithHistory());

      expect(occurrences(t, 'stale local line 0'), 0,
          reason: '负载自带权威历史，客户端那份必须让位，否则两份并存 = 重复');
      expect(occurrences(t, 'history line 0'), 1);
    });

    test('alt 负载自带 primary 历史 —— 退出 TUI 后不该是一片空白', () {
      // 这条**取代**了原来那条「alt 负载不清 primary 的 scrollback」。
      //
      // 旧模型：alt 走 `serialize`，只画 alt 屏、不发 3J，靠客户端自己那份
      // primary 历史撑着。它在热重连时成立，冷启动时不成立 —— 客户端本地
      // primary 是空的，服务端又不发，退出 TUI 就是一片空白。
      //
      // 新模型：负载 = primary 历史 + 可见屏 + alt 屏快照。清完立刻填回来，
      // 冷热两种情形都对。
      final t = Terminal(maxLines: 1000)..resize(80, 24);
      t.write(altPayload());

      expect(t.isUsingAltBuffer, isTrue, reason: '应当停在 alt 屏');

      t.write('\x1b[?1049l'); // 退出 TUI，回到 primary

      expect(occurrences(t, 'history line 0'), 1,
          reason: '退出 alt 后 primary 历史必须在，且只有一份');
      expect(occurrences(t, 'screen row 0'), 1);
    });

    test('alt 负载连应用五次也不累积 primary 历史', () {
      final t = Terminal(maxLines: 1000)..resize(80, 24);
      t.write(altPayload());
      final afterFirst = t.buffer.height;
      for (var i = 0; i < 4; i++) {
        t.write(altPayload());
      }
      expect(t.buffer.height, afterFirst, reason: 'buffer 不该变长');
      t.write('\x1b[?1049l');
      expect(occurrences(t, 'history line 0'), 1,
          reason: '五次之后 primary 历史仍只有一份');
    });
  });
}
