/// PTY 停流判死 —— 传输层活着不等于终端还在收数据。
///
/// 背景（2026-09-06 真机现场，Screenshot_2026-09-06-11-29-19）：
/// QUIC 连接一切正常（qstate:connected dead:false pathDied:false，心跳
/// 150ms 返回），但终端 96 秒收不到一个字节，远端 Claude Code 的画面冻结在
/// 96 秒前。用户看到的是永久卡死，而系统始终认为连接健康。
///
/// 根因是活性判据的信号源选错了层：`rawRecvAgeMs` 来自 Rust 侧对
/// `conn.stats().udp_rx.bytes` 的 1Hz 轮询，而那个计数器**任何入向 UDP 包**
/// 都会增长 —— ACK、PATH_RESPONSE、quinn 的 15s keepalive、以及我们自己
/// 发的心跳 datagram。终端数据走的却是独立的 QUIC bi-stream。
///
/// 于是形成一个自我确认的闭环：
///   t=0     收到 keepalive → silence=0 → live
///   t=10s   silence≥suspectMs → suspect + SendProbe（datagram）
///   t=10s+ε 探针回包 → udp_rx.bytes 增长 → silence=0 → live
///   t=20s   再次 suspect……
/// keepalive 周期 15s 正好落在 suspectMs(10s) 与 deathMs(20s) 之间，silence
/// 永远够不到判死线。探针治好了它自己制造的怀疑。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_machine.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

void main() {
  test('真机现场：传输层新鲜但 PTY 停流 96s → 必须判死并发起恢复', () {
    // 截图现场的数值：noEcho:98s（距最后一次写入）、ptyAge:96s（距最后一次
    // 收到 PTY 数据）。rawRecvAge 取 1s —— 心跳/keepalive 刚把它刷新过，这
    // 正是旧实现判"健康"的原因。
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(
      nowMs: 200000,
      rawRecvAgeMs: 1000,
      ptySilenceMs: 96000,
      sinceLastWriteMs: 98000,
    );
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.recovering,
        reason: '传输层再新鲜，终端 96 秒没数据也必须判死');
    expect(actions.whereType<StartResume>().length, 1);
  });

  test('probing 中同样适用 —— 探针刷新了 rawRecvAge 也救不回来', () {
    // 截图抓到的就是这一刻：mphase:probing。旧实现下探针一回包就退回 live，
    // 循环重来；PTY 维度必须能越过这个循环。
    const s = MachineState(
        phase: ConnPhase.probing, observeStartMs: 0, suspectSinceMs: 190000);
    const f = Facts(
      nowMs: 200000,
      rawRecvAgeMs: 200,
      ptySilenceMs: 96000,
      sinceLastWriteMs: 98000,
    );
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.recovering);
    expect(actions.whereType<StartResume>().length, 1);
  });

  test('空闲会话不误判：没写过输入就不期待输出', () {
    // 用户十分钟没碰终端，远端也就没有输出 —— 这是正常的静默，不是坏死。
    // 判据要求"近期有过写入"正是为了挡住这一类。
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(
      nowMs: 900000,
      rawRecvAgeMs: 1000,
      ptySilenceMs: 600000,
      sinceLastWriteMs: null, // 从未写过
    );
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.live);
    expect(actions.whereType<StartResume>(), isEmpty);
  });

  test('写入是很久以前的事 → 不判死', () {
    // 早上敲了一条命令，人走开了，下午回来。PTY 沉默很久，但那次写入的
    // 回音早就收到过了，这段沉默说明不了任何问题。
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(
      nowMs: 900000,
      rawRecvAgeMs: 1000,
      ptySilenceMs: 600000,
      sinceLastWriteMs: 601000, // 写入只比 PTY 沉默早 1 秒，但两者都超出关注窗口
    );
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.live);
    expect(actions.whereType<StartResume>(), isEmpty);
  });

  test('刚写完还没来得及回音 → 不判死（这是幻影判据的地盘，阈值内不抢）', () {
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(
      nowMs: 200000,
      rawRecvAgeMs: 500,
      ptySilenceMs: 3000,
      sinceLastWriteMs: 3500,
    );
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.live);
    expect(actions.whereType<StartResume>(), isEmpty);
  });

  test('后台不判 PTY 停流 —— 后台本来就不期待输出', () {
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(
      nowMs: 200000,
      rawRecvAgeMs: 1000,
      ptySilenceMs: 96000,
      sinceLastWriteMs: 98000,
      isForeground: false,
    );
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(actions.whereType<StartResume>(), isEmpty,
        reason: '后台的沉默没有说明力，回前台那条路径自会处理');
    expect(s2.phase, isNot(ConnPhase.recovering));
  });

  test('PTY 停流判死不依赖 rawRecvAge —— 两个维度是并列的', () {
    // 传输层已经很旧（25s > deathMs）时走的是原有天花板分支，这里只确认
    // 新分支没有把它挡掉。
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(nowMs: 200000, rawRecvAgeMs: 25000, ptySilenceMs: 0);
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.recovering);
    expect(actions.whereType<StartResume>().length, 1);
  });
}
