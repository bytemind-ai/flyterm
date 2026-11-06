// SPDX-License-Identifier: GPL-3.0-or-later
/// 一次 QUIC 恢复的耗时样本。
///
/// **纯 Dart，不调 `DateTime.now()`** —— 所有时刻由外部注入，与
/// `conn/conn_machine.dart` 同一套路（那里的文档写明「纯函数是整套设计的
/// 支点」：一条真机失败序列可以原样变成测试向量）。
///
/// 关键约束：五段**首尾相接、无重叠、无空隙**，加总等于端到端耗时。破坏
/// 这一点，分段数据就无法与总耗时对账，也就失去了归因能力。
library;

/// 恢复由什么触发。不同触发源的耗时不可比 —— 前台恢复带着 Doze 解冻的
/// 网络栈延迟，网络切换恢复带着路由表就绪延迟。混在一起统计会互相污染。
///
/// [userRefresh] 目前没有生产者：用户手动刷新会先落进连接状态机再走
/// `onResume`，和 [watchdog] 走的是同一条路径，两者在调用点无法区分。
/// 保留这个值是为了以后一旦区分开（比如状态机开始携带触发原因），
/// 不用改枚举定义；现在不用为它去找"谁调用了它"。
enum ResumeTrigger { foreground, connectivity, watchdog, userRefresh }

enum ResumeOutcomeKind { ok, abandoned, failed }

/// 后台时长分档。
///
/// 边界选在 30s / 90s 是为了让阈值修正的效果可验证：`under90s` 这一档正是
/// 被旧的 30s 硬编码阈值误伤的区间。
enum BackgroundBucket { under30s, under90s, under3min, under30min, over30min }

/// 返回 null 表示这次恢复不是从后台回来的（网络切换、看门狗等），
/// 不参与分档统计。
BackgroundBucket? bucketFor(int? backgroundMs) {
  if (backgroundMs == null) return null;
  if (backgroundMs < 30 * 1000) return BackgroundBucket.under30s;
  if (backgroundMs < 90 * 1000) return BackgroundBucket.under90s;
  if (backgroundMs < 3 * 60 * 1000) return BackgroundBucket.under3min;
  if (backgroundMs < 30 * 60 * 1000) return BackgroundBucket.under30min;
  return BackgroundBucket.over30min;
}

/// 一次失败的 RESUME 尝试。耗时单独记在这里，**不占用主时间轴** ——
/// 主时间轴上它们被压缩进 ② 段（首次发起 → 最终成功那次的 sentAt）。
class ResumeAttempt {
  final String reason;
  final int elapsedMs;
  const ResumeAttempt({required this.reason, required this.elapsedMs});

  /// 分隔符安全：[reason] 类型上是裸 String，而 `ResumeSample.toLine()` 用
  /// 空格分字段、用 `|` 分 attempts。当前所有来源都是枚举名（安全），但
  /// 类型不保证 —— 有人塞进带空格的自由文本就会打散整行的列格式。
  @override
  String toString() =>
      '${reason.replaceAll(RegExp(r'[\s|]'), '_')}:${elapsedMs}ms';
}

/// 不可变的一次恢复样本。
class ResumeSample {
  final ResumeTrigger trigger;
  final int? backgroundMs;
  final int decideMs;
  final int retryMs;
  final int handshakeMs;
  final int transferMs;
  final int applyMs;
  final List<ResumeAttempt> attempts;
  final int screenBytes;
  final ResumeOutcomeKind outcome;

  const ResumeSample({
    required this.trigger,
    required this.backgroundMs,
    required this.decideMs,
    required this.retryMs,
    required this.handshakeMs,
    required this.transferMs,
    required this.applyMs,
    required this.attempts,
    required this.screenBytes,
    required this.outcome,
  });

  int get totalMs =>
      decideMs + retryMs + handshakeMs + transferMs + applyMs;

  BackgroundBucket? get bucket => bucketFor(backgroundMs);

  /// 一行一样本的纯文本。只含数值与枚举名，不含任何终端内容。
  String toLine() => [
        trigger.name,
        backgroundMs?.toString() ?? '-',
        bucket?.name ?? '-',
        decideMs,
        retryMs,
        handshakeMs,
        transferMs,
        applyMs,
        totalMs,
        screenBytes,
        outcome.name,
        attempts.join('|'),
      ].join(' ');
}

/// 可变的 span builder。各段时刻逐步到达，闭合时产出不可变的
/// [ResumeSample]。
class ResumeSpan {
  final ResumeTrigger trigger;
  final int? backgroundMs;

  /// ① 起点：`resumed` / 连接事件抵达的时刻。
  final int t0;

  int? _t1; // ① 终点 = ② 起点：首次 RESUME 发起
  int? _t2; // ② 终点 = ③ 起点：最终成功那次的 sentAt
  int? _t3; // ③ 终点 = ④ 起点：RESUME_ACK 落地
  int? _t4; // ④ 终点 = ⑤ 起点：快照末字节抵达

  final List<ResumeAttempt> _attempts = [];

  /// 本次恢复的快照字节数。是**属性**不是事件，所以直接赋值而不走 mark*
  /// 方法 —— 后者记录的是时刻，语义上不是一回事。
  int screenBytes = 0;

  ResumeSpan({
    required this.trigger,
    required this.backgroundMs,
    required this.t0,
  });

  void markFirstAttempt(int nowMs) => _t1 ??= nowMs;
  void markSent(int nowMs) => _t2 = nowMs;
  void markAck(int nowMs) => _t3 = nowMs;
  void markTransferDone(int nowMs) => _t4 = nowMs;

  void recordAttempt({required String reason, required int elapsedMs}) {
    _attempts.add(ResumeAttempt(reason: reason, elapsedMs: elapsedMs));
  }

  /// 闭合并产出样本。
  ///
  /// 没走到的段记 **0 而不是 null**：样本的用途是分位数聚合，null 会污染
  /// 求和与排序；而 0 的含义（「这一段没发生」）在配合 [outcome] 读时是
  /// 明确的。abandoned 样本本来就不该混进 ok 的分位数里。
  ///
  /// **abandoned / failed 样本的分段归因不可信**：未走到的段兜底为 0，
  /// 于是从最后一个已知时刻到 [t5] 的全部时间都堆进最后一段。一个在重试
  /// 阶段就放弃的样本，看起来会像是「applyMs 占了 98%」。
  ///
  /// 因此下游只能对 `ok` 样本做分段级别的统计（[ResumeSampleLog.statsByBucket]
  /// 正是这么做的）；abandoned 样本只有 [totalMs] 和 [attempts] 有解读价值。
  ResumeSample close({
    required int t5,
    required ResumeOutcomeKind outcome,
  }) {
    // 逐段取值时向后兜底：任一段缺失，后续段的起点退回上一个已知时刻，
    // 保证不出现负数，也保证五段之和不超过 t5 - t0。
    final t1 = _t1 ?? t0;
    final t2 = _t2 ?? t1;
    final t3 = _t3 ?? t2;
    final t4 = _t4 ?? t3;
    // 单调性校验。总和恒等于 t5-t0 是 telescoping sum 的代数保证，
    // 但**单段非负**不是 —— 乱序 mark 或时钟回退会让某一段变成负数，
    // 而负数会直接污染下游的分位数排序。
    //
    // 用 assert 而不是 clamp：clamp 会把「时刻乱序」这个真实 bug 悄悄
    // 抹平，而这个类型的全部意义就是暴露真实的时序。release 构建下
    // assert 被裁掉，生产路径零成本。
    assert(
      t1 >= t0 && t2 >= t1 && t3 >= t2 && t4 >= t3 && t5 >= t4,
      '恢复 span 的时刻必须单调不减，实际为 '
      't0=$t0 t1=$t1 t2=$t2 t3=$t3 t4=$t4 t5=$t5',
    );
    return ResumeSample(
      trigger: trigger,
      backgroundMs: backgroundMs,
      decideMs: t1 - t0,
      retryMs: t2 - t1,
      handshakeMs: t3 - t2,
      transferMs: t4 - t3,
      applyMs: t5 - t4,
      attempts: List.unmodifiable(_attempts),
      screenBytes: screenBytes,
      outcome: outcome,
    );
  }
}
