// SPDX-License-Identifier: GPL-3.0-or-later
/// `@file` 的一次性目录索引 —— 纯 Dart，`dart:async` 之外零依赖。
///
/// **不 import `flutter/material.dart`。** 与 `mention.dart` 同一个分工：递归的
/// BFS、上限、取消、并发度全是可单测的逻辑，不该和 widget 生命周期缠在一起。
/// widget 那边只负责「什么时候该建、建出来的往哪张表里放」。
///
/// ## 为什么是「后台建索引」而不是「每层现查」
///
/// 逐层懒加载（本文件之前的行为）下钻三层就是三次远端往返，移动网络下每次
/// 100–800ms。参考实现 pi-web 走的是另一条路：一次取回整个工作区的文件列表，
/// 之后纯本地过滤，点目录零往返。本文件是那条路在 SFTP 通道上的落地。
///
/// **为什么不给 flyterm-server 加端点**：`@file` 浏览走的是独立 SSH + SFTP
/// 连接（`terminal_screen.dart` 的 `listRemoteDir`），根本不经过 QUIC 协议；
/// 且 QUIC 只在 QUIC 模式会话下存在。加端点打不到目标，还得背跨版本回退。
library;

import '../../sftp/sftp_entry.dart';

/// 列一层目录。形状对齐 `mention.dart` 的 `RemoteDirLister`，签名一致以便
/// 宿主把同一个闭包同时喂给两边。
typedef DirLister = Future<List<SftpEntry>> Function(
  String dir, {
  String? serverId,
});

/// 索引的硬上限。每一项都对应一个「不设它就会怎样」。
class FileIndexConfig {
  /// 从根往下最多展开几层。根自身算第 0 层。
  ///
  /// 4 覆盖绝大多数「`@` 进去找文件」的场景（`/etc/nginx/conf.d` 是 3 层）。
  /// pi-web 用 8，但它那是本地 `readdirSync` 一次遍历；我们每层都是一条网络
  /// 请求，单位成本差三个数量级。
  final int maxDepth;

  /// 写入索引的**条目**总数上限（不是目录数）。到顶就停止扩展队列。
  final int maxEntries;

  /// 同时最多几个在途 `listDir`。SFTP 是单连接多路复用，并发太高会排队还
  /// 打乱顺序；8 是「比串行快一个数量级、又不淹没连接」的折中。
  final int concurrency;

  const FileIndexConfig({
    this.maxDepth = 4,
    this.maxEntries = 2000,
    this.concurrency = 8,
  });
}

/// 后台递归列目录，结果**副作用式**写进 [sink]。
///
/// 不返回索引，因为索引不是这里造出来的 —— 调用方把 `_cache` 直接传进来，
/// 逐层加载和索引写的是同一张表。两份结构会出现「同一目录两份数据、谁新谁旧」
/// 的问题，而增量补齐必然让两份不一致。一张表自动合并：谁先到谁赢，后来的
/// 覆盖（远端文件会变，旧的本就该被覆盖）。
///
/// ## 参数
///
/// [root] 必须是绝对路径。调用方负责把 `~` / `.` / 跨机冒号形态解析掉 —— 本
/// 文件不做路径解析，那是 `mention.dart` + 宿主 resolver 的活。
///
/// [sink] 是 `<绝对目录路径, 该层条目>`。形状与调用方的逐层缓存**完全一样**
/// 是刻意的：索引命中时走的正是缓存那条查询。
///
/// [isCancelled] 是**回调而不是 bool**：递归每写完一层问一次，调用方只需让一个
/// 计数器变一下，不需要把取消信号透传进来。与 `MentionField._loadDir` 里
/// `seq != _reqSeq` 同源。
///
/// [onDirReady] 每写完一层回调一次（带该目录），宿主据此刷新候选 —— 索引边建
/// 边可用，用户能看到候选逐层冒出来，而不是先转一个 3 秒的圈。
///
/// ## 不做的事
///
/// - **不跟随软链递归**：`isDir` 对「软链指向目录」也为真，跟着走会撞上
///   `a → b → a` 的环。与 `SftpOps.stat` 文档里那条「递归遍历必须传
///   followLink: false」同一个理由。
/// - **不因单层失败而整体失败**：一层 `listdir` 抛异常（permission denied /
///   目录被删）只丢那一层，其余照常。索引是加速层，不完整 ≠ 失败。
/// - **不读 `.gitignore`**：SFTP 拿不到 git 信息。代价是 `node_modules` 这类
///   噪声会被扫进来，靠 [FileIndexConfig.maxEntries] 挤掉。
Future<void> buildFileIndex({
  required String root,
  String? serverId,
  required DirLister listDir,
  required Map<String, List<SftpEntry>> sink,
  required bool Function() isCancelled,
  required void Function(String dir) onDirReady,
  FileIndexConfig config = const FileIndexConfig(),
}) async {
  // 队列里带 depth，因为展开与否看的是「离根几层」而不是当前队首是谁。
  final queue = <({String dir, int depth})>[(dir: root, depth: 0)];
  var entriesWritten = 0;

  while (queue.isNotEmpty && !isCancelled()) {
    // 按批取：一次拿 concurrency 个并发发出去，等这批回来再取下一批。这是
    // 「有界并发」而不是「无限并发池」—— 后者在深目录下会瞬间发起上千请求
    // 把 SFTP 连接打爆。
    //
    // 预算在**入批前**检查：一个目录的 `listdir` 是原子的，没法只取它的一
    // 半，所以超支的单位是「一层」而不是「一条」。检查放在这里比放在写
    // sink 前更早一步，少一次必被丢弃的往返。
    final batch = <({String dir, int depth})>[];
    while (batch.length < config.concurrency && queue.isNotEmpty) {
      if (entriesWritten >= config.maxEntries) {
        queue.clear();
        break;
      }
      batch.add(queue.removeAt(0));
    }
    if (batch.isEmpty) break;

    final results = await Future.wait(
      batch.map((item) async {
        // 已经有这一层了？不重列 —— 逐层加载刚把它写进同一张表，再问一次是
        // 纯浪费（移动网络下就是一次 100–800ms 的白花）。但**仍然要展开它
        // 的子目录**，否则索引到这一层就断了。
        final existing = sink[item.dir];
        if (existing != null) return (item: item, entries: existing);
        try {
          final entries = await listDir(item.dir, serverId: serverId);
          return (item: item, entries: entries);
        } catch (_) {
          // 单层失败：丢这一层。不 rethrow —— 一个 permission denied 不该让
          // 用户丢掉整个索引。
          return (item: item, entries: null);
        }
      }),
    );

    for (final r in results) {
      if (isCancelled()) return;
      final entries = r.entries;
      if (entries == null) continue;

      // 已经是缓存里的那份就不重写、不重计 —— 否则预算被「已有」的条目消耗
      // 掉，索引会比实际提前停。
      //
      // 判据必须是「插入**之前**键在不在」：`putIfAbsent` 在插入新值时返回的
      // 就是刚插进去的那个对象，拿 `identical(返回值, entries)` 当判据恒为真，
      // 等于没判。
      final alreadyHad = sink.containsKey(r.item.dir);
      final kids = sink.putIfAbsent(r.item.dir, () => entries);
      if (!alreadyHad) {
        entriesWritten += entries.length;
        onDirReady(r.item.dir);
      }

      if (r.item.depth >= config.maxDepth) continue;
      if (entriesWritten >= config.maxEntries) continue;

      for (final e in kids) {
        // `e.isDir` 已经把「软链指向目录」算进去了（SftpEntry.fromSftpName
        // 的 isDir 判定），但递归不能跟着软链走 —— 会撞环。
        if (!e.isDir || e.isSymlink) continue;
        queue.add((dir: e.path, depth: r.item.depth + 1));
      }
    }
  }
}
