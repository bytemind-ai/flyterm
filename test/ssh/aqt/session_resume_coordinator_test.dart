// SessionResumeCoordinator 是恢复的唯一入口，合并同一 tab 的并发
// RESUME——测的是「合并」这个行为本身，不是协议正确性（协议幂等，
// 并发发也不会错，见类文档）。用 Completer 卡住 doResume 制造真实的
// 并发窗口，不用 Future.delayed 碰运气赌调度顺序。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/aqt/session_resume_coordinator.dart';

void main() {
  test('同一 tab 的并发请求合并成一次 RESUME', () async {
    var calls = 0;
    final gate = Completer<void>();
    final c = SessionResumeCoordinator(doResume: (tabId) async {
      calls++;
      await gate.future;
      return ResumeOutcome.restored();
    });

    // 六个发起点同时来 —— prewarm / coldHydrate / preSsh / fullreconn /
    // proactive-live / proactive-disk
    final futures = List.generate(6, (_) => c.ensureResumed('tab-1'));
    gate.complete();
    final results = await Future.wait(futures);

    expect(calls, 1, reason: '六个请求必须合并成一次');
    expect(results.every((r) => r.isRestored), isTrue,
        reason: '每个调用方都要拿到结果，不能只有第一个');
  });

  test('不同 tab 互不阻塞', () async {
    final started = <String>[];
    final gates = {'a': Completer<void>(), 'b': Completer<void>()};
    final c = SessionResumeCoordinator(doResume: (tabId) async {
      started.add(tabId);
      await gates[tabId]!.future;
      return ResumeOutcome.restored();
    });

    final fa = c.ensureResumed('a');
    final fb = c.ensureResumed('b');
    await Future<void>.delayed(Duration.zero);
    expect(started, containsAll(['a', 'b']), reason: 'b 不该等 a');
    gates['a']!.complete();
    gates['b']!.complete();
    await Future.wait([fa, fb]);
  });

  test('前一次完成后，下一次会真的重新发', () async {
    var calls = 0;
    final c = SessionResumeCoordinator(doResume: (_) async {
      calls++;
      return ResumeOutcome.restored();
    });
    await c.ensureResumed('t');
    await c.ensureResumed('t');
    expect(calls, 2, reason: 'in-flight 合并，不是结果缓存');
  });

  test('失败不会粘住 —— 下一次仍能发起', () async {
    var calls = 0;
    final c = SessionResumeCoordinator(doResume: (_) async {
      calls++;
      if (calls == 1) throw StateError('network down');
      return ResumeOutcome.restored();
    });
    await expectLater(c.ensureResumed('t'), throwsStateError);
    final ok = await c.ensureResumed('t');
    expect(ok.isRestored, isTrue);
    expect(calls, 2);
  });

  test('并发调用共享同一个失败', () async {
    var calls = 0;
    final gate = Completer<void>();
    final c = SessionResumeCoordinator(doResume: (_) async {
      calls++;
      await gate.future;
      throw StateError('boom');
    });
    final f1 = c.ensureResumed('t');
    final f2 = c.ensureResumed('t');
    gate.complete();
    await expectLater(f1, throwsStateError);
    await expectLater(f2, throwsStateError);
    expect(calls, 1);
  });
}
