import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/notify_format.dart';

void main() {
  group('NotifyFormat.build', () {
    test('title 就是消息原文，不做任何加工', () {
      final ts = DateTime(2026, 8, 17, 10, 0, 0).millisecondsSinceEpoch;
      final content = NotifyFormat.build(
        text: 'build finished',
        serverName: 'srv',
        tabTitle: 'tab',
        tsUnixMs: ts,
        now: DateTime(2026, 8, 17, 10, 0, 5),
      );
      expect(content.title, 'build finished');
    });

    test('同一天 → body 只带 HH:mm:ss，不带日期', () {
      final ts = DateTime(2026, 8, 17, 9, 5, 3).millisecondsSinceEpoch;
      final content = NotifyFormat.build(
        text: 'x',
        serverName: '我的服务器',
        tabTitle: 'bash',
        tsUnixMs: ts,
        now: DateTime(2026, 8, 17, 12, 0, 0),
      );
      expect(content.body, '我的服务器 · bash · 09:05:03');
    });

    test('跨天（例如断线补投的旧事件）→ body 带完整日期', () {
      final ts = DateTime(2026, 8, 15, 22, 30).millisecondsSinceEpoch;
      final content = NotifyFormat.build(
        text: 'x',
        serverName: 'srv',
        tabTitle: 'bash',
        tsUnixMs: ts,
        now: DateTime(2026, 8, 17, 9, 0, 0),
      );
      expect(content.body, 'srv · bash · 2026-08-15 22:30');
    });

    test('tabTitle 为 null（无法解析来源 tab）→ body 省略这一段，不留多余分隔符', () {
      final ts = DateTime(2026, 8, 17, 9, 0, 0).millisecondsSinceEpoch;
      final content = NotifyFormat.build(
        text: 'x',
        serverName: 'srv',
        tabTitle: null,
        tsUnixMs: ts,
        now: DateTime(2026, 8, 17, 9, 0, 5),
      );
      expect(content.body, 'srv · 09:00:00');
    });

    test('不使用相对时间——即便 now 和事件时间相差很久，body 仍是绝对时间', () {
      // 回归防呆：绝不能把 "n 分钟/小时前" 这种相对表述带回来。时钟不同步 +
      // 补投场景下，相对时间会显示出没有意义甚至荒谬的结果。
      final ts = DateTime(2020, 1, 1, 0, 0, 0).millisecondsSinceEpoch;
      final content = NotifyFormat.build(
        text: 'x',
        serverName: 'srv',
        tabTitle: null,
        tsUnixMs: ts,
        now: DateTime(2026, 8, 17, 9, 0, 0),
      );
      expect(content.body, contains('2020-01-01'));
      expect(content.body, isNot(contains('前')));
      expect(content.body, isNot(contains('ago')));
    });
  });
}
