import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/data/models/agent_session.dart';
import 'package:flyterm/ui/ai/widgets/session_history_search.dart';

/// 历史会话搜索的过滤逻辑。
///
/// **只搜标题，不搜正文。** 理由是两条：
///
/// 1. `archive` 是整段会话的 JSON（可能几百 KB），每敲一个字符解析一遍太贵。
/// 2. 它是模型总结出来的，信息密度最高 —— 用户记得住的通常就是那个词。
///
/// 另外：历史本来就只保留最近 `kSessionsPerServer` 条，能被搜到的东西当前
/// 列表里全都有。所以「跨已删除数据搜索」这个方向不成立，不需要 SQL 搜索。
void main() {
  AgentSession s(String? title, {int id = 0, bool starred = false}) =>
      AgentSession(
        id: id,
        serverId: 'srv',
        title: title,
        archive: '{"events":[]}',
        eventCount: 1,
        starred: starred,
        createdAt: DateTime(2026, 10, 1),
        updatedAt: DateTime(2026, 10, 1),
      );

  group('空查询', () {
    test('空串返回全部 —— 不清空列表', () {
      final all = [s('nginx 502', id: 1), s('磁盘满了', id: 2)];
      expect(filterSessions(all, ''), hasLength(2));
    });

    test('纯空白等同空串', () {
      final all = [s('nginx 502', id: 1), s('磁盘满了', id: 2)];
      expect(filterSessions(all, '   '), hasLength(2));
    });
  });

  group('匹配标题', () {
    test('子串命中', () {
      final all = [s('nginx 502 排查', id: 1), s('磁盘满了', id: 2)];
      final r = filterSessions(all, 'nginx');
      expect(r, hasLength(1));
      expect(r.single.id, equals(1));
    });

    test('大小写不敏感', () {
      final all = [s('Nginx 502', id: 1)];
      expect(filterSessions(all, 'nginx'), hasLength(1));
      expect(filterSessions(all, 'NGINX'), hasLength(1));
    });

    test('前后空白被忽略', () {
      final all = [s('nginx 502', id: 1)];
      expect(filterSessions(all, '  nginx  '), hasLength(1));
    });

    test('中文子串命中', () {
      final all = [s('磁盘满了', id: 1), s('nginx 502', id: 2)];
      expect(filterSessions(all, '磁盘'), hasLength(1));
    });

    test('不命中返回空列表', () {
      final all = [s('nginx 502', id: 1)];
      expect(filterSessions(all, 'redis'), isEmpty);
    });
  });

  group('无标题的行', () {
    /// 无标题的行**不参与匹配**，但不该因此让它变成不可搜的幽灵 ——
    /// 也不该让「abc」这种查询把它误命中。这里的取舍是：标题为 null 时
    /// 拿显示用的占位文案（`(无标题)`）当匹配目标会引入一个假命中，
    /// 所以直接不参与。
    test('标题为 null 的行不被任何词命中', () {
      final all = [s(null, id: 1), s('nginx 502', id: 2)];
      expect(filterSessions(all, 'nginx'), hasLength(1));
      expect(filterSessions(all, '无标题'), isEmpty,
          reason: '占位文案不是标题，不该被搜到');
    });

    test('空串查询时它照样在列表里', () {
      final all = [s(null, id: 1), s('nginx 502', id: 2)];
      expect(filterSessions(all, ''), hasLength(2));
    });
  });

  group('保持顺序与星标', () {
    test('过滤后保持原有顺序', () {
      final all = [
        s('nginx a', id: 1),
        s('别的', id: 2),
        s('nginx b', id: 3),
      ];
      final r = filterSessions(all, 'nginx');
      expect(r.map((e) => e.id).toList(), equals([1, 3]));
    });

    test('星标不影响是否命中', () {
      final all = [s('nginx 502', id: 1, starred: true)];
      expect(filterSessions(all, 'nginx'), hasLength(1));
    });
  });
}
