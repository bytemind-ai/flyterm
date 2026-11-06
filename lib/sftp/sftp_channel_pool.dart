// SPDX-License-Identifier: GPL-3.0-or-later
/// 每条 SSH 连接**至多一条** SFTP 通道的池子。
///
/// ## 为什么需要它
///
/// `SSHClient.sftp()`（dartssh2）每次调用都会 `_openSessionChannel()` —— 开
/// 一条**新的** SSH session channel，不是复用。而 OpenSSH 的 `sshd` 有
/// `MaxSessions` 上限（默认 10）。凡是「列目录」这种高频小操作，如果每次都
/// 裸调 `client.sftp()`，channel 名额会被迅速吃满，之后每一次 open 都收到
/// `SSHChannelOpenError`（`SSH channel setup failed`）—— 连接本身还活着，
/// 用户看到的却是「SSH 连接错误」。
///
/// `@file` 补全的后台索引（`file_index.dart`）并发 8 个 `listdir`，是把这个
/// 问题从「偶发」放大成「经常」的那根导火索：一批就是 8 条 channel，再叠上
/// agent 的 exec channel 和别处的 SFTP，很容易越过 10。
///
/// 本类把「一条 client → 一条 SFTP 通道」这个不变量收在一个地方。所有
/// `sftpOpsFromClient` 的调用方（agent 的 `sftpOpsProvider`、`@file` 的
/// `listRemoteDir`、`SFTPService.fromClient`）自动共享同一条通道，而不是各开
/// 各的。
///
/// ## 为什么键是 `Object` 而不是 `SSHClient`
///
/// 可测。测试里造不出真的 `SSHClient`（它要一条真连接）。本类只负责「哪些
/// key 对应哪条已开/在飞的通道」，与 SSH 无关。生产侧传的是 `SSHClient`
/// 实例本身。
///
/// ## 为什么用 `Expando` 而不是 `Map`
///
/// `Expando` 不持有强引用：client 被回收时条目自动消失，不需要任何清理逻辑
/// （与 `DeadSshClients` 同一个理由）。用 `Map` 会让每条聊完的连接永远留在
/// 内存里。
library;

class SftpChannelPool {
  SftpChannelPool();

  /// 进程级共享实例。
  ///
  /// `sftpOpsFromClient` 是纯函数式 API（拿一个 client，返回 ops），调用方
  /// 不持有 pool。要让它「同一 client 复用同一条通道」，池子必须是全局的；
  /// 否则每次调用 new 一个 pool，缓存永远冷启动，等于没做。
  static final SftpChannelPool shared = SftpChannelPool();

  /// key → 在飞或已就绪的 ops。「在飞」也缓存，是为了让并发的两个调用者
  /// 汇入同一次开通道，而不是各开一条（与 `AgentExecChannel._connecting`
  /// 同一个理由）。
  final Expando<Future<Object>> _byKey = Expando<Future<Object>>('flyterm.sftpOps');

  /// 取（必要时开）一条通道。
  ///
  /// [key] 通常是 `SSHClient` 实例 —— **按实例身份**判定，不是按内容。
  ///
  /// [open] 只在没有可用条目时调用一次；并发的第二个调用者会汇入第一次的
  /// Future，不会重复开通道。
  ///
  /// 失败时**立即清掉条目**：否则一次开通道失败会让此后每次 `obtain` 都拿到
  /// 同一个已 reject 的 Future，通道再也建不起来（与 `AgentExecChannel.obtain`
  /// 的 `finally` 清理同一个坑）。
  Future<T> obtain<T extends Object>(Object key, Future<T> Function() open) {
    final cached = _byKey[key];
    if (cached != null) return cached.then((v) => v as T);

    final fut = open();
    _byKey[key] = fut;
    // 失败时清掉条目。**用一个吞掉错误的旁路 listener，而不是 `fut.catchError`**
    // —— `catchError` 会造出一条新的 Future，我们不 await 它就会变成未捕获
    // 异常（测试里直接炸掉）。旁路监听只做清理，异常本身仍由返回给调用方的
    // `fut` 传播。
    //
    // 只清自己那一条：evict 之后可能已经有新条目顶上来，把它误删会把别人的
    // 在飞通道也丢掉。
    fut.then<void>((_) {}, onError: (Object _) {
      if (identical(_byKey[key], fut)) _byKey[key] = null;
    });
    return fut;
  }

  /// 丢弃 [key] 的缓存条目。通道开不出来（channel setup failure）或 client
  /// 已死时调用，让下次 `obtain` 重建。
  ///
  /// **不关闭旧通道**：本池只登记 Future，不持有 `SftpClient` 的关闭句柄 ——
  /// 通道的生死跟着底层 SSH client 走（client 关 → 通道自动关）。这里能做的
  /// 只是「下次别再复用它」。
  void evict(Object key) {
    _byKey[key] = null;
  }
}
