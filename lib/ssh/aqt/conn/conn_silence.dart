// SPDX-License-Identifier: GPL-3.0-or-later
/// 沉默的度量与紧迫度分级。
///
/// 这个文件承载整套设计里最微妙的一条不变量：**只能判断你实际观测到的沉默**。
/// `last_recv_age_ms` 的原始值在后台会一直累积（app 心跳被取消，只剩 quinn 的
/// 15s keepalive），所以回前台第一个 tick 看到的 10–30s 原始 age 说明不了链路
/// 健康。曾经把它直接喂给判死逻辑，导致几乎每次回前台都判连接已死。
library;

import 'dart:math';

import 'conn_types.dart';

/// 盲区判据：`rawAge − observedSilence` 超过一个 quinn keepalive 周期，才说明
/// 确实漏掉了本该收到的包。
///
/// 取值等于两端的 `keep_alive_interval`（`rust/aqt_client_ffi/src/client.rs` 与
/// `rust/flyterm-server/src/endpoint.rs` 都是 15s）。少于它无法与抖动区分。
const int kBlindGapMs = 15000;

enum Urgency { normal, elevated }

class Thresholds {
  final int suspectMs;
  final int probeTimeoutMs;
  /// 丢 tick 时的安全网：单次 tick 直接越过它就当场判死，不经 probe。
  /// 见 `conn_machine_liveness_test.dart` 的「丢 tick：单次
  /// 越过 death 天花板」那条用例。
  final int deathMs;

  const Thresholds({
    required this.suspectMs,
    required this.probeTimeoutMs,
    required this.deathMs,
  });
}

Thresholds thresholdsFor({required Urgency urgency}) => switch (urgency) {
      Urgency.normal => const Thresholds(
          suspectMs: 10000, probeTimeoutMs: 3000, deathMs: 20000),
      // 有盲区时更急：链路很可能在盲区里就死了，没必要再等一个稳态周期。
      Urgency.elevated => const Thresholds(
          suspectMs: 3000, probeTimeoutMs: 2000, deathMs: 6000),
    };

/// 实际观测到的沉默时长。
///
/// 取代 `AqtTransport.effectiveWatchdogAgeMs` 的两层归一化：那里分别按
/// `msSinceForeground` 与 `msSinceConnected` 夹取两次。因为
/// `min(now−A, now−B) = now − max(A,B)`，只要令
/// `observeStartMs = max(connectedAt, lastForegroundAt)` 就一行覆盖 ——
/// 等价性由 conn_silence_test.dart 穷举 20000 组验证。
int observedSilence(MachineState s, Facts f) {
  final start = s.observeStartMs;
  if (start == null) return f.rawRecvAgeMs;
  return min(f.rawRecvAgeMs, f.nowMs - start);
}

/// 是否处于"之前有一段观测盲区"的状态。
///
/// 取代固定 8s 的 `kForegroundResumeWindowMs` 窗口：那个窗口是在近似这件事，
/// 而盲区长度可以直接算出来，比"前台后 8 秒内"精确，且不需要窗口常量。
bool elevated(MachineState s, Facts f) =>
    f.rawRecvAgeMs - observedSilence(s, f) > kBlindGapMs;

Urgency urgencyFor(MachineState s, Facts f) =>
    elevated(s, f) ? Urgency.elevated : Urgency.normal;

/// PTY 停流判死阈值。
///
/// 取 45s 而不是更短，是因为误判有代价：RESUME 的 prelude 带 `ESC c`(RIS) +
/// `ESC[!p`(DECSTR)，屏幕会清一次再重放，TUI 里看得见。45s 已经远超任何
/// 交互式程序的响应时间（真机现场停了 96s），又不至于把「按了一下键、盯着
/// 一个静止的 vim 界面看半分钟」误判成坏死。
const int kPtyStallMs = 45000;

/// 「近期有过写入」的窗口。
///
/// 超出它的写入不再构成"期待输出"的理由：早上敲的命令，下午的沉默说明不了
/// 任何事。5 分钟足以覆盖「提交了一个跑很久的任务，中途没有输出」这类真正
/// 需要保护的场景。
const int kWriteRelevanceMs = 300000;

/// 传输层活着，但终端已经收不到数据了。
///
/// 这是 [observedSilence] 覆盖不到的一整个维度。`rawRecvAgeMs` 数的是入向
/// UDP 字节，ACK / keepalive / 心跳 datagram 都会让它归零；PTY 数据却走独立
/// 的 QUIC bi-stream。stream 停摆而连接层照常喘气时，前者一无所知。
///
/// 三个前置条件各自挡住一类正常的静默：
///   • 后台 —— 后台本来就不出帧，这段沉默没有说明力（回前台那条路径自会处理）
///   • 从未写过输入 —— 没发过东西就没有理由期待下文
///   • 写入已经很旧 —— 那次写入的回音早收到了，此后的静默是空闲不是坏死
/// 不依赖 [Facts] 的判据本体。
///
/// 单独抽出来是因为它有第二个调用点：`ReconnectService` 里那个「心跳还活着
/// 就 SKIP 掉整次恢复」的分支。那里拿不到 Facts，若在当地重写一遍判断，两份
/// 判据迟早漂移 —— 而它们一旦不一致，就会出现「状态机判死、外部触发又跳过」
/// 这种互相抵消的死局。
bool isPtyStalled({
  required bool isForeground,
  required int ptySilenceMs,
  required int? sinceLastWriteMs,
}) {
  if (!isForeground) return false;
  if (ptySilenceMs < kPtyStallMs) return false;
  final w = sinceLastWriteMs;
  if (w == null) return false;
  return w <= kWriteRelevanceMs;
}

bool ptyStalled(MachineState s, Facts f) => isPtyStalled(
      isForeground: f.isForeground,
      ptySilenceMs: f.ptySilenceMs,
      sinceLastWriteMs: f.sinceLastWriteMs,
    );
