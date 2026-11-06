import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_silence.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

/// 被取代的旧实现，原样复制自 `AqtTransport.effectiveWatchdogAgeMs`
/// （随该实现一起删除前的最后版本）。
///
/// 留在这里作等价性参照：`observedSilence` 取代它时用 20000 组穷举证明逐点相等，
/// 而那个证据不该随被取代的实现一起消失。
///
/// **不要跟着生产代码改它。** 它是历史快照，一旦"跟进"就不再是独立参照了。
int _goldenEffectiveWatchdogAgeMs({
  required int rawAgeMs,
  required int? msSinceForeground,
  required int? msSinceConnected,
}) {
  var age = rawAgeMs;
  if (msSinceForeground != null && msSinceForeground < age) {
    age = msSinceForeground;
  }
  if (msSinceConnected != null && msSinceConnected < age) {
    age = msSinceConnected;
  }
  return age;
}

void main() {
  test('没有观测起点时等于原始 age', () {
    const s = MachineState(phase: ConnPhase.live);
    const f = Facts(nowMs: 50000, rawRecvAgeMs: 720000);
    expect(observedSilence(s, f), 720000);
  });

  test('有观测起点时被夹到"观测到的沉默"', () {
    // 刚回前台：原始 age 12 分钟，但我们只观测了 100ms
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 721000);
    const f = Facts(nowMs: 721100, rawRecvAgeMs: 720100);
    expect(observedSilence(s, f), 100);
  });

  // 等价性：现有实现取 min(rawAge, now−foregroundAt, now−connectedAt)。
  // 而 min(now−A, now−B) = now − max(A,B)，所以令
  // observeStartMs = max(connectedAt, foregroundAt) 应当逐点相等。
  test('与 effectiveWatchdogAgeMs 逐点等价（穷举 20000 组）', () {
    final rnd = Random(20260827);
    for (var i = 0; i < 20000; i++) {
      final nowMs = rnd.nextInt(1000000);
      final rawAge = rnd.nextInt(1000000);
      // 三分之一概率为 null，覆盖"只有一个窗口"和"两个都没有"的情形
      final fgAt = rnd.nextInt(3) == 0 ? null : rnd.nextInt(nowMs + 1);
      final connAt = rnd.nextInt(3) == 0 ? null : rnd.nextInt(nowMs + 1);

      final old = _goldenEffectiveWatchdogAgeMs(
        rawAgeMs: rawAge,
        msSinceForeground: fgAt == null ? null : nowMs - fgAt,
        msSinceConnected: connAt == null ? null : nowMs - connAt,
      );

      final starts = [fgAt, connAt].whereType<int>().toList();
      final observeStart = starts.isEmpty ? null : starts.reduce(max);
      final s = MachineState(phase: ConnPhase.live, observeStartMs: observeStart);
      final f = Facts(nowMs: nowMs, rawRecvAgeMs: rawAge);

      expect(observedSilence(s, f), old,
          reason: 'i=$i now=$nowMs raw=$rawAge fgAt=$fgAt connAt=$connAt');
    }
  });

  test('elevated：盲区超过一个 quinn keepalive 周期才算', () {
    // 原始 age 720s，观测到 100ms → 盲区 ~720s，远超 15s
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 721000);
    const f = Facts(nowMs: 721100, rawRecvAgeMs: 720100);
    expect(elevated(s, f), isTrue);
  });

  test('elevated：稳态下没有盲区', () {
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(nowMs: 20000, rawRecvAgeMs: 11000);
    expect(elevated(s, f), isFalse, reason: '盲区为 0，不该抬高紧迫度');
  });

  test('阈值表：normal 与 elevated 两档', () {
    expect(thresholdsFor(urgency: Urgency.normal).suspectMs, 10000);
    expect(thresholdsFor(urgency: Urgency.normal).probeTimeoutMs, 3000);
    expect(thresholdsFor(urgency: Urgency.normal).deathMs, 20000);
    expect(thresholdsFor(urgency: Urgency.elevated).suspectMs, 3000);
    expect(thresholdsFor(urgency: Urgency.elevated).probeTimeoutMs, 2000);
    expect(thresholdsFor(urgency: Urgency.elevated).deathMs, 6000);
  });
}
