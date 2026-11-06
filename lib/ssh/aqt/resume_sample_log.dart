// SPDX-License-Identifier: GPL-3.0-or-later
/// 恢复耗时样本的环形缓冲与分位数聚合。
///
/// 与 `resume_sample.dart` 分开：那边是数据与分档判定，这边是聚合与
/// 序列化。两者的变更原因不同（加字段 vs 改统计口径）。
///
/// 纯 Dart，不做 IO —— 落盘由调用方负责（`ReconnectService` 持有 IO），
/// 与 `conn/conn_trace.dart` 的分工一致。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'resume_sample.dart';

/// 一个档位的统计量。
///
/// [p50] / [p90] 非空：`statsByBucket()` 只为**至少有一个样本**的档位建
/// 条目（见那里的 `putIfAbsent`），所以分位数必然算得出来。可空性是从
/// [percentile] 的通用签名机械继承来的 —— 那个函数要处理空输入，这个
/// 类不需要。把不可达状态留在类型里，只会逼下游写永远为真的 null 分支。
class BucketStats {
  final int n;
  final int p50;
  final int p90;
  const BucketStats({required this.n, required this.p50, required this.p90});
}

/// 最近邻分位数。空列表返回 null。
///
/// **不修改入参** —— 调用方传进来的往往是 `samples` 的投影，就地排序会
/// 打乱样本的时间顺序，而导出的样本要保持时序才能和 conn_trace 对照。
///
/// ## 取值规则与它的偏向
///
/// 下标取 `((n-1) * p).round()`，而 Dart 的 `round()` 对 `.5` 是**远离零**
/// 取整。后果是偶数样本量下 p50 偏向**较大**的那个：10 个样本
/// `[10,20,…,100]` 的 p50 是 **60** 而不是 50，2 个样本 `[100,200]` 的
/// p50 是 **200** 而不是 100。
///
/// 这是**有意选的**，不是 off-by-one：这套设施用来判断恢复耗时有没有
/// 超过验收线，偏向高估比偏向低估安全 —— 低估会让人误判「已经达标」，
/// 而找出没达标的地方正是它存在的全部理由。
///
/// 分位数本来就没有唯一定义（nearest-rank ceil/floor、round-half-even、
/// R type 6…… 各有各的下标）。**改这个规则会静默改变全部历史基线数据的
/// 含义**，让改动前后采的样本不可比。要改就得同时作废已有基线。
int? percentile(List<int> values, double p) {
  if (values.isEmpty) return null;
  final sorted = List<int>.from(values)..sort();
  final idx = ((sorted.length - 1) * p).round();
  return sorted[idx];
}

/// 五段各自的 p50，配 [ResumeSampleLog.segmentStats]。
///
/// 五个字段**相加不等于**总耗时的 p50 —— 每段独立取分位数，见那个方法的
/// 文档。要对账总耗时请用 [ResumeSampleLog.statsAll]。
class SegmentStats {
  final int n;
  final int decideMs;
  final int retryMs;
  final int handshakeMs;
  final int transferMs;
  final int applyMs;
  const SegmentStats({
    required this.n,
    required this.decideMs,
    required this.retryMs,
    required this.handshakeMs,
    required this.transferMs,
    required this.applyMs,
  });
}

class ResumeSampleLog {
  final int cap;
  final List<ResumeSample> _samples = [];

  ResumeSampleLog({this.cap = 64});

  List<ResumeSample> get samples => List.unmodifiable(_samples);

  /// 探测命中次数（心跳证实旧连接还活着，于是**没有发生恢复**），按档位记。
  ///
  /// 不做成 [ResumeSample]：命中意味着这次压根没有恢复，没有五段耗时可言，
  /// 塞进 64 条的样本环只会白占额度。而它又必须被记下来 —— 探测命中率是 90s 阈值那个赌注成立与否的
  /// 唯一证据（150ms 探测换掉一次数百毫秒的 RESUME，值不值全看命中多少）。
  ///
  /// 命中率 = probeHits[b] / (probeHits[b] + statsByBucket()[b].n)
  final Map<BackgroundBucket, int> probeHits = {};

  void recordProbeHit(BackgroundBucket? bucket) {
    if (bucket == null) return;
    probeHits[bucket] = (probeHits[bucket] ?? 0) + 1;
  }

  /// 这份日志有没有值得落盘的东西。
  ///
  /// 判据不能只看 [samples]：一档如果整轮都是探测命中——恰恰是 90s 阈值
  /// 那个赌注成立时的典型形态——[samples] 会一直是空的。调用方（导出
  /// 守卫）原本只查 `samples.isEmpty`，赌注越成立、命中越多，数据反而
  /// 越干净地一个文件都不写。把判据做成这里的纯数据 getter 而不是散在
  /// IO 方法里的 if，是为了能被测试直接断言，不必依赖
  /// `getApplicationSupportDirectory()`。
  bool get hasAnythingToExport => samples.isNotEmpty || probeHits.isNotEmpty;

  void add(ResumeSample s) {
    _samples.add(s);
    while (_samples.length > cap) {
      _samples.removeAt(0);
    }
  }

  /// 按后台时长分档的统计量。
  ///
  /// 只统计 [ResumeOutcomeKind.ok] 且有档位的样本：
  /// * abandoned / failed 的耗时是「放弃时刻」而非「完成时刻」，混进去会把
  ///   p90 拉到毫无意义的高位；
  /// * 无档位的样本不是从后台回来的，与分档问题无关。
  ///
  /// 没有样本的档位**不出现在结果里**，而不是给一个 n=0 的空壳 —— 后者会
  /// 在 overlay 上占一行，把真正有数据的档位挤下去。
  Map<BackgroundBucket, BucketStats> statsByBucket() {
    final grouped = <BackgroundBucket, List<int>>{};
    for (final s in _samples) {
      if (s.outcome != ResumeOutcomeKind.ok) continue;
      final b = s.bucket;
      if (b == null) continue;
      grouped.putIfAbsent(b, () => []).add(s.totalMs);
    }
    return grouped.map((b, v) => MapEntry(
          b,
          BucketStats(
            n: v.length,
            // `!` 而不是 `?? 0`：v 恒非空（见上面的 putIfAbsent），断言失败
            // 说明这个不变量被改坏了，那时候炸出来比静默记 0 强 —— 静默的 0
            // 会混进基线数据，看起来像一次真实的「零耗时恢复」。
            p50: percentile(v, 0.5)!,
            p90: percentile(v, 0.9)!,
          ),
        ));
  }

  /// 全部 ok 样本的总耗时统计，**不分档**。没有 ok 样本时返回 null。
  ///
  /// 与 [statsByBucket] 是两个问题：那个服务于「90s 阈值这个赌注成立没有」，
  /// 所以只看从后台回来的样本，跳过 `backgroundMs == null` 的那些是对的。
  /// 但真机上那些恰恰是大多数 —— 一次实测 45 个样本里 40 个是网络切换 /
  /// 看门狗触发的，一个都不进分档视图。于是 overlay 上那几行 `n:1` / `n:4`
  /// 的 p50 看起来像整体表现，实际只由一两个样本算出。
  ///
  /// 这个 getter 给出那个缺失的整体视图。判 `ok` 的理由与 [statsByBucket]
  /// 相同：abandoned / failed 的耗时是「放弃时刻」而非「完成时刻」。
  BucketStats? statsAll() {
    final v = [
      for (final s in _samples)
        if (s.outcome == ResumeOutcomeKind.ok) s.totalMs
    ];
    if (v.isEmpty) return null;
    return BucketStats(n: v.length, p50: percentile(v, 0.5)!, p90: percentile(v, 0.9)!);
  }

  /// 五段各自的 p50。没有 ok 样本时返回 null。
  ///
  /// **每段独立取分位数**，不是「取中位样本再读它的分段」—— 后者会让某一次
  /// 恰好总耗时居中的样本决定全部五个读数，而慢在握手和慢在传输完全可能出现
  /// 在不同样本上。代价是五个 p50 相加不等于总 p50，这是分位数的固有性质，
  /// 不是 bug：它们回答的是「每一段各自的典型耗时」。
  ///
  /// 只用 `ok` 样本，理由见 `ResumeSample.close()` 的文档：abandoned / failed
  /// 样本里没走到的段兜底为 0，从最后一个已知时刻到结束的时间全堆进最后一段，
  /// 混进来会让分段归因彻底失真。
  SegmentStats? segmentStats() {
    final ok = [
      for (final s in _samples)
        if (s.outcome == ResumeOutcomeKind.ok) s
    ];
    if (ok.isEmpty) return null;
    int p50of(int Function(ResumeSample) f) =>
        percentile([for (final s in ok) f(s)], 0.5)!;
    return SegmentStats(
      n: ok.length,
      decideMs: p50of((s) => s.decideMs),
      retryMs: p50of((s) => s.retryMs),
      handshakeMs: p50of((s) => s.handshakeMs),
      transferMs: p50of((s) => s.transferMs),
      applyMs: p50of((s) => s.applyMs),
    );
  }

  /// 一行一样本的纯文本，供落盘。
  ///
  /// **不含 [probeHits]**：这份文本是「一行一样本、固定列数」的契约（见
  /// `ResumeSample.toLine()`），下游按这个契约逐行解析。命中计数是按档位
  /// 聚合的标量，不是样本，混进去会让某些行的列数和含义跟其余行不一样，
  /// 解析器要么得特殊处理这一行、要么直接读错。命中数走独立的兄弟文件
  /// 落盘（`ReconnectService.exportResumeSamples()` 里的
  /// `resume-probe-hits.txt`），道理和当初把 resume-samples 从
  /// conn-trace 里分出来一样：格式不同源就不共享同一份文本。
  String export() => _samples.map((s) => s.toLine()).join('\n');

  /// 仅供测试 —— 全局状态会在用例之间泄漏。
  @visibleForTesting
  void clear() {
    _samples.clear();
    probeHits.clear();
  }
}
