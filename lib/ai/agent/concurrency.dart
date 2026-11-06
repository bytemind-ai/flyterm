// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ai/agent/concurrency.dart

/// 带两层配额的滑动窗口调度器。
///
/// ## 为什么是滑动窗口而不是批次屏障
///
/// 原来的并行桶是 `for (i += limit) { await Future.wait(batch) }` —— 批与批
/// 之间是屏障。5 条只读命令分 2 批，批 1 里有一条 `journalctl` 跑 8 秒，批 2
/// 那两条 `echo` 级的就干等 8 秒。滑动窗口一条完成就补一条。
///
/// ## 为什么配额分两层
///
/// `_kMaxParallel` 的注释写明它挡三样：手机上行、SSH 连接的窗口、远端的负载。
/// 后两条是 per-connection 的，跨机时本就不该共享；第一条是全局的。于是
/// [perKeyLimit] 按目标机计数，[globalLimit] 兜住「模型一轮请求 20 台机器」。
///
/// ## 返回值里的 null 是什么
///
/// 两种情形：[shouldStop] 让它没能起飞，或 [task] 抛了。**调用方负责把 null
/// 翻译成合适的结果**——`AgentLoop._executeRound` 末尾已经有
/// `byIndex[i] ?? ToolResult(...)` 这个兜底，不要在这里编造。
///
/// [task] **不应该**抛：调用方已经逐个 try/catch 过（`Future.wait` 的
/// fail-fast 会让一条抖动吃掉另两条的成功结果，那是现有代码专门防过的坑）。
/// 这里再兜一层只是保证调度器本身**永不 rethrow**。
Future<List<T?>> runWithLimits<T>({
  required int count,
  required String? Function(int index) keyOf,
  required Future<T> Function(int index) task,
  required int perKeyLimit,
  required int globalLimit,
  bool Function()? shouldStop,
}) async {
  // 不是死锁 —— 一条都起不来时 `inFlight.isEmpty` 会立刻 break。后果是
  // **整桶静默返回全 null**，而调用方会把 null 翻译成「会话被取消了」，
  // 那比死锁更难查（功能看起来正常，只是所有并行工具都「没执行」）。
  // release 档 assert 不生效，所以这两个值只能是常量，不能来自外部输入。
  assert(perKeyLimit > 0, 'perKeyLimit 为 0 会让整桶静默返回 null');
  assert(globalLimit > 0, 'globalLimit 为 0 会让整桶静默返回 null');

  final out = List<T?>.filled(count, null);
  if (count == 0) return out;

  final inFlight = <Future<void>>{};
  final perKey = <String?, int>{};
  final pending = [for (var i = 0; i < count; i++) i];

  void start(int i) {
    final k = keyOf(i);
    perKey[k] = (perKey[k] ?? 0) + 1;
    late Future<void> f;
    f = task(i).then<void>(
      (v) => out[i] = v,
      // 调度器永不 rethrow：一条抛出不能让 `Future.any` 把整轮带走。
      onError: (Object _, StackTrace __) {},
    ).whenComplete(() {
      perKey[k] = perKey[k]! - 1;
      inFlight.remove(f);
    });
    inFlight.add(f);
  }

  while (true) {
    if (!(shouldStop?.call() ?? false)) {
      // **必须扫描全部待起飞项，不能只看队头。** 只推进队头的话，3 条打
      // A 机的调用会把后面 1 条打 B 机的堵死——那正是两层配额要消除的
      // 队头阻塞。
      pending.removeWhere((i) {
        if (inFlight.length >= globalLimit) return false;
        if ((perKey[keyOf(i)] ?? 0) >= perKeyLimit) return false;
        start(i);
        return true;
      });
    }
    if (inFlight.isEmpty) break;
    // 等最早完成的那一条，然后回到循环顶部补位。
    await Future.any(inFlight.toList());
  }

  return out;
}
