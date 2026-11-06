import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';

/// `AqtTransport.close()` 在**从未被订阅过**的 transport 上会不会挂死。
///
/// ## 为什么这是一条关键路径
///
/// `_outputCtrl` 是**单订阅** StreamController（刻意的，为了缓冲 RESUME
/// prelude —— 见 aqt_transport.dart 里它的定义处注释）。Dart 语义：单订阅
/// controller 的 `close()` 返回的 Future 只在 done 事件**被送达订阅者之后**
/// 才完成。没有订阅者时 done 无处可送，`await close()` 永久挂住。
///
/// 而 output 的唯一订阅点是 `SessionManager.startStreaming()`，它只在 RESUME
/// **成功**、调用方把 transport 赋给 `tab.transport` 之后才被调用。
///
/// 于是 RESUME 失败路径上的 transport 永远没有订阅者，而
/// `tryResumeWithInfoDetailed` 有三处 `await t.close()`（state==failed /
/// TimeoutException / catch-all）。挂在那里的后果是整条重连链停摆：
///
///   resume 永不返回
///     → appendResumeResult 永不执行（日志里表现为「发起了却没有结果」）
///     → _retrying / _proactiveResuming 标志永不清除
///     → 后续每一次重连尝试都被这些标志挡掉
///     → QUIC 再也不会恢复
///
/// SSH / mosh 不走 AQT resume，所以同一次网络恢复里它们照常重连 —— 这正是
/// 「SSH 最快、mosh 其次、QUIC 一直不恢复」那个现象的来源。
void main() {
  test('从未被 listen 的 transport，close() 不能挂死', () async {
    final t = AqtTransport.testStub();

    // 挂死则这里抛 TimeoutException。2 秒远大于正常 close 所需（实测
    // broadcast/已cancel 的 controller 都在 3ms 内完成）。
    await t.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail(
          'close() 挂住了 —— _outputCtrl 没有订阅者时 await close() 永不完成'),
    );
  });

  test('有活跃 listener 时，close() 仍然正常完成且送达 done', () async {
    final t = AqtTransport.testStub();
    var gotDone = false;
    final sub = t.output.listen((_) {}, onDone: () => gotDone = true);
    addTearDown(sub.cancel);

    await t.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('有 listener 时 close() 反而挂住了'),
    );
    // 修复不能把「有订阅者时等 done 真正送达」这个既有语义弄丢：
    // startStreaming 的重装配逻辑依赖 onDone 跑过。
    expect(gotDone, isTrue, reason: 'done 应当已经送达订阅者');
  });

  test('listen 过又 cancel 的 transport，close() 不能挂死', () async {
    final t = AqtTransport.testStub();
    final sub = t.output.listen((_) {});
    await sub.cancel();

    await t.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('订阅已取消后 close() 挂住了'),
    );
  });

  test('close() 幂等：连调两次不抛也不挂', () async {
    final t = AqtTransport.testStub(
      port: 1234,
      spki: Uint8List.fromList([1, 2, 3]),
      token: Uint8List(32),
      tabId: 7,
    );
    await t.close().timeout(const Duration(seconds: 2));
    await t.close().timeout(const Duration(seconds: 2),
        onTimeout: () => fail('第二次 close() 挂住了'));
  });

  /// 关闭 QUIC tab 必崩的回归测试。
  ///
  /// ## 上面那个「幂等」测试为什么没兜住
  ///
  /// 它只断言了「不抛也不挂」。但 `testStub` 的 `_handle` 是 `nullptr`，而
  /// `AqtFfi.close`（aqt_ffi.dart:358）开头就是 `if (handle == nullptr)
  /// return;` —— 于是第二次调用在 Dart 层安安静静地过去了，FFI 层的
  /// double free 完全不可见。真机上 `_handle` 是真指针，第二次就要命。
  ///
  /// ## 真机上的两个调用者
  ///
  /// `SessionManager.closeTab()` 一次关闭里 close 了**两遍**同一个 transport：
  ///
  ///   1. session_manager.dart:1523  `closingTab.transport?.close()`
  ///   2. session_manager.dart:1529  `_tabClosedListeners` 回调
  ///        → reconnect_service.dart:904  `_onTabClosed`
  ///        → reconnect_service.dart:906  `feed(TabClosed(), ...)`
  ///        → conn_machine.dart:104      `TabClosed() => [CancelTick(), Close()]`
  ///        → conn_runner.dart:56        `case Close(): onClose()`
  ///        → reconnect_service.dart:503 `onClose: next.close`  ← 同一个实例
  ///
  /// 第二条路径不是字面上的 `transport.close()`，而是经状态机 action 回调
  /// 间接抵达的，所以 grep `.close()` 找不到它。
  ///
  /// ## 崩溃机制
  ///
  /// Rust 的 `aqt_close`（ffi.rs:591）= `Arc::from_raw(handle)` 后立刻 drop。
  /// 稳态 refcount 是 2（Dart 一份 + ffi.rs:483 的 1Hz 轮询 task 一份）：
  ///
  ///   第一次 close → 2→1，轮询 task 还持有，一切正常
  ///   第二次 close → 1→0，SessionHandle 被释放
  ///   约 1 秒后轮询 task 醒来 → `h_poll.conn.read().await`（ffi.rs:496）
  ///     → 从已释放内存读出垃圾 `conn` 指针
  ///     → tokio batch_semaphore 的 `ldar` → SIGSEGV in thread "aqt-rt"
  ///
  /// 崩溃延迟一秒且落在 Rust 线程上，是因为 `aqt_close` 本身不解引用任何东西。
  test('close() 幂等：FFI aqt_close 只能被触达一次', () async {
    final t = AqtTransport.testStub(
      port: 1234,
      spki: Uint8List.fromList([1, 2, 3]),
      token: Uint8List(32),
      tabId: 7,
    );

    await t.close();
    expect(t.ffiCloseCount, 1, reason: '第一次 close 应当正常触达 FFI');

    await t.close();
    expect(
      t.ffiCloseCount,
      1,
      reason: '第二次 close 必须不再触达 FFI —— 否则 Rust 侧对同一个 Arc '
          '减两次引用计数，SessionHandle 提前释放，1Hz 轮询 task 下一个 '
          'tick 就在 aqt-rt 线程上 SIGSEGV',
    );

    // 真机路径是「closeTab 关一次 + 状态机 Close action 再关一次」，
    // 但闸门要对任意次数成立，不只是两次。
    await t.close();
    await t.close();
    expect(t.ffiCloseCount, 1, reason: '闸门必须对任意重复次数成立');
  });

  /// close() 之后其余 FFI 入口必须全部静默 —— 第二个 UAF 根因。
  ///
  /// ## 为什么幂等 close 修完还在崩
  ///
  /// 幂等闸门只保证 `aqt_close` 调一次，refcount 走 2→1。但那个 1 也活不长：
  /// ffi.rs:496 的 1Hz 轮询 task 下一个 tick 读到 `conn.close_reason()`
  /// 非空就 `break`，drop 掉自己那份 Arc —— **refcount 归零，SessionHandle
  /// 被释放**。
  ///
  /// 从那一刻起，`_handle` 是一个悬垂指针。而这个类有 18 个 FFI 入口用它，
  /// close() 之前没有任何一个检查过存活状态：
  ///
  ///   - `setForeground`（最危险：它还会 `_heartbeatTimer ??= Timer.periodic`
  ///     重建心跳，close 刚把 timer 置 null，它转头再起一个每 3 秒
  ///     `aqt_heartbeat(_handle)` 的周期任务）
  ///   - `heartbeat` / `ackNotify` / `roam` / `migrateEndpoint`
  ///   - `resize` / `refreshPathStats` / `resumeTtlSecs` / `lastRecvAgeMs`
  ///
  /// 任何一个在释放之后被触达，就是 use-after-free。崩溃同样延迟约一秒、
  /// 同样落在 Rust 线程上 —— 与 double-free 的现象无法用肉眼区分，所以
  /// 修完第一个根因会以为「没修好」。
  ///
  /// ## 这个测试断言什么
  ///
  /// `testStub` 的 `_handle` 本来就是 null，所以「没触达 FFI」在测试里天然
  /// 成立，断言它没有意义。真正要锁住的是**闸门被触发并记账**：
  /// `ffiCallsAfterClose` 只在「已经 close 过、且仍有人来取 handle」时递增。
  /// 未 close 的 stub 上调同样的方法不能计数，否则闸门就分不清「从未有过
  /// handle」和「handle 已失效」。
  group('close() 之后 FFI 入口全部静默', () {
    AqtTransport makeStub() => AqtTransport.testStub(
          port: 1234,
          spki: Uint8List.fromList([1, 2, 3]),
          token: Uint8List(32),
          tabId: 7,
        );

    /// 每个入口一条用例：调用方式 + 入口名。入口名会被 `lastFfiCallAfterClose`
    /// 记下来并 debugPrint —— 真机上拿不到 tombstone 时，logcat 里的
    /// 「FFI call after close: setForeground」就是残留入口的直接证据。
    final entries = <String, void Function(AqtTransport)>{
      'setForeground': (t) => t.setForeground(true),
      'heartbeat': (t) => t.heartbeat(),
      'ackNotify': (t) => t.ackNotify(1),
      'roam': (t) => t.roam(),
      'migrateEndpoint': (t) => t.migrateEndpoint(),
      'resize': (t) => t.resize(80, 24),
      'refreshPathStats': (t) => t.refreshPathStats(),
      'takeResumeDisposition': (t) => t.takeResumeDisposition(),
      'resumeTtlSecs': (t) => t.resumeTtlSecs,
      'lastRecvAgeMs': (t) => t.lastRecvAgeMs,
    };

    entries.forEach((name, invoke) {
      test('$name 在 close 之后不得取到 handle', () async {
        final t = makeStub();
        await t.close();

        expect(t.ffiCallsAfterClose, 0, reason: 'close 本身不该记账');

        invoke(t);

        expect(
          t.ffiCallsAfterClose,
          1,
          reason: '$name 必须经过闸门 —— 直接用 _handle 就是对已释放内存解引用',
        );
        expect(t.lastFfiCallAfterClose, name,
            reason: '闸门要记下是谁来的，否则真机上还是只能靠猜');
      });
    });

    test('未 close 的 stub 上调用不得记账', () {
      final t = makeStub();
      for (final invoke in entries.values) {
        invoke(t);
      }
      expect(
        t.ffiCallsAfterClose,
        0,
        reason: '闸门必须能分清「从未有过 handle」和「handle 已失效」——'
            '否则 testStub 的正常使用会把计数刷满，真实的 UAF 反而淹没在噪声里',
      );
    });

    /// setForeground 单独再锁一条：它不只是读 handle，还会**重建心跳定时器**。
    /// 光挡住 FFI 调用不够 —— 定时器一旦建起来，它会每 3 秒自己去取一次
    /// handle，把一次性的误用变成持续的。
    test('close 之后 setForeground 不得重建 _heartbeatTimer', () async {
      final t = makeStub();
      await t.close();

      t.setForeground(true);

      expect(
        t.hasHeartbeatTimer,
        isFalse,
        reason: 'close 已经取消了心跳定时器，setForeground 不能把它复活 ——'
            '否则每 3 秒一次 aqt_heartbeat 打在已释放的 SessionHandle 上',
      );
      expect(t.hasWatchdogTimer, isFalse,
          reason: 'watchdog 定时器同理，close 之后不得复活');
    });
  });
}
