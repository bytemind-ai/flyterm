// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../util/dlog.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/public_downloads.dart';
import 'sftp_service.dart' show SftpOps;

/// 传输被用户取消。
class TransferCancelledException implements Exception {
  /// 已传字节数 —— 回给模型时告诉它「续传可以从这里接」。
  final int bytesDone;
  const TransferCancelledException(this.bytesDone);
  @override
  String toString() => 'Transfer cancelled after $bytesDone bytes';
}

/// 连续一段时间没有任何字节推进。
///
/// 与超时分开命名是刻意的：超时的语义是「太久了」，而传一个 500 MB 的文件
/// 花十分钟一点问题都没有。真正的死亡判据是**不再推进**。
class TransferStalledException implements Exception {
  final int bytesDone;
  const TransferStalledException(this.bytesDone);
  @override
  String toString() => 'Transfer stalled at $bytesDone bytes';
}

/// 一次传输的进度快照。
@immutable
class TransferProgress {
  final int bytesDone;

  /// 0 = 未知（stat 失败时的兜底）。UI 据此显示不确定进度条。
  final int totalBytes;

  const TransferProgress({required this.bytesDone, required this.totalBytes});

  double? get fraction =>
      totalBytes > 0 ? (bytesDone / totalBytes).clamp(0.0, 1.0) : null;
}

/// 取消令牌。**一次传输一个**，不是全局标志。
///
/// `SFTPService` 那个 `cancelTransfer()` 是单例字段，agent 与用户同时传时
/// 一个取消会掐掉两个。这里每个 task 自己持有一个。
class TransferCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// 一次文件传输的执行体。
///
/// **无 `ChangeNotifier`，无 UI 状态。** 进度通过 [onProgress] 推出去，调用方
/// 决定拿它做什么（`SFTPService` 喂给自己的 notifier 字段，agent 喂给
/// `TransferEvent`）。这是 agent 与浏览器能同时传输而互不干扰的原因。
class SftpTransferTask {
  final SftpOps ops;
  final TransferCancelToken cancelToken;
  final void Function(TransferProgress)? onProgress;

  /// 多久没有字节推进就判死。
  final Duration stallTimeout;

  /// 看门狗的检查间隔。做成参数只为测试能拨快。
  final Duration stallCheckInterval;

  SftpTransferTask({
    required this.ops,
    TransferCancelToken? cancelToken,
    this.onProgress,
    this.stallTimeout = const Duration(seconds: 30),
    this.stallCheckInterval = const Duration(seconds: 5),
  }) : cancelToken = cancelToken ?? TransferCancelToken();

  /// 下载 [remotePath] 到 [destDir]，支持从 `.part` 续传。
  ///
  /// 返回落盘的本地绝对路径。抛 [TransferCancelledException] /
  /// [TransferStalledException]，其余异常原样上抛。
  Future<String> download({
    required String remotePath,
    required Directory destDir,
    required int totalBytes,
    bool publishToPublicStore = false,
  }) async {
    final filename = remotePath.split('/').last;
    final savePath = '${destDir.path}/$filename';
    final partFile = File('$savePath.flyterm.part');

    var resumeOffset = 0;
    if (await partFile.exists()) {
      resumeOffset = await partFile.length();
      if (totalBytes > 0 && resumeOffset >= totalBytes) {
        // 上次其实传完了，只是没来得及改名。
        await partFile.rename(savePath);
        await _maybePublish(savePath, filename, publishToPublicStore);
        return savePath;
      }
    }

    // 无条件推一次初始进度，**包括全新下载的 0**。
    //
    // 续传时它让 UI 立刻显示已有进度，不必等第一个分片回来。全新下载时它让
    // 进度条立刻出现在 0% —— 这条不能省：`SFTPService` 的薄壳只靠
    // `onProgress` 去设 `transferState`，少了这次 emit，从用户点下载到第一个
    // 字节到达之间 `transferState` 还是 null，UI 上完全没有反馈。大文件在慢
    // 网络上这段空白能有几秒，用户会以为没点上。
    _emit(resumeOffset, totalBytes);

    final sink = partFile.openWrite(
      mode: resumeOffset > 0 ? FileMode.append : FileMode.write,
    );
    try {
      await _guarded(
        startBytes: resumeOffset,
        body: () => ops.downloadFromOffset(
          remotePath,
          sink,
          offset: resumeOffset,
          onProgress: (bytesRead) {
            _bytesDone = bytesRead;
            _emit(bytesRead, totalBytes);
          },
        ),
      );
    } finally {
      // 先 close 再改名 —— 未 flush 的尾部字节否则会丢。
      await sink.close();
    }

    await partFile.rename(savePath);
    await _maybePublish(savePath, filename, publishToPublicStore);
    return savePath;
  }

  /// 把本地 [localPath] 上传到远端 [remotePath]。
  ///
  /// 不做续传：SFTP 的追加写在服务端实现上差异很大，而手机上传的文件通常
  /// 不大。断了就重传整份，比一个各家行为不一致的续传更可预期。
  Future<void> upload({
    required String localPath,
    required String remotePath,
  }) async {
    final file = File(localPath);
    final totalBytes = await file.length();
    _emit(0, totalBytes);

    await _guarded(
      startBytes: 0,
      body: () => ops.upload(
        remotePath,
        file.openRead(),
        totalBytes,
        (bytesWritten) {
          _bytesDone = bytesWritten;
          _emit(bytesWritten, totalBytes);
        },
      ),
    );
  }

  int _bytesDone = 0;

  void _emit(int done, int total) {
    onProgress?.call(TransferProgress(bytesDone: done, totalBytes: total));
  }

  /// 跑 [body]，同时挂两道守卫：取消轮询与无进度看门狗。
  ///
  /// 看门狗用 `Timer.periodic` 比对字节数而不是记 `DateTime.now()` 的差值：
  /// 远端完全不吐数据时 `onProgress` 根本不会被调用，把判定写在回调里等于
  /// 永远不触发。同时只依赖 Timer 让 `FakeAsync` 能完整控制它。
  Future<void> _guarded({
    required int startBytes,
    required Future<void> Function() body,
  }) async {
    _bytesDone = startBytes;

    // 传之前就已经取消 —— 不必等第一个 tick。
    if (cancelToken.isCancelled) {
      throw TransferCancelledException(startBytes);
    }

    var lastSeen = startBytes;
    final maxIdleTicks =
        (stallTimeout.inMilliseconds / stallCheckInterval.inMilliseconds)
            .ceil()
            .clamp(1, 1 << 20);
    var idleTicks = 0;

    final aborted = Completer<void>();
    final watchdog = Timer.periodic(stallCheckInterval, (t) {
      if (cancelToken.isCancelled) {
        t.cancel();
        if (!aborted.isCompleted) {
          aborted.completeError(TransferCancelledException(_bytesDone));
        }
        return;
      }
      if (_bytesDone != lastSeen) {
        lastSeen = _bytesDone;
        idleTicks = 0;
        return;
      }
      if (++idleTicks >= maxIdleTicks) {
        t.cancel();
        if (!aborted.isCompleted) {
          aborted.completeError(TransferStalledException(_bytesDone));
        }
      }
    });

    try {
      await Future.any([body(), aborted.future]);
      // body 正常返回但取消恰好在最后一刻到达 —— 按取消处理，调用方不该
      // 把它当成功（它会去改名 .part）。
      if (cancelToken.isCancelled) {
        throw TransferCancelledException(_bytesDone);
      }
    } finally {
      watchdog.cancel();
    }
  }

  /// 仅供测试：直接驱动守卫层，绕开真实的文件 IO。
  @visibleForTesting
  Future<void> guardedForTest({
    required int startBytes,
    required Future<void> Function() body,
  }) =>
      _guarded(startBytes: startBytes, body: body);

  /// 尽力而为：把已落盘的私有文件复制进系统可见的 Downloads 集合。
  ///
  /// 失败不影响传输结果 —— 文件已经在 [savePath]，调用方照常能打开它。
  Future<void> _maybePublish(
      String savePath, String filename, bool enabled) async {
    if (!enabled) return;
    try {
      final res = await PublicDownloads.publish(
        source: File(savePath),
        fileName: filename,
        mimeType: guessMimeType(filename),
      );
      publishedPublicPath = res?.publicPath;
    } catch (e) {
      dlog('transfer', 'publish to public Downloads failed: $e');
    }
  }

  /// 发布到系统 Downloads 集合后的公共路径。null = 没发布，或发布失败。
  ///
  /// 做成字段而不是让 [download] 返回一个二元组：现有调用方拿的是
  /// `String savePath`，改返回类型会波及 agent 那条路径（它压根不关心公共
  /// 路径）。一次传输一个 task 实例，字段不会串。
  ///
  /// **这个字段不能省。** `SftpInlineView._downloadFile` 靠它决定 snackbar
  /// 说「已存到系统 Downloads 的 X」还是只说文件名；抽走传输逻辑时漏掉它，
  /// 浏览器的下载提示会静默退化成后者，而测试覆盖不到这条。
  String? publishedPublicPath;
}

/// 按扩展名猜 MIME。从 `SFTPService._guessMimeType` 平移出来 —— 上传/下载
/// 两条路径都要用，留在那个类里 agent 侧拿不到。
String guessMimeType(String filename) {
  final dot = filename.lastIndexOf('.');
  final ext = dot >= 0 ? filename.substring(dot + 1).toLowerCase() : '';
  switch (ext) {
    case 'txt':
    case 'log':
    case 'md':
      return 'text/plain';
    case 'json':
      return 'application/json';
    case 'pdf':
      return 'application/pdf';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'zip':
      return 'application/zip';
    case 'gz':
      return 'application/gzip';
    default:
      return 'application/octet-stream';
  }
}
