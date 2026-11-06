import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/knowledge.dart';
import 'package:flyterm/ai/agent/knowledge_distiller.dart';

import '../../ai/agent/_fakes.dart';

/// 这里断言的是 `terminal_screen.dart` 里 `knowledgeDistiller` 那个闭包该有的
/// 行为，把「装配错了」在单元层就抓住 —— 与 `skill_wiring_test.dart` 同一思路。
///
/// 关键在于**开关判断的位置**：它刻意放在装配处的闭包里，而不是
/// `shouldProposeKnowledge` 门控函数里。关掉时应当连提炼调用都不发起，
/// 而不是等门控跑完再省 —— 后者省的是判断，前者省的是钱。
///
/// ## 这个测试抓不住什么（与 `skill_wiring_test.dart` 同样的局限）
///
/// 下面的 `closureWith` 是生产闭包的**复刻**，不是它本身 —— 真品内联在
/// `terminal_screen.dart` 的 `_agentLoopFor` 里，没有可供测试取用的入口。
/// 所以如果有人把真品里的开关判断删掉，这个测试**不会**变红。
///
/// 它锁住的是「这套组合逻辑本身是对的」，以及日后读代码的人能看到这个
/// 顺序是刻意的。要真正锁住装配，得先把那个闭包提成命名方法 —— 那是一次
/// 独立的重构，不在本次范围内。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late AgentSessionManager mgr;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    mgr = AgentSessionManager(prefs);
  });

  /// 复刻 `terminal_screen.dart` 装配处的那个闭包。
  Future<List<KnowledgeCandidate>> Function(List<AgentEvent>) closureWith(
          FakeProvider p) =>
      (events) async {
        if (!mgr.knowledgeCaptureEnabled) return const [];
        return KnowledgeDistiller(() => p).distill(
          buildDistillInput(
            events: events,
            existingSkills: const [],
            currentMachineNotes: null,
          ),
        );
      };

  List<AgentEvent> someEvents() => [
        UserTurnEvent('502 怎么回事'),
        AssistantTextEvent('upstream 挂了'),
      ];

  test('开关关闭时返回空列表，且**不发起**提炼调用', () async {
    mgr.knowledgeCaptureEnabled = false;
    final p = FakeProvider([], completeScript: ['[{"target":"skill",'
        '"name":"x","description":"d","body":"b"}]']);

    final r = await closureWith(p)(someEvents());

    expect(r, isEmpty);
    expect(p.seenComplete, isEmpty,
        reason: '关掉时连模型调用都不该发出去 —— 省的是钱，不是一次判断');
  });

  test('开关开启时会发起提炼调用', () async {
    final p = FakeProvider([], completeScript: ['[{"target":"skill",'
        '"name":"nginx-502","description":"d","body":"b"}]']);

    final r = await closureWith(p)(someEvents());

    expect(p.seenComplete, hasLength(1));
    expect(r.single.name, equals('nginx-502'));
  });

  test('默认（用户没碰过设置）就是开启的', () async {
    final p = FakeProvider([], completeScript: ['[]']);
    await closureWith(p)(someEvents());
    expect(p.seenComplete, hasLength(1));
  });
}
