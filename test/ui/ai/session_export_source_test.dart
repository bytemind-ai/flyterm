import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_events.dart';
import 'package:flyterm/ui/ai/widgets/session_export_source.dart';

/// 导出会话时**该读内存还是回表**，两个入口各写过一遍，逻辑相同但容易漂移。
///
/// 那条分支是：被导的那一段**恰好是当前活跃段**时走内存，其余回表。理由在
/// 两个调用点都写了 —— 活跃段按 `updated_at DESC` 排第一，最容易被点到，
/// 而回表读到的是节流落盘的版本（`_kPersistThrottle`），会缺最近几轮，
/// **且用户完全看不出来**（静默数据缺失比少一个入口糟糕得多）。
///
/// 收口成 [exportEventsFor] 之后，这条判断只此一份。
void main() {
  group('exportEventsFor 的取数来源', () {
    test('目标段就是活跃段时走内存（不吃节流落盘的旧副本）', () {
      final live = <AgentEvent>[
        AssistantTextEvent('刚落盘还没写进去的那一轮'),
      ];

      final r = exportEventsFor(
        id: 7,
        activeRowId: 7, // 同一个 id —— 活跃段
        liveEvents: live,
      );

      expect(r.fromMemory, isTrue);
      expect(r.events, same(live),
          reason: '应当直接用内存里那份，而不是回表');
    });

    test('目标段不是活跃段时回表', () {
      final r = exportEventsFor(
        id: 3,
        activeRowId: 7, // 活跃的是另一段
        liveEvents: <AgentEvent>[AssistantTextEvent('不该被用到')],
      );

      expect(r.fromMemory, isFalse,
          reason: '导旧会话不该拿当前会话的内存事件冒充');
      expect(r.events, isEmpty);
    });

    test('没有活跃段（activeRowId 为 null）时回表', () {
      final r = exportEventsFor(
        id: 3,
        activeRowId: null,
        liveEvents: <AgentEvent>[AssistantTextEvent('x')],
      );

      expect(r.fromMemory, isFalse);
    });

    test('活跃段判定按 id 相等，不是「只要活跃段存在就走内存」', () {
      final r = exportEventsFor(
        id: 99,
        activeRowId: 1,
        liveEvents: <AgentEvent>[],
      );

      expect(r.fromMemory, isFalse);
    });
  });

  group('回表解析', () {
    test('archive 里的 events 被解析成事件列表', () {
      final encoded = [
        agentEventToJson(AssistantTextEvent('你好')),
      ];

      final r = exportEventsFor(
        id: 3,
        activeRowId: null,
        liveEvents: const [],
        archive: {'events': encoded},
      );

      expect(r.fromMemory, isFalse);
      expect(r.events.whereType<AssistantTextEvent>(), hasLength(1));
      expect((r.events.first as AssistantTextEvent).text, equals('你好'));
    });

    test('archive 为 null（那一行已不存在）时给出空列表而不是抛', () {
      final r = exportEventsFor(
        id: 3,
        activeRowId: null,
        liveEvents: const [],
        archive: null,
      );

      expect(r.events, isEmpty);
    });

    test('archive 里 events 字段缺失或畸形时给空列表而不是抛', () {
      final r = exportEventsFor(
        id: 3,
        activeRowId: null,
        liveEvents: const [],
        archive: {'events': 'not a list'},
      );

      expect(r.events, isEmpty);
    });
  });
}
