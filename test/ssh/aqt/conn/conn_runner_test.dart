import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_runner.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

AqtConnRunner _noopRunner() => AqtConnRunner(
      onProbe: () {},
      onResume: () {},
      onBootstrap: () {},
      onClose: () {},
      onBanner: (_) {},
      onClearBanner: () {},
      scheduleTick: (_) {},
      cancelTick: () {},
    );

void main() {
  test('runner 把事件喂进状态机并执行 actions', () {
    final probes = <int>[];
    final ticks = <int>[];
    final r = AqtConnRunner(
      onProbe: () => probes.add(1),
      onResume: () {},
      onBootstrap: () {},
      onClose: () {},
      onBanner: (_) {},
      onClearBanner: () {},
      scheduleTick: (ms) => ticks.add(ms),
      cancelTick: () {},
    );
    r.state = const MachineState(phase: ConnPhase.live, observeStartMs: 0);
    r.feed(const WatchdogTick(),
        const Facts(nowMs: 11000, rawRecvAgeMs: 11000));
    expect(r.state.phase, ConnPhase.suspect);
    expect(probes.length, 1);
    expect(ticks, isNotEmpty);
  });

  test('每次 feed 都进轨迹', () {
    final r = _noopRunner();
    r.state = const MachineState(phase: ConnPhase.live, observeStartMs: 0);
    r.feed(const WatchdogTick(), const Facts(nowMs: 5000, rawRecvAgeMs: 100));
    expect(r.trace.lines.length, 1);
    expect(r.trace.lines.single, contains('WatchdogTick'));
  });

  test('判死时执行 StartResume 与 CancelTick', () {
    var resumes = 0;
    var cancels = 0;
    final r = AqtConnRunner(
      onProbe: () {},
      onResume: () => resumes++,
      onBootstrap: () {},
      onClose: () {},
      onBanner: (_) {},
      onClearBanner: () {},
      scheduleTick: (_) {},
      cancelTick: () => cancels++,
    );
    r.state = const MachineState(phase: ConnPhase.live, observeStartMs: 0);
    // 25s 沉默 → 越过 death 天花板 → 当场判死
    r.feed(const WatchdogTick(),
        const Facts(nowMs: 25000, rawRecvAgeMs: 25000));
    expect(r.state.phase, ConnPhase.recovering);
    expect(resumes, 1);
    expect(cancels, 1);
  });

  // 约束要能被检查，否则会慢慢腐蚀。
  // 仓库已有"锁住源码形状"的先例（test/hooks/notify_hooks_test.dart 断言
  // 文档与脚本逐字节一致）。
  test('runner 源码里除 switch(action) 外不得读 state / facts 做分支', () {
    final src = File('lib/ssh/aqt/conn/conn_runner.dart').readAsStringSync();
    // 去掉注释行，避免注释里的示例误报
    final code = src
        .split('\n')
        .where((l) =>
            !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
        .join('\n');
    for (final pattern in ['if (state', 'if (_state', 'if (facts', 'if (f.']) {
      expect(code, isNot(contains(pattern)),
          reason: 'runner 不许做判断，判断全在 step() 里：命中 "$pattern"');
    }
  });
}
