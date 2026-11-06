/// 「探测命中」这条路：连接其实没死，恢复流程该原地取消。
///
/// 真机现场（2026-09-13 09:44，截图）：
///
/// ```
/// mux:off ssh:closed
/// 43:39.972 #11← FAIL networkTimeout hs:--
/// RESUMED✓ qstate:connected dead:false pathDied:false   ← 连接是活的
/// mphase:recovering trace:27                            ← 却卡在 recovering
/// path rtt:159 loss:11.5% cwnd:2
/// 09:44:23 [b972] START port=61679 dead=false probe=true
/// 09:44:24 [b972] SKIP — heartbeat alive 150ms ✓        ← 心跳 150ms 就回来了
/// ```
///
/// 屏幕上「重新连接中…」一直挂着，而连接一直是通的。
///
/// 成因是 `reconnect_service.dart` 的探测命中分支（搜 `SKIP — heartbeat alive`）
/// **直接 `return`，不给状态机发任何事件**。而状态机在 `recovering` 里是完全
/// 被动的 —— `_onTick` 的那一支只做「显示横幅 + 继续 tick」，注释写明「不做
/// 判活（判活的对象是旧连接，已经没了）」。于是它永远等不到结果。
///
/// `conn_resume_inflight_test.dart` 头部早就记下过同一类失效：「走回退链时
/// 没有任何事件把 phase 推走 —— tab 卡在 recovering 出不来」。探测命中这条
/// 路踩的是同一个坑。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_machine.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

void main() {
  group('recovering 期间没有事件 → 永远出不来（这是被动性的代价）', () {
    test('只有 tick 时，phase 一直是 recovering、横幅一直挂着', () {
      var s = const MachineState(
          phase: ConnPhase.recovering, inFlight: true, recoveringSinceMs: 1000);
      var acts = <Action>[];
      // 连推 30 秒的 tick，模拟 SKIP 之后什么事件都没来。
      for (var t = 2000; t <= 32000; t += 1000) {
        final (s2, a) = step(s, const WatchdogTick(),
            Facts(nowMs: t, rawRecvAgeMs: 100));
        s = s2;
        acts = a;
      }
      expect(s.phase, ConnPhase.recovering,
          reason: '状态机在 recovering 里不判活，只能靠外部事件推走');
      expect(acts.whereType<ShowBanner>(), isNotEmpty,
          reason: '横幅会一直显示「重新连接中」——这正是用户看到的现象');
    });
  });

  group('探测命中应当把连接判回 live', () {
    test('recovering + ProbeAnswered → live', () {
      const s = MachineState(
          phase: ConnPhase.recovering, inFlight: true, recoveringSinceMs: 1000);
      final (s2, _) =
          step(s, const ProbeAnswered(), const Facts(nowMs: 5000, rawRecvAgeMs: 100));
      expect(s2.phase, ConnPhase.live);
    });

    test('ProbeAnswered 必须清 recoveringSinceMs', () {
      // 不清的话，下次再进 recovering 时 `nowMs - since` 一上来就超过
      // kBannerDelayMs，横幅**立刻**弹出而不是延迟几秒 —— 把一个卡死换成
      // 一个闪烁。延迟本身是刻意的（见 kBannerDelayMs 的文档：短暂抖动不该
      // 惊动用户）。
      const s = MachineState(
          phase: ConnPhase.recovering, inFlight: true, recoveringSinceMs: 1000);
      final (s2, _) =
          step(s, const ProbeAnswered(), const Facts(nowMs: 5000, rawRecvAgeMs: 100));
      expect(s2.recoveringSinceMs, isNull,
          reason: '恢复已经结束了，起点不该留着污染下一次');
    });

    test('探测命中也要清 inFlight —— 否则下一次恢复会被 inFlight 挡掉', () {
      const s = MachineState(
          phase: ConnPhase.recovering, inFlight: true, recoveringSinceMs: 1000);
      final (s2, _) =
          step(s, const ProbeAnswered(), const Facts(nowMs: 5000, rawRecvAgeMs: 100));
      expect(s2.inFlight, isFalse,
          reason: '`_enterRecovering` 的 `if (s.inFlight)` 会把后续发起全吞掉');
    });
  });
}
