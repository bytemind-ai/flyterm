// 阈值一律从 LivenessSupervisor 的常量现读，不写字面秒数。
//
// 这个文件原先钉的是 30/40/45s，而实现放宽到了 30/45/75s（见类里的注释：
// 旧窗口太激进，蜂窝切换典型 25–35s，每次切换都会触发 roaming 甚至判死）。
// 钉字面量的结果是「40s 应当 roaming」这类断言把一次**刻意的**放宽报成回归，
// 而真正该守的东西——三档的先后顺序、以及 grace 之后留给漫游的余量——反而
// 没有任何用例覆盖。那条不变量单独一条用例守着，见文件末尾。
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_interface.dart';
import 'package:flyterm/ssh/ssp_v2/transport/liveness_supervisor.dart';

const _tick = Duration(seconds: 1);

void main() {
  test('emits gracePeriod once past kGraceAfter', () {
    final s = LivenessSupervisor();
    final t0 = DateTime(2026, 5, 10);
    s.lastInbound = t0;
    expect(s.evaluate(t0.add(LivenessSupervisor.kGraceAfter + _tick))?.kind,
        SspLivenessKind.gracePeriod);
  });

  test('emits roaming once past kRoamAfter', () {
    final s = LivenessSupervisor();
    final t0 = DateTime(2026, 5, 10);
    s.lastInbound = t0;
    s.evaluate(t0.add(LivenessSupervisor.kGraceAfter + _tick));
    expect(s.evaluate(t0.add(LivenessSupervisor.kRoamAfter + _tick))?.kind,
        SspLivenessKind.roaming);
  });

  test('emits hardReconnectNeeded once past kHardAfter', () {
    final s = LivenessSupervisor();
    final t0 = DateTime(2026, 5, 10);
    s.lastInbound = t0;
    expect(s.evaluate(t0.add(LivenessSupervisor.kHardAfter + _tick))?.kind,
        SspLivenessKind.hardReconnectNeeded);
  });

  test('re-fires roaming every kRoamRetryInterval while still stale', () {
    // 第一次 roam 常常赶在 OS 路由表切换之前，所以卡在 roaming 期间要反复重发。
    final s = LivenessSupervisor();
    final t0 = DateTime(2026, 5, 10);
    s.lastInbound = t0;
    final firstRoamAt = t0.add(LivenessSupervisor.kRoamAfter + _tick);
    expect(s.evaluate(firstRoamAt)?.kind, SspLivenessKind.roaming);
    expect(s.evaluate(firstRoamAt.add(_tick)), isNull,
        reason: '重发间隔没到，不该再发一次');
    expect(
        s.evaluate(firstRoamAt.add(LivenessSupervisor.kRoamRetryInterval))
            ?.kind,
        SspLivenessKind.roaming);
  });

  test('each state emits at most once until reset', () {
    final s = LivenessSupervisor();
    final t0 = DateTime(2026, 5, 10);
    s.lastInbound = t0;
    final graced = t0.add(LivenessSupervisor.kGraceAfter + _tick);
    expect(s.evaluate(graced), isNotNull);
    expect(s.evaluate(graced.add(_tick)), isNull);
  });

  test('onPacket resets to healthy', () {
    final s = LivenessSupervisor();
    final t0 = DateTime(2026, 5, 10);
    s.lastInbound = t0;
    final stale = t0.add(LivenessSupervisor.kHardAfter + _tick);
    s.evaluate(stale);
    s.onPacket(stale.add(_tick));
    expect(s.state, SspLivenessKind.healthy);
  });

  test('healthy while gap stays under kGraceAfter', () {
    final s = LivenessSupervisor();
    final t0 = DateTime(2026, 5, 10);
    s.lastInbound = t0;
    expect(s.evaluate(t0.add(LivenessSupervisor.kGraceAfter - _tick)), isNull);
    expect(s.state, SspLivenessKind.healthy);
  });

  // 数值护栏。调阈值时照着改这里是预期成本，但顺序和余量这两条不变量不该被
  // 任何一次调整破坏。
  test('thresholds stay ordered with room for a cellular handoff', () {
    expect(LivenessSupervisor.kGraceAfter, const Duration(seconds: 30));
    expect(LivenessSupervisor.kRoamAfter, const Duration(seconds: 45));
    expect(LivenessSupervisor.kHardAfter, const Duration(seconds: 75));

    expect(LivenessSupervisor.kGraceAfter,
        lessThan(LivenessSupervisor.kRoamAfter));
    expect(LivenessSupervisor.kRoamAfter,
        lessThan(LivenessSupervisor.kHardAfter));

    // 蜂窝切换典型 25–35s。判死点必须比它远得多，否则每次切网都是一次
    // 硬重连 —— 那正是旧的 30/40/45 窗口被放宽的原因。
    expect(LivenessSupervisor.kHardAfter - LivenessSupervisor.kGraceAfter,
        greaterThanOrEqualTo(const Duration(seconds: 30)));
  });
}
