// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

/// 传输速率与 ETA 的采样器。
///
/// ## 为什么用滑动窗口而不是指数衰减
///
/// 指数衰减（EMA）在速率突变时读数会长时间飘着不收敛：网络从 5 MB/s 掉到
/// 200 KB/s，用户要等好几秒才看到真实值。滑动窗口是「最近实际发生了什么」，
/// 响应更快、解释更直白 —— 对传输进度这种用户盯着看的东西，可预期性比平滑
/// 更重要。
///
/// ## 为什么样本不足时返回 null 而不是 0
///
/// 刚起步的速率被缓冲区填充过程污染（第一秒常虚高或虚低）。返回 null 让 UI
/// 显示「计算中」，而不是一个会跳变的假数字 —— 假数字比没有数字更让人不安。
///
/// 纯 Dart、无 Flutter 依赖，可独立单测。**刻意不依赖 `dartssh2` 或本仓库
/// 其他模块**：将来 QUIC/AQT 那套传输想接（它的传输机制和 SFTP 是两套），
/// 喂数据即可，不必把这套适配过去。
class RateMeter {
  /// 窗口长度。5 秒是「足够平滑、又能跟上突变」的折中。
  static const window = Duration(seconds: 5);

  final List<_Sample> _samples = [];

  /// 记录一个样本：[bytesDone] 是**累计**字节数（含续传断点）。
  void sample({required int bytesDone, required DateTime at}) {
    _samples.add(_Sample(bytesDone, at));
    final cutoff = at.subtract(window);
    // 保留一个刚好早于窗口的样本 —— 它是窗口左端点，没有它算不出窗口内的
    // 完整增量（只有窗口内的样本会低估实际传输量）。
    while (_samples.length > 2 && _samples[1].at.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  /// 速率（字节/秒）。样本不足或时间跨度为 0 时返回 null。
  double? get bytesPerSecond {
    if (_samples.length < 2) return null;
    final first = _samples.first;
    final last = _samples.last;
    final seconds =
        last.at.difference(first.at).inMilliseconds / 1000.0;
    if (seconds <= 0) return null;
    final delta = last.bytesDone - first.bytesDone;
    if (delta < 0) return null; // 不该发生，但别让负数速率流出去
    return delta / seconds;
  }

  /// 剩余时间。[totalBytes] 未知（0 或 null）或速率不可用时返回 null。
  Duration? etaFor({required int totalBytes, required int bytesDone}) {
    if (totalBytes <= 0) return null;
    final rate = bytesPerSecond;
    if (rate == null || rate <= 0) return null;
    final remaining = totalBytes - bytesDone;
    if (remaining <= 0) return Duration.zero;
    return Duration(seconds: (remaining / rate).ceil());
  }

  /// 清空所有样本。
  ///
  /// **续传前必须调用。** 续传时 [sample] 的 bytesDone 从断点起算（比如
  /// 500 MB），而上一次传输残留的样本是 0 —— 差值会把整个断点算成瞬时速率，
  /// 显示出一个荒谬的数字。
  void reset() => _samples.clear();
}

class _Sample {
  final int bytesDone;
  final DateTime at;
  const _Sample(this.bytesDone, this.at);
}

/// 人类可读的速率。null → '—'（「暂不可知」，不是 0）。
String formatRate(double? bytesPerSecond) {
  if (bytesPerSecond == null) return '—';
  if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

/// 人类可读的剩余时间。null → '—'。
///
/// 超过 1 小时只报小时 + 分钟（「1h23m」）—— 精确到秒没有意义，因为 ETA
/// 本身是按当前速率外推的，速率一变它就变。
String formatEta(Duration? eta) {
  if (eta == null) return '—';
  final s = math.max(0, eta.inSeconds);
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m${(s % 60).toString().padLeft(2, '0')}s';
  return '${s ~/ 3600}h${((s % 3600) ~/ 60).toString().padLeft(2, '0')}m';
}
