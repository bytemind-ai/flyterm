// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../util/dlog.dart';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../data/models/server.dart';
import '../ssh/dead_ssh_clients.dart';
import '../ssh/jump_host_resolver.dart';
import '../ssh/ssh_connection.dart';
import 'sftp_channel_pool.dart';
import 'sftp_entry.dart';
import 'sftp_name_sort.dart';
import 'rate_meter.dart';
import 'sftp_read_result.dart';
import 'sftp_transfer_task.dart';
import 'sftp_upload_plan.dart';

/// Thrown internally to abort an in-progress transfer on user request.
class _CancelException implements Exception {
  const _CancelException();
}

class TransferState {
  final String filename;

  /// 0.0–1.0 的整体进度。
  ///
  /// **null 表示「暂不可知」**：扫描阶段，或文件总大小未知（stat 失败）。
  /// 曾经这里是必填 `double` + 「0.5 表示不确定」的约定 —— 那是魔数，调用方
  /// 每处都得记得判 0.5，漏一处就画出半满的假进度条。
  final double? fraction;
  final bool isSending;

  /// True while scanning the remote directory tree (phase 1 of folder download).
  final bool isScanning;

  /// Files fully downloaded so far (folder download phase 2).
  /// Also used as "files discovered" during scan phase.
  final int filesCompleted;

  /// Total files to download; null during scan and for single-file transfers.
  final int? filesTotal;

  /// Total bytes across all files; 0 during scan and for single-file transfers.
  final int totalBytes;

  /// Bytes transferred so far; 0 during scan and for single-file transfers.
  final int bytesTransferred;

  /// 当前速率（字节/秒）。null = 样本不足，UI 显示「—」而不是 0。
  final double? bytesPerSecond;

  /// 预计剩余时间。null = 总大小未知或速率不可用。
  final Duration? eta;

  const TransferState({
    required this.filename,
    required this.fraction,
    required this.isSending,
    this.isScanning = false,
    this.filesCompleted = 0,
    this.filesTotal,
    this.totalBytes = 0,
    this.bytesTransferred = 0,
    this.bytesPerSecond,
    this.eta,
  });

  /// 进度条的值。null 时 UI 用不确定态（LinearProgressIndicator 不传 value）。
  double? get progressValue => fraction;
}

/// Testable abstraction over SftpClient operations.
abstract class SftpOps {
  Future<List<SftpName>> listdir(String path);
  Future<int> download(
    String path,
    StreamSink<List<int>> sink, {
    void Function(int bytesRead)? onProgress,
  });

  /// Like [download] but starts reading from [offset] bytes into the remote file.
  /// [onProgress] receives cumulative bytes transferred including [offset].
  Future<void> downloadFromOffset(
    String path,
    StreamSink<List<int>> sink, {
    int offset = 0,
    void Function(int bytesRead)? onProgress,
  });
  Future<Uint8List> readBytes(String path, {int? maxBytes});
  Future<void> writeBytes(String path, Uint8List data);
  Future<void> upload(
    String remotePath,
    Stream<List<int>> data,
    int totalBytes,
    void Function(int bytes)? onProgress,
  );
  Future<void> remove(String path);
  Future<void> rmdir(String path);
  Future<void> mkdir(String path);
  Future<void> rename(String oldPath, String newPath);

  /// Creates an empty file at [path] (equivalent to `touch`).
  Future<void> createFile(String path);

  /// Sets the permission bits of [path] to [permissions] (lower 12 bits).
  Future<void> setPermissions(String path, int permissions);

  /// Resolves [path] to an absolute path via SFTP realpath.
  Future<String> absolutePath(String path);

  /// 单个路径的属性。`downloadFile` 不能再靠翻父目录列表拿 size ——
  /// agent 下载的路径通常不在浏览器当前列出的目录里。
  ///
  /// [followLink] 为 true（默认）时**跟随软链**，返回目标的属性 —— 这是判断
  /// 「软链指向目录还是文件」的唯一手段，因为 `listdir` 返回的
  /// `attr.isDirectory` 对软链恒为 false（软链的 mode.type 是 symbolicLink）。
  ///
  /// 递归遍历（删除 / 扫描下载）必须传 **false**：跟随会让你顺着软链走进
  /// 目标目录，轻则删掉目标内容，重则在 `a → b → a` 的环上无限递归。
  Future<SftpFileAttrs> stat(String path, {bool followLink = true});

  /// 软链的目标路径。对非软链调用会失败。
  ///
  /// 只用于展示「→ 目标」，**不用于判断类型** —— 判断类型请用
  /// `stat(followLink: true)`。
  Future<String> readlink(String path);

  /// 递归创建目录（等价 `mkdir -p`）。已存在的层级跳过。
  Future<void> mkdirRecursive(String path);
}

class _LiveSftpOps implements SftpOps {
  final SftpClient _client;
  _LiveSftpOps(this._client);

  @override
  Future<List<SftpName>> listdir(String path) => _client.listdir(path);

  @override
  Future<int> download(
    String path,
    StreamSink<List<int>> sink, {
    void Function(int bytesRead)? onProgress,
  }) => _client.download(path, sink, onProgress: onProgress);

  @override
  Future<void> downloadFromOffset(
    String path,
    StreamSink<List<int>> sink, {
    int offset = 0,
    void Function(int bytesRead)? onProgress,
  }) async {
    final file = await _client.open(path, mode: SftpFileOpenMode.read);
    try {
      int totalRead = offset;
      await for (final chunk in file.read(offset: offset)) {
        sink.add(chunk);
        totalRead += chunk.length;
        onProgress?.call(totalRead);
      }
    } finally {
      await file.close();
    }
  }

  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) async {
    final file = await _client.open(path, mode: SftpFileOpenMode.read);
    try {
      return await file.readBytes(length: maxBytes);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> writeBytes(String path, Uint8List data) async {
    final file = await _client.open(
      path,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(data);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> upload(
    String remotePath,
    Stream<List<int>> data,
    int totalBytes,
    void Function(int bytes)? onProgress,
  ) async {
    final file = await _client.open(
      remotePath,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.write(
        data.map((chunk) => Uint8List.fromList(chunk)),
        onProgress: onProgress,
      );
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> remove(String path) => _client.remove(path);

  @override
  Future<void> rmdir(String path) => _client.rmdir(path);

  @override
  Future<void> mkdir(String path) => _client.mkdir(path);

  @override
  Future<void> rename(String oldPath, String newPath) =>
      _client.rename(oldPath, newPath);

  @override
  Future<void> createFile(String path) async {
    final file = await _client.open(
      path,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    await file.close();
  }

  @override
  Future<void> setPermissions(String path, int permissions) => _client.setStat(
    path,
    SftpFileAttrs(mode: SftpFileMode.value(permissions)),
  );

  @override
  Future<String> absolutePath(String path) => _client.absolute(path);

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) =>
      _client.stat(path, followLink: followLink);

  @override
  Future<String> readlink(String path) => _client.readlink(path);

  @override
  Future<void> mkdirRecursive(String path) async {
    // 逐段建。**不能靠 mkdir 抛异常再吞** —— 那分不清「已存在」和「权限
    // 不足」，后者会被当成成功，随后的写入才失败在一个无关的位置。
    // 所以已存在与否用 stat(followLink: false) 显式探。
    final segments = path.split('/').where((s) => s.isNotEmpty);
    var cur = path.startsWith('/') ? '' : '.';
    for (final seg in segments) {
      cur = '$cur/$seg';
      try {
        await _client.stat(cur, followLink: false);
        continue; // 已存在
      } catch (_) {
        // 不存在（或权限不可见）→ 尝试创建。创建失败会原样抛出，交给上层分类。
      }
      await _client.mkdir(cur);
    }
  }
}

/// 元数据操作的超时。
///
/// 覆盖的是「channel 已经开着，但协议请求有去无回」那一类半死连接——和
/// `_getOps()`/`_probeAliveOnEmpty()` 处理的「开不出新 channel」是两种不同
/// 的死法：后者在建连/探活那一步就能发现，前者只有在真的发请求时才会卡住，
/// 而且没有任何信号——Future 永远不 complete，UI 上连"重连"按钮都出不来。
///
/// 15 秒不是「网络慢」的阈值，是「不可能再回来了」的底线：正常的 sftp
/// mkdir/stat/rename/remove 这类纯元数据往返，哪怕移动网络再抖，几秒内必有
/// 响应；15 秒还没回应，基本可以断定对端已经不会再回复了。
///
/// `download`/`upload` 不在这个超时的覆盖范围内——它们的「卡住」判定归
/// `sftp_transfer_task.dart` 里专门的 stall watchdog 管（按「多久没有新字节
/// 到达」判断，而不是按「调用总耗时」，一个大文件传几分钟是正常的，不能套
/// 同一个 15 秒）。
const Duration _sftpMetaOpTimeout = Duration(seconds: 15);

/// 包一层超时，应用在 [_getOps] 的统一出口上——这样无论底层是真实的
/// [_LiveSftpOps] 还是测试用的 fake [SftpOps]，纯元数据方法都会在卡死时
/// 超时报错，而不是把调用方永远挂起。
///
/// `download`/`downloadFromOffset`/`readBytes`/`writeBytes`/`upload` 刻意不
/// 包超时，原因见 [_sftpMetaOpTimeout] 的文档。
class _TimeoutGuardedOps implements SftpOps {
  final SftpOps _inner;
  const _TimeoutGuardedOps(this._inner);

  @override
  Future<List<SftpName>> listdir(String path) =>
      _inner.listdir(path).timeout(_sftpMetaOpTimeout);

  @override
  Future<int> download(
    String path,
    StreamSink<List<int>> sink, {
    void Function(int bytesRead)? onProgress,
  }) => _inner.download(path, sink, onProgress: onProgress);

  @override
  Future<void> downloadFromOffset(
    String path,
    StreamSink<List<int>> sink, {
    int offset = 0,
    void Function(int bytesRead)? onProgress,
  }) => _inner.downloadFromOffset(path, sink, offset: offset, onProgress: onProgress);

  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) =>
      _inner.readBytes(path, maxBytes: maxBytes);

  @override
  Future<void> writeBytes(String path, Uint8List data) =>
      _inner.writeBytes(path, data);

  @override
  Future<void> upload(
    String remotePath,
    Stream<List<int>> data,
    int totalBytes,
    void Function(int bytes)? onProgress,
  ) => _inner.upload(remotePath, data, totalBytes, onProgress);

  @override
  Future<void> remove(String path) =>
      _inner.remove(path).timeout(_sftpMetaOpTimeout);

  @override
  Future<void> rmdir(String path) =>
      _inner.rmdir(path).timeout(_sftpMetaOpTimeout);

  @override
  Future<void> mkdir(String path) =>
      _inner.mkdir(path).timeout(_sftpMetaOpTimeout);

  @override
  Future<void> rename(String oldPath, String newPath) =>
      _inner.rename(oldPath, newPath).timeout(_sftpMetaOpTimeout);

  @override
  Future<void> createFile(String path) =>
      _inner.createFile(path).timeout(_sftpMetaOpTimeout);

  @override
  Future<void> setPermissions(String path, int permissions) =>
      _inner.setPermissions(path, permissions).timeout(_sftpMetaOpTimeout);

  @override
  Future<String> absolutePath(String path) =>
      _inner.absolutePath(path).timeout(_sftpMetaOpTimeout);

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) =>
      _inner.stat(path, followLink: followLink).timeout(_sftpMetaOpTimeout);

  @override
  Future<String> readlink(String path) =>
      _inner.readlink(path).timeout(_sftpMetaOpTimeout);

  @override
  Future<void> mkdirRecursive(String path) =>
      _inner.mkdirRecursive(path).timeout(_sftpMetaOpTimeout);
}

/// 从一条已认证的 SSH client 直接建 SFTP ops。
///
/// 与 [SFTPService.fromClient] 的区别是它不带 service 那一层状态机（当前
/// 目录、entries、error / isDisconnected），调用方自己管。agent 的
/// `sftpOpsProvider`、AI 面板输入框的 `@file` 补全、计划任务的
/// `TaskResultCollector` 都走这条。
///
/// **同一 client 复用同一条 SFTP 通道**（见 [SftpChannelPool]）。这是本函数
/// 最重要的一条契约：dartssh2 的 `client.sftp()` 每次都开**新** session
/// channel，而 sshd 的 `MaxSessions` 默认只有 10。此前这里每次调用都裸开一条，
/// `@file` 的并发 8 个 `listdir` 一批就能吃满名额，之后每次 open 都收到
/// `SSHChannelOpenError` —— 用户看到「SSH 连接错误」，其实连接是活的。
/// 池化之后：一条 client 至多一条通道，无论上面叠了多少个 `@` 补全与工具
/// 调用。
///
/// **两道防护和 service 那条路对齐**，不要再分叉：
///   1. `client.sftp()` 的 10 秒超时 —— 半死连接下开 channel 会一直没响应，
///      不加的话 agent 的 download_file 会永久卡死（它的 20 秒命令超时管不到
///      SFTP 通道），`@file` 浮层会一直转圈
///   2. [_TimeoutGuardedOps] 包装 —— 覆盖「channel 已开着但协议请求有去无回」
///      那类死法，理由见该类文档
///
/// 开通道撞上「服务端拒绝开新 channel」时不把缓存留成死条目：那类失败多半是
/// 名额紧张，下次调用重开比一直复用同一个 reject 的 Future 更有机会成功。
Future<SftpOps> sftpOpsFromClient(SSHClient client) =>
    SftpChannelPool.shared.obtain<SftpOps>(client, () async {
      try {
        final inner = _LiveSftpOps(await client.sftp().timeout(
          const Duration(seconds: 10),
          onTimeout: () =>
              throw TimeoutException('SFTP 连接超时，SSH 连接可能已断开'),
        ));
        // 任何一次操作撞上「开不出 channel」都踢掉本条缓存：半死连接
        // （socket 还开着、服务端已拒新 channel）下，留着它只会让
        // `@file` 每次都失败且永不自愈。
        return EvictOnChannelFailureOps(
          _TimeoutGuardedOps(inner),
          onFailure: () => SftpChannelPool.shared.evict(client),
        );
      } catch (e) {
        // 开通道本身就是这里失败的唯一来源。`obtain` 会在 Future 失败时自动
        // 清掉条目，下次调用重开 —— 但把「服务端拒绝开 channel」这一类额外
        // 记一笔，便于诊断 MaxSessions 命中的情形。
        if (isSshChannelSetupFailure(e)) {
          dlog('SFTP', 'sftpOpsFromClient: 开 SFTP 通道被拒（MaxSessions?）: $e');
        }
        rethrow;
      }
    });

/// 把「开不出 channel」这类失败变成「踢掉当前 client 的 SFTP 缓存」。
///
/// 只拦元数据类操作（`listdir` / `stat` / `absolutePath` …）—— 那是 `@file`
/// 与 agent 浏览走的路径；传输类（`download` / `upload`）的超时与中断语义
/// 不同，不在这里插一脚。
@visibleForTesting
class EvictOnChannelFailureOps implements SftpOps {
  final SftpOps _inner;
  final void Function() onFailure;
  const EvictOnChannelFailureOps(this._inner, {required this.onFailure});

  Future<T> _guard<T>(Future<T> Function() op) async {
    try {
      return await op();
    } catch (e) {
      if (isSshChannelSetupFailure(e)) onFailure();
      rethrow;
    }
  }

  @override
  Future<List<SftpName>> listdir(String path) =>
      _guard(() => _inner.listdir(path));

  @override
  Future<String> absolutePath(String path) =>
      _guard(() => _inner.absolutePath(path));

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) =>
      _guard(() => _inner.stat(path, followLink: followLink));

  @override
  Future<String> readlink(String path) => _guard(() => _inner.readlink(path));

  @override
  Future<void> mkdirRecursive(String path) =>
      _guard(() => _inner.mkdirRecursive(path));

  // 传输类直通，不加 guard。
  @override
  Future<int> download(
    String path,
    StreamSink<List<int>> sink, {
    void Function(int bytesRead)? onProgress,
  }) => _inner.download(path, sink, onProgress: onProgress);

  @override
  Future<void> downloadFromOffset(
    String path,
    StreamSink<List<int>> sink, {
    int offset = 0,
    void Function(int bytesRead)? onProgress,
  }) => _inner.downloadFromOffset(path, sink, offset: offset, onProgress: onProgress);

  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) =>
      _inner.readBytes(path, maxBytes: maxBytes);

  @override
  Future<void> writeBytes(String path, Uint8List data) =>
      _inner.writeBytes(path, data);

  @override
  Future<void> upload(
    String remotePath,
    Stream<List<int>> data,
    int totalBytes,
    void Function(int bytes)? onProgress,
  ) => _inner.upload(remotePath, data, totalBytes, onProgress);

  @override
  Future<void> remove(String path) => _guard(() => _inner.remove(path));

  @override
  Future<void> rmdir(String path) => _guard(() => _inner.rmdir(path));

  @override
  Future<void> mkdir(String path) => _guard(() => _inner.mkdir(path));

  @override
  Future<void> rename(String oldPath, String newPath) =>
      _guard(() => _inner.rename(oldPath, newPath));

  @override
  Future<void> createFile(String path) => _guard(() => _inner.createFile(path));

  @override
  Future<void> setPermissions(String path, int permissions) =>
      _guard(() => _inner.setPermissions(path, permissions));
}

/// 抛出于 SFTPService._getOps()：SSH 连接已断开或 svc 已 dispose。
/// toString() 直接返回原始消息（不带 "Exception: " 前缀），方便 UI 直接
/// 展示。sftp_inline_view 在 `_svc.error != null && entries.isEmpty` 时
/// 显示"重新连接"按钮（onReconnectRequested → invalidateSftpSvc + _openSftp）。
class SftpDisconnectedException implements Exception {
  final String message;
  const SftpDisconnectedException(this.message);
  @override
  String toString() => message;
}

class SFTPService extends ChangeNotifier {
  final Future<SftpOps> Function() _opsProvider;
  final Future<Directory> Function()? _downloadDirProvider;

  /// When this returns true, a successfully downloaded single file is also
  /// published to the user-visible public Downloads collection
  /// (Download/FlyTerm). Evaluated per download so it tracks the live setting.
  final bool Function()? _publishToPublicStore;

  /// Public location of the most recent single-file download, if it was
  /// published to public Downloads (else null). Read by the UI to tailor the
  /// success message. Reset at the start of each [downloadFile].
  String? lastPublishedPublicPath;

  final SSHClient? _ownedClient;
  final SSHClient? _ownedJumpClient;

  /// 复用的那条连接是否已经不可用。null = 自有连接，没有复用可言。
  ///
  /// 取代了早前直接持有 `SSHClient` 判 `isClosed` 的写法（QUIC tab 一段时间
  /// 后默默关闭 SSH、idle timeout / ClientAlive 超时后 QUIC PTY 仍活导致
  /// `_opsFuture` 缓存着 dead-channel 的 `SftpClient`，`listDirectory` 返回
  /// 空 list 或抛异常，用户感知"空目录错误"的那个历史问题仍然是这个字段要
  /// 解决的，只是判据现在归一到 [isSshClientDead]）。
  ///
  /// 注入而不是直接拿 `SSHClient` 判，有两个理由：
  ///   1. 可测 —— 测试里造不出真的 `SSHClient`
  ///   2. 判据归一 —— 生产注入的是 `isSshClientDead`，与 agent 侧读的是同一个
  ///      登记处，不会再出现「一边已拉黑、另一边照用」
  final bool Function()? _isReusedClientDead;

  /// 列目录结果为空时，探一次连接是否还活着。null = 不探（自有连接路径）。
  final Future<void> Function()? _aliveProbe;

  /// 撞上「开不出 channel」的那类半死连接时，把它记进跨组件登记处。
  /// null = 自有连接，没有复用对象可拉黑。
  final void Function()? _markReusedDead;

  Future<SftpOps>? _opsFuture;
  bool _disposed = false;
  bool _cancelRequested = false;

  /// 速率/ETA 采样器。每次传输开始时 [RateMeter.reset]。
  final RateMeter _rateMeter = RateMeter();

  /// 当前那次由本 service 发起的传输的取消令牌。null = 没有在传。
  TransferCancelToken? _activeToken;

  /// True once [dispose] has been called. Callers can check this before
  /// attempting SFTP operations so they can offer a reconnect flow rather
  /// than crashing with "notifyListeners called after dispose".
  bool get isDisposed => _disposed;

  String currentPath = '/';
  List<SftpEntry> entries = [];
  TransferState? transferState;
  bool isLoading = false;
  String? error;

  /// 最近一次失败的原始异常对象。
  ///
  /// [error] 存的是 `e.toString()`，类型信息在那一步就丢了，UI 无从区分
  /// 「连接断了」和「没权限 / 路径不存在」。这里平行保留原始对象（不改变
  /// [error] 的类型，避免动到 12 个消费方含 agent 路径），供 UI 用
  /// `SftpError.classify` 给出可读文案。
  Object? lastError;

  bool _disconnected = false;

  /// 最近一次失败是否属于「底层连接已断开」。
  ///
  /// 与 [error] 分开是因为 error 存的是 `e.toString()`，类型信息在那一步就
  /// 丢了，UI 无从区分「连接断了」和「没权限 / 路径不存在」—— 而这两者的
  /// 正确应对完全不同：前者该重连，后者重连一百次也没用。
  bool get isDisconnected => _disconnected;

  /// 判断异常是否指向连接不可用。
  ///
  /// [SftpDisconnectedException] 来自 `_getOps` 的健康守卫；
  /// [TimeoutException] 来自开 channel 的超时和 [_TimeoutGuardedOps] 的元数据
  /// 超时；[TransferStalledException] 来自传输路径自己的无进度看门狗 ——
  /// 「传输卡住不动」和「连接已断开」对用户是同一件事：都该给重连按钮，而不是
  /// 一条只能看不能操作的文字 error。
  static bool _isDisconnectFailure(Object e) =>
      e is SftpDisconnectedException ||
      e is TimeoutException ||
      e is TransferStalledException;

  /// 记录一次失败。**所有 catch 块都走这里**，不要手写 `error = ...`。
  ///
  /// [error]（String，供既有 12 个消费方，含 agent 路径）与 [lastError]
  /// （原始对象，供 UI 分类成可读文案）必须同步设置 —— 手写两行的话，
  /// 漏一行不会有任何编译错误，只会让某条路径的错误悄悄退化成「未知错误」。
  /// 收进一个方法让这种漏写在结构上不可能发生。
  void _recordError(Object e) {
    error = e.toString();
    _disconnected = _isDisconnectFailure(e);
    lastError = e;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _checkCancel() {
    if (_cancelRequested) {
      _cancelRequested = false;
      throw const _CancelException();
    }
  }

  /// Requests cancellation of the current in-progress transfer.
  void cancelTransfer() {
    _cancelRequested = true; // 老路径（downloadFolder / 递归扫描）还在用
    _activeToken?.cancel();
  }

  SFTPService._({
    required Future<SftpOps> Function() opsProvider,
    Future<Directory> Function()? downloadDirProvider,
    bool Function()? publishToPublicStore,
    SSHClient? ownedClient,
    SSHClient? ownedJumpClient,
    bool Function()? isReusedClientDead,
    Future<void> Function()? aliveProbe,
    void Function()? markReusedDead,
  }) : _opsProvider = opsProvider,
       _downloadDirProvider = downloadDirProvider,
       _publishToPublicStore = publishToPublicStore,
       _ownedClient = ownedClient,
       _ownedJumpClient = ownedJumpClient,
       _isReusedClientDead = isReusedClientDead,
       _aliveProbe = aliveProbe,
       _markReusedDead = markReusedDead;

  /// Creates SFTP service reusing an existing SSH connection from a terminal tab.
  /// A 10 s timeout guards against stale TCP connections that appear open but
  /// are actually dead (common for mosh sessions where SSH is not the active
  /// data path and the underlying TCP may have been silently dropped).
  factory SFTPService.fromClient(
    SSHClient client, {
    Future<Directory> Function()? downloadDirProvider,
    bool Function()? publishToPublicStore,
  }) {
    // 开一条新 channel 探活。**必须**真的开新 channel 才有意义——复用当前
    // 缓存的 ops 再做一次操作走的是同一条死 channel，问它一百遍也还是那个
    // 答案。探完即关：`SftpClient.close()` 是同步的本地清理（结束等待中的
    // request、标记 done），不等待任何网络往返，不会拖慢这条探测路径。
    // 8 秒超时防止半死连接（socket 开着但 server 不响应 channel open）把
    // 探活挂住——比正式 SFTP 连接的 10s 略短，比最初的 5s 宽，给移动网络的
    // 抖动留点余地（5s 在弱网下偶尔会把「还在响应、只是慢」误判成死连接）。
    Future<void> aliveProbe() async {
      final sftp = await client.sftp().timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw TimeoutException('SFTP 探活超时，连接可能已断开'),
      );
      sftp.close();
    }

    final svc = SFTPService._(
      opsProvider:
          () async => _LiveSftpOps(
            await client.sftp().timeout(
              const Duration(seconds: 10),
              onTimeout: () =>
                  throw TimeoutException('SFTP 连接超时，SSH 连接可能已断开'),
            ),
          ),
      downloadDirProvider: downloadDirProvider,
      publishToPublicStore: publishToPublicStore,
      isReusedClientDead: () => isSshClientDead(client),
      aliveProbe: aliveProbe,
      markReusedDead: () => DeadSshClients.mark(client),
    );
    // 监听 SSH client 关闭事件：远端 sshd 因 idle/keepalive timeout 关
    // 连接、或网络断时，client.done future 完成。立即 dispose svc 释放
    // _opsFuture 缓存，让上层下次访问触发"重连"流程（_getOps 抛异常 →
    // sftp_inline_view 显示 reconnect 按钮 → invalidateSftpSvc + _openSftp）。
    // **两条关闭路径都要 dispose。** dartssh2 有两个出口：正常 FIN 走
    // `close()`（done 正常完成），socket 出错走 `closeWithError()`（done 以
    // error 完成，见 ssh_transport.dart:390-396）。早前这里只写了 `.then`
    // 的成功回调，异常关闭时回调根本不执行 —— svc 不被 dispose，_opsFuture
    // 里的死 SftpClient 继续被返回，用户看到的就是「空目录」。而异常关闭恰恰
    // 是网络抖动/切网下最常见的那条路径。
    void handleClosed(String how, [Object? err]) {
      dlog('SFTP', '复用的 SSH client $how → dispose svc'
          '${err != null ? '：${err.runtimeType}: $err' : ''}');
      if (!svc._disposed) svc.dispose();
    }

    unawaited(client.done.then(
      (_) => handleClosed('正常关闭'),
      onError: (Object e) => handleClosed('异常关闭', e),
    ));
    return svc;
  }

  /// Creates SFTP service with its own dedicated SSH connection.
  /// Pass [jump] (resolved via resolveJumpParams) to connect through a bastion.
  static Future<SFTPService> forServer(
    Server server, {
    String? privateKeyPem,
    String? password,
    JumpHostParams? jump,
    Future<Directory> Function()? downloadDirProvider,
    bool Function()? publishToPublicStore,
  }) async {
    SSHClient client;
    SSHClient? jumpClient;

    if (jump != null) {
      final jumpSocket = await SSHSocket.connect(
        jump.host,
        jump.port,
        timeout: const Duration(seconds: 15),
      );
      jumpClient = SSHClient(
        jumpSocket,
        username: jump.username,
        identities:
            jump.privateKeyPem != null
                ? SSHKeyPair.fromPem(jump.privateKeyPem!)
                : [],
        onPasswordRequest: jump.password != null ? () => jump.password! : null,
      );
      await jumpClient.authenticated;
      try {
        final channel = await jumpClient.forwardLocal(server.host, server.port);
        final transport = SshChannelTransport(channel);
        client = SSHClient(
          transport,
          username: server.username,
          identities:
              privateKeyPem != null ? SSHKeyPair.fromPem(privateKeyPem) : [],
          onPasswordRequest: password != null ? () => password : null,
        );
        await client.authenticated;
      } catch (e) {
        jumpClient.close();
        rethrow;
      }
    } else {
      final socket = await SSHSocket.connect(
        server.host,
        server.port,
        timeout: const Duration(seconds: 15),
      );
      client = SSHClient(
        socket,
        username: server.username,
        identities:
            privateKeyPem != null ? SSHKeyPair.fromPem(privateKeyPem) : [],
        onPasswordRequest: password != null ? () => password : null,
      );
      await client.authenticated;
      jumpClient = null;
    }

    Future<SftpOps> openSftpOps() async {
      try {
        return _LiveSftpOps(await client.sftp());
      } catch (_) {
        client.close();
        jumpClient?.close();
        rethrow;
      }
    }

    // Validate the subsystem before returning so callers can show the connect
    // error immediately instead of navigating to an empty browser first. This
    // also closes the SSH clients on SSHChannelOpenError/open failed.
    final initialOps = await openSftpOps();

    return SFTPService._(
      opsProvider: () async => initialOps,
      downloadDirProvider: downloadDirProvider,
      publishToPublicStore: publishToPublicStore,
      ownedClient: client,
      ownedJumpClient: jumpClient,
    );
  }

  @visibleForTesting
  SFTPService.testWith(
    Future<SftpOps> Function() opsProvider, {
    Future<Directory> Function()? downloadDirProvider,
    bool Function()? isReusedClientDead,
    Future<void> Function()? aliveProbe,
    void Function()? markReusedDead,
  }) : _opsProvider = opsProvider,
       _downloadDirProvider = downloadDirProvider,
       _publishToPublicStore = null,
       _ownedClient = null,
       _ownedJumpClient = null,
       _isReusedClientDead = isReusedClientDead,
       _aliveProbe = aliveProbe,
       _markReusedDead = markReusedDead;

  Future<SftpOps> _getOps() {
    // 健康守卫：dispose 之后或底层 SSH 已死 → 立即抛异常，由上层 catch
    // 触发 reconnect UI（sftp_inline_view 检测 _svc.error 显示重连按钮）。
    // 不再返回死缓存让用户看到"空目录"。
    if (_disposed) {
      dlog('SFTP', '_getOps 拒绝：svc 已 dispose');
      throw const SftpDisconnectedException('SFTP 服务已关闭，请重新连接');
    }
    if (_isReusedClientDead?.call() ?? false) {
      dlog('SFTP', '_getOps 拒绝：复用的 SSH 连接已不可用（closed 或被拉黑）');
      _opsFuture = null;
      throw const SftpDisconnectedException('SSH 连接已断开，请重新连接');
    }
    // 统一在这里拦截「开不出 channel」—— 它正是 `_opsProvider()` 建立 SFTP
    // 子系统 channel 的地方（`fromClient` 路径是 `client.sftp()`）。放在这
    // 一处而不是每个调用 `_getOps()` 的方法里各写一遍：任何操作（mkdir、
    // delete、download...）只要撞上这类半死连接，都会在这里统一被标记，
    // 不需要在十几个方法的 catch 块里重复同一行代码。
    _opsFuture ??= _opsProvider()
        .then<SftpOps>((ops) => _TimeoutGuardedOps(ops))
        .catchError((e) {
          _opsFuture = null;
          if (isSshChannelSetupFailure(e)) {
            dlog('SFTP', '_getOps: 撞上 channel 建立失败，拉黑复用连接: $e');
            _markReusedDead?.call();
          }
          throw e;
        });
    return _opsFuture!;
  }

  /// 仅供测试：取底层 ops。生产代码一律走 `_getOps()`。
  @visibleForTesting
  Future<SftpOps> opsForTest() => _getOps();

  /// 结果为空时探活。探不通就拉黑这条连接并抛 [SftpDisconnectedException]。
  ///
  /// 必须**开一条新 channel** 才有意义：用当前这个 ops 再做一次操作走的是
  /// 同一条死 channel，问它一百遍也还是那个答案。
  ///
  /// 探活的结果要分两种完全不同的失败来解读：
  ///   - [TimeoutException]（探不通，完全没响应）→ 真的死了。
  ///   - [isSshChannelSetupFailure]（服务端明确回了拒绝，比如 sshd 的
  ///     `MaxSessions` 命中）→ 它在响应，连接是活的；探活本身要开一条新
  ///     channel，在 channel 名额紧张的会话里这反而是探活自己诱发的拒绝，
  ///     不能把这种「服务端有回应」的失败也判成死连接。
  Future<void> _probeAliveOnEmpty() async {
    final probe = _aliveProbe;
    if (probe == null) return; // 自有连接：建连失败会直接抛，不需要这道探测
    try {
      await probe();
    } on TimeoutException catch (e) {
      // 只有「探不通」才判死。
      dlog('SFTP', '空结果探活超时，判定连接已死: $e');
      _markReusedDead?.call();
      _opsFuture = null;
      throw const SftpDisconnectedException('SSH 连接已断开，请重新连接');
    } catch (e) {
      if (isSshChannelSetupFailure(e)) {
        // 服务端明确拒绝开新 channel —— 它在响应，连接是活的。
        dlog('SFTP', '空结果探活被拒（服务端在响应，连接存活）: $e');
        return;
      }
      dlog('SFTP', '空结果探活失败，判定连接已死: $e');
      _markReusedDead?.call();
      _opsFuture = null;
      throw const SftpDisconnectedException('SSH 连接已断开，请重新连接');
    }
  }

  /// 外部驱动的轻量探活（回前台 / 切网后调用）。
  ///
  /// 与 [_probeAliveOnEmpty] 的分工：后者是「列目录返回空」时的**自愈**，
  /// 挂在 listDirectory 里；这个是**主动检查**，由生命周期/网络事件驱动。
  /// 两者共用同一个判据 —— **必须开一条新 channel**，复用的死 channel
  /// 问一百遍也还是同一个答案。
  ///
  /// **失败不设 [error]。** 它由后台触发，用户没在等这个结果；设了 error 会
  /// 让「切出去看一眼通知再回来」变成一次弹错。真正的错误等用户下一次操作
  /// 时由那条路径自己报。
  Future<bool> probeAlive() async {
    if (_disposed) return false;
    if (_isReusedClientDead?.call() ?? false) {
      _disconnected = true;
      return false;
    }
    final probe = _aliveProbe;
    if (probe == null) {
      // 自有连接：建连失败会直接抛，这里做一次真实往返即可。
      try {
        final ops = await _getOps();
        await ops.stat(currentPath, followLink: false);
        return true;
      } catch (_) {
        _opsFuture = null;
        _disconnected = true;
        return false;
      }
    }
    try {
      await probe();
      return true;
    } on TimeoutException {
      _markReusedDead?.call();
      _opsFuture = null;
      _disconnected = true;
      return false;
    } catch (e) {
      if (isSshChannelSetupFailure(e)) {
        // 服务端明确拒绝开新 channel —— 它在响应，连接是活的（与
        // _probeAliveOnEmpty 同一判据）。
        return true;
      }
      _markReusedDead?.call();
      _opsFuture = null;
      _disconnected = true;
      return false;
    }
  }

  Future<void> ensureConnected() async {
    await _getOps();
  }

  /// 按指定维度排序当前目录内容。UI 用；[entries] 本身保持默认顺序不变。
  List<SftpEntry> sortedEntries({
    required SortKey key,
    required bool ascending,
  }) =>
      sortEntries(entries, key: key, ascending: ascending);

  Future<void> listDirectory(String path, {bool silent = false}) async {
    isLoading = !silent;
    error = null;
    lastError = null;
    _disconnected = false;
    notifyListeners();
    try {
      final ops = await _getOps();
      final names = await ops.listdir(path);
      // 「空」有两种完全相反的含义：真的空目录，或者死 channel 静默返回了空
      // 列表（`87338468` 的排查记录里实测到过这种）。SFTP 协议层不给我们区分
      // 的手段 —— 两种情况下 listdir 都「成功」返回了一个空 list。
      //
      // 判别法：只在结果为空时额外探一次连接。真·空目录很少见，所以这条额外
      // 往返几乎不触发；而一旦探不通，用户得到的是「连接已断开 + 重连按钮」，
      // 而不是一个骗人的空列表。
      if (names.isEmpty) await _probeAliveOnEmpty();
      final filtered =
          names.where((n) => n.filename != '.' && n.filename != '..').toList();

      // 软链要额外一次 stat(followLink: true) 才知道目标是不是目录 ——
      // listdir 给的 attr.isDirectory 对软链恒为 false。
      //
      // **只对软链发起，且并发。** 一个目录里可能有几十上百条软链
      // （/usr/lib64、node_modules/.bin），串行就是几十次往返。
      final linkStates = <String, SftpLinkState>{};
      final linkTargetIsDir = <String, bool>{};
      await Future.wait(
        filtered
            .where((n) => n.attr.isSymbolicLink)
            .map((n) async {
              // 局部变量叫 linkPath，避免与方法的 `path` 参数同名遮蔽。
              final linkPath =
                  path == '/' ? '/${n.filename}' : '$path/${n.filename}';
              try {
                final attrs = await ops.stat(linkPath, followLink: true);
                linkStates[n.filename] = SftpLinkState.ok;
                linkTargetIsDir[n.filename] = attrs.isDirectory;
              } catch (_) {
                // 悬空软链（目标已删）或无权限访问目标。**不能让它冒泡** ——
                // 一条坏链接不该让整页目录列不出来。
                linkStates[n.filename] = SftpLinkState.dangling;
                linkTargetIsDir[n.filename] = false;
              }
            }),
      );

      entries = filtered
          .map(
            (n) => SftpEntry.fromSftpName(
              n,
              path,
              linkState: linkStates[n.filename] ?? SftpLinkState.none,
              linkTargetIsDir: linkTargetIsDir[n.filename] ?? false,
            ),
          )
          .toList();

      // **排序放在软链解析之后**：目录优先必须和「可进入」用同一个判据。
      //
      // 在 SftpName 上排会看 attr.isDirectory，而它对软链恒为 false ——
      // 于是「指向目录的软链」会被归到文件堆里，与它恰好相反的可进入
      // 语义相矛盾（用户看到一个带链接角标的条目排在文件之间）。
      // 用 SftpEntry（此时的 isDir 已含软链目标）排序就一致了。
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.compareTo(b.name);
      });
      currentPath = path;
    } catch (e) {
      _recordError(e);
    } finally {
      isLoading = false;
      _notify();
    }
  }

  /// 重新列出当前目录，**但不进入 loading 态**。
  ///
  /// 与 [listDirectory] 的区别只在这一点：后者把 `isLoading` 置真，UI 会显示
  /// 全屏转圈（替换整个列表）。下拉刷新时那样会闪一下空白 —— 旧内容明明还
  /// 在，没必要先清掉。
  Future<void> refresh() async {
    await listDirectory(currentPath, silent: true);
  }

  /// 远端是否已存在该路径。
  ///
  /// `stat` 抛异常即视为不存在 —— SFTP 没有单独的 exists 调用，而调用方
  /// （附文件的避重名循环）只关心「这个名字能不能用」，不关心失败原因。
  ///
  /// 放在 SFTPService 上而不是让调用方自己拿 [SftpOps]：`_getOps()` 是私有的，
  /// 把它公开等于把整个 ops 接口暴露给 UI 层。
  Future<bool> exists(String path) async {
    try {
      final ops = await _getOps();
      await ops.stat(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 读软链目标。失败返回 null（悬空 / 非软链 / 断线）。
  ///
  /// 失败不设 [error]：它由可见行的懒查触发，一条坏链接不该让整页弹错误。
  Future<String?> readlink(String path) async {
    try {
      final ops = await _getOps();
      return await ops.readlink(path);
    } catch (_) {
      return null;
    }
  }

  /// 上传一个**已知路径**的本地文件到指定远端路径。
  ///
  /// 与 [pickAndUpload] 的分工：那个负责「选文件 + 多文件循环」，这个只负责
  /// 传一个。终端里的附件按钮走这条 —— 它自己已经选好了文件，也自己算好了
  /// 远端路径（含改名与避重名），不需要再走一遍选择器。
  ///
  /// 进度、取消、上传后刷新目录的行为与 SFTP 界面完全一致。
  Future<void> uploadTo({
    required String localPath,
    required String remotePath,
  }) async {
    _disconnected = false;
    final token = TransferCancelToken();
    _activeToken = token;
    _rateMeter.reset();
    try {
      final ops = await _getOps();
      final task = SftpTransferTask(
        ops: ops,
        cancelToken: token,
        onProgress: (p) {
          _rateMeter.sample(bytesDone: p.bytesDone, at: DateTime.now());
          transferState = TransferState(
            filename: remotePath.split('/').last,
            fraction: p.fraction,
            isSending: true,
            bytesTransferred: p.bytesDone,
            totalBytes: p.totalBytes,
            bytesPerSecond: _rateMeter.bytesPerSecond,
            eta: _rateMeter.etaFor(
              totalBytes: p.totalBytes,
              bytesDone: p.bytesDone,
            ),
          );
          _notify();
        },
      );
      await task.upload(localPath: localPath, remotePath: remotePath);
      // 上传成功后刷新目录 —— 同时开着 SFTP 视图时能立刻看到新文件。
      // 放在 try 内、异常之前：失败时目录没变化，刷新只是徒增一次往返。
      await listDirectory(currentPath);
    } catch (e) {
      // 这个方法一贯是 rethrow（调用方——附件上传流程——自己 catch 并显示
      // snackbar，不读 `error`/`isDisconnected`）。但 SFTP 浏览器等其它调用方
      // 需要 `isDisconnected` 才能决定要不要出重连按钮，所以在 rethrow 之前
      // 把这个状态记下来，不吞异常、不改变已有的错误传播路径。
      _disconnected = _isDisconnectFailure(e);
      lastError = e;
      rethrow;
    } finally {
      // 无论成功失败都要清掉进度条，否则失败后那条进度会永远停在屏幕上。
      transferState = null;
      _notify();
    }
  }

  Future<void> pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    final files = result.files.where((f) => f.path != null).toList();
    final total = files.length;

    for (var i = 0; i < files.length; i++) {
      final picked = files[i];
      final filename = picked.name;
      final label = total > 1 ? '(${i + 1}/$total) $filename' : filename;
      final remotePath =
          currentPath == '/' ? '/$filename' : '$currentPath/$filename';

      error = null;
      lastError = null;
      _disconnected = false;
      final token = TransferCancelToken();
      _activeToken = token;
      _rateMeter.reset();
      try {
        final ops = await _getOps();
        final task = SftpTransferTask(
          ops: ops,
          cancelToken: token,
          onProgress: (p) {
            _rateMeter.sample(bytesDone: p.bytesDone, at: DateTime.now());
            transferState = TransferState(
              filename: label,
              fraction: p.fraction,
              isSending: true,
              bytesTransferred: p.bytesDone,
              totalBytes: p.totalBytes,
              bytesPerSecond: _rateMeter.bytesPerSecond,
              eta: _rateMeter.etaFor(
                totalBytes: p.totalBytes,
                bytesDone: p.bytesDone,
              ),
            );
            _notify();
          },
        );
        await task.upload(localPath: picked.path!, remotePath: remotePath);
        transferState = null;
        await listDirectory(currentPath);
      } on TransferCancelledException {
        transferState = null;
        _notify();
        return;
      } catch (e) {
        _recordError(e);
        transferState = null;
        _notify();
        return;
      } finally {
        _activeToken = null;
      }
    }
  }

  /// 递归上传本地目录 [localRoot] 到远端 [remoteRoot]。
  ///
  /// [skipRelativePaths] 里的相对路径（用 `/` 分隔）会被跳过 —— 由调用方先
  /// 用 [detectConflicts] 探测、再让用户选「跳过 / 覆盖」，**不在传输中途弹
  /// 对话框**（那样用户得在进度条跑着的时候做决定）。
  ///
  /// [overwrite] 预留给 B4 的冲突 UI（「全部覆盖 / 全部跳过」）—— 当前实际
  /// 生效的跳过集就是 [skipRelativePaths]；传进来的 `overwrite == false` 时
  /// 调用方应把冲突全部放进 [skipRelativePaths]。
  ///
  /// 串行逐文件上传（与下载侧对称）：手机上行带宽
  /// 有限，并发只会让每个文件都变慢，且进度语义变得难以解释。
  Future<void> uploadDirectory({
    required String localRoot,
    required String remoteRoot,
    Set<String> skipRelativePaths = const {},
    bool overwrite = true,
    SftpUploadPlan? plan,
  }) async {
    error = null;
    lastError = null;
    _disconnected = false;
    _cancelRequested = false;
    _rateMeter.reset();

    // Phase 1 – 扫描（纯本地，见 SftpUploadPlan 的文档）。
    //
    // [plan] 可由调用方传入 —— UI 在探测同名冲突时**已经扫过一遍**，再扫一次
    // 是纯浪费；而且在 widget 测试里，真实 `dart:io` 扫描会在 FakeAsync 时钟下
    // 挂住，传入预扫描结果才能测到上传逻辑本身。
    final SftpUploadPlan plan2;
    if (plan != null) {
      plan2 = plan;
    } else {
      try {
        plan2 = await SftpUploadPlan.scan(
          localRoot,
          isCancelled: () => _cancelRequested,
        );
      } on UploadScanCancelled {
        // 扫描期取消：什么都没发生，静默收摊。
        transferState = null;
        _notify();
        return;
      } catch (e) {
        _recordError(e);
        transferState = null;
        _notify();
        return;
      }
    }

    if (plan2.files.isEmpty && plan2.directories.isEmpty) {
      transferState = null;
      _notify();
      return;
    }

    final token = TransferCancelToken();
    _activeToken = token;
    try {
      final ops = await _getOps();

      // Phase 2 – 递归建目录。**用 ops.mkdirRecursive**（阶段 A 加的：逐段
      // stat 探测，靠 mkdir 抛异常再吞的写法分不清「已存在」和「权限不足」）。
      for (final rel in plan2.requiredDirectories()) {
        _checkCancel();
        await ops.mkdirRecursive(joinRemote(remoteRoot, rel));
      }

      // Phase 3 – 串行传文件，整体进度（X/N + 字节 + 速率/ETA）。
      final total = plan2.files.length;
      final totalBytes = plan2.totalBytes;
      var filesCompleted = 0;
      var bytesTransferred = 0;

      for (final file in plan2.files) {
        _checkCancel();
        if (skipRelativePaths.contains(file.relativePath)) {
          filesCompleted++;
          bytesTransferred += file.size;
          continue;
        }

        final name = file.relativePath.split('/').last;
        transferState = TransferState(
          filename: name,
          fraction: totalBytes > 0 ? bytesTransferred / totalBytes : null,
          isSending: true,
          filesCompleted: filesCompleted,
          filesTotal: total,
          totalBytes: totalBytes,
          bytesTransferred: bytesTransferred,
        );
        _notify();

        final task = SftpTransferTask(
          ops: ops,
          cancelToken: token,
          onProgress: (p) {
            final done = bytesTransferred + p.bytesDone;
            _rateMeter.sample(bytesDone: done, at: DateTime.now());
            transferState = TransferState(
              filename: name,
              fraction: totalBytes > 0 ? done / totalBytes : null,
              isSending: true,
              filesCompleted: filesCompleted,
              filesTotal: total,
              totalBytes: totalBytes,
              bytesTransferred: done,
              bytesPerSecond: _rateMeter.bytesPerSecond,
              eta: _rateMeter.etaFor(
                totalBytes: totalBytes,
                bytesDone: done,
              ),
            );
            _notify();
          },
        );
        await task.upload(
          localPath: file.localPath,
          remotePath: joinRemote(remoteRoot, file.relativePath),
        );
        filesCompleted++;
        bytesTransferred += file.size;
      }

      transferState = null;
      _notify();
      await listDirectory(currentPath);
    } on _CancelException {
      transferState = null;
      _notify();
    } on TransferCancelledException {
      transferState = null;
      _notify();
    } catch (e) {
      _recordError(e);
      transferState = null;
      _notify();
    } finally {
      _activeToken = null;
    }
  }

  /// 探测 [relativePaths] 里哪些在远端已存在。
  ///
  /// 用 `stat(followLink: false)` —— 跟随后一个指向别处的软链会把「链接存在」
  /// 误判成「文件存在」，进而建议用户覆盖一个其实不冲突的位置。
  Future<Set<String>> detectConflicts({
    required String remoteRoot,
    required List<String> relativePaths,
  }) async {
    final ops = await _getOps();
    return detectConflictsForTest(
      ops,
      remoteRoot: remoteRoot,
      relativePaths: relativePaths,
    );
  }

  /// 拼远端路径，**避免根目录产生双斜杠**。
  ///
  /// 直接写 `'$remoteRoot/$rel'` 在 `remoteRoot == '/'` 时会得到 `//a.txt` ——
  /// 服务端当它不存在，于是**根目录下的冲突永远探测不到**，用户会在无声无息中
  /// 被覆盖。既有代码（`pickAndUpload` 那行）早就在用 `currentPath == '/' ?
  /// '/$filename' : ...` 的手写法，新加的路径拼接统一走这里，不再各写各的。
  static String joinRemote(String root, String rel) {
    if (rel.isEmpty) return root;
    final r = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    return '$r/$rel';
  }

  /// [detectConflicts] 的无状态内核 —— 不经过 `_getOps()`，测试可注入 fake。
  @visibleForTesting
  static Future<Set<String>> detectConflictsForTest(
    SftpOps ops, {
    required String remoteRoot,
    required List<String> relativePaths,
  }) async {
    final out = <String>{};
    for (final rel in relativePaths) {
      try {
        await ops.stat(joinRemote(remoteRoot, rel), followLink: false);
        out.add(rel);
      } catch (_) {
        // 不存在 —— 正是我们想要的。
      }
    }
    return out;
  }

  /// Downloads a remote folder recursively to device downloads dir.
  /// Phase 1: scan the tree to discover all files and total byte count.
  /// Phase 2: download each file with overall progress (X/N, bytes, %).
  /// Returns the local root path or null on error.
  Future<String?> downloadFolder(String remotePath) async {
    final folderName = remotePath.split('/').last;
    error = null;
    lastError = null;
    _disconnected = false;

    // Phase 1 – scan
    _rateMeter.reset();
    transferState = TransferState(
      filename: folderName,
      fraction: null,
      isSending: false,
      isScanning: true,
    );
    notifyListeners();

    try {
      final ops = await _getOps();
      final dir =
          _downloadDirProvider != null
              ? await _downloadDirProvider()
              : (await getDownloadsDirectory() ??
                  await getApplicationDocumentsDirectory());
      final localRoot = '${dir.path}/$folderName';

      final files = <_RemoteFile>[];
      await _scanFolder(ops, remotePath, localRoot, files);

      final totalBytes = files.fold<int>(0, (s, f) => s + f.size);
      int filesCompleted = 0;
      int bytesTransferred = 0;

      // Phase 2 – download
      for (final file in files) {
        _checkCancel();
        final name = file.remotePath.split('/').last;
        transferState = TransferState(
          filename: name,
          fraction: totalBytes > 0 ? bytesTransferred / totalBytes : null,
          isSending: false,
          filesCompleted: filesCompleted,
          filesTotal: files.length,
          totalBytes: totalBytes,
          bytesTransferred: bytesTransferred,
        );
        _notify();

        final sink = File(file.localPath).openWrite();
        try {
          await ops.download(
            file.remotePath,
            sink,
            onProgress: (read) {
              _checkCancel();
              final done = bytesTransferred + read;
              _rateMeter.sample(bytesDone: done, at: DateTime.now());
              transferState = TransferState(
                filename: name,
                fraction: totalBytes > 0 ? done / totalBytes : null,
                isSending: false,
                filesCompleted: filesCompleted,
                filesTotal: files.length,
                totalBytes: totalBytes,
                bytesTransferred: done,
                bytesPerSecond: _rateMeter.bytesPerSecond,
                eta: _rateMeter.etaFor(
                  totalBytes: totalBytes,
                  bytesDone: done,
                ),
              );
              _notify();
            },
          );
        } finally {
          await sink.close();
        }
        filesCompleted++;
        bytesTransferred += file.size;
      }

      transferState = null;
      _notify();
      return localRoot;
    } on _CancelException {
      transferState = null;
      _notify();
      return null;
    } catch (e) {
      _recordError(e);
      transferState = null;
      _notify();
      return null;
    }
  }

  /// Phase 1: traverse tree, create local dirs, collect file metadata.
  /// Notifies after each directory is listed so the UI shows a live count.
  Future<void> _scanFolder(
    SftpOps ops,
    String remotePath,
    String localPath,
    List<_RemoteFile> files,
  ) async {
    _checkCancel();
    await Directory(localPath).create(recursive: true);
    final names = await ops.listdir(remotePath);
    for (final entry in names) {
      if (entry.filename == '.' || entry.filename == '..') continue;
      final remoteChild = '$remotePath/${entry.filename}';
      final localChild = '$localPath/${entry.filename}';
      if (entry.attr.isDirectory && !entry.attr.isSymbolicLink) {
        await _scanFolder(ops, remoteChild, localChild, files);
      } else {
        // 软链当叶子：不下载目标内容。指向目录的软链在这里会作为一个
        // 0 字节（size 通常为 0）的条目被跳过（下载它本身没有意义，跟随又
        // 太危险）。判断用 lstat 语义 —— 与 _deleteRecursive 同理，安全性
        // 必须独立于 SftpEntry.isDir 的「可进入」语义。
        files.add(_RemoteFile(remoteChild, localChild, entry.attr.size ?? 0));
      }
    }
    // Notify once per directory so the discovered count updates incrementally.
    transferState = TransferState(
      filename: remotePath.split('/').last,
      fraction: null,
      isSending: false,
      isScanning: true,
      filesCompleted: files.length,
    );
    _notify();
  }

  /// Downloads [remotePath] to device downloads dir with resume support.
  /// Returns saved path or null on cancel / error.
  ///
  /// 传输本身由 [SftpTransferTask] 做；这里只负责把它的进度喂给自己的
  /// notifier 字段。文件大小改由 `stat` 拿 —— 原先取自 `entries`，那让
  /// 「下载一个不在当前列出目录里的文件」永远算不出进度。
  Future<String?> downloadFile(String remotePath) async {
    final filename = remotePath.split('/').last;
    error = null;
    lastError = null;
    _disconnected = false;
    lastPublishedPublicPath = null;

    try {
      final ops = await _getOps();
      final dir = _downloadDirProvider != null
          ? await _downloadDirProvider()
          : (await getDownloadsDirectory() ??
              await getApplicationDocumentsDirectory());

      // stat 失败不致命：拿不到大小就按 0 传（进度条走不确定态）。
      int total = 0;
      try {
        total = (await ops.stat(remotePath)).size ?? 0;
      } catch (_) {
        total = 0;
      }

      final token = TransferCancelToken();
      _activeToken = token;
      _rateMeter.reset();
      final task = SftpTransferTask(
        ops: ops,
        cancelToken: token,
        onProgress: (p) {
          _rateMeter.sample(bytesDone: p.bytesDone, at: DateTime.now());
          transferState = TransferState(
            filename: filename,
            fraction: p.fraction,
            isSending: false,
            bytesTransferred: p.bytesDone,
            totalBytes: p.totalBytes,
            bytesPerSecond: _rateMeter.bytesPerSecond,
            eta: _rateMeter.etaFor(
              totalBytes: p.totalBytes,
              bytesDone: p.bytesDone,
            ),
          );
          _notify();
        },
      );

      final saved = await task.download(
        remotePath: remotePath,
        destDir: dir,
        totalBytes: total,
        publishToPublicStore: _publishToPublicStore?.call() ?? false,
      );
      // 把公共路径接回来 —— `SftpInlineView._downloadFile` 靠它决定 snackbar
      // 说「已存到系统 Downloads 的 X」还是只说文件名。传输逻辑搬到 task 之后
      // 少了这一行，那条提示会静默退化，而 sftp_service_test 覆盖不到它。
      lastPublishedPublicPath = task.publishedPublicPath;
      transferState = null;
      _notify();
      return saved;
    } on TransferCancelledException {
      transferState = null;
      _notify();
      return null;
    } catch (e) {
      _recordError(e);
      transferState = null;
      _notify();
      return null;
    } finally {
      _activeToken = null;
    }
  }

  /// Downloads a remote file to [localPath] for preview purposes.
  /// Does NOT update [transferState] — intended for lightweight image/preview
  /// use where the caller manages its own progress UI. Returns [localPath] on
  /// success or throws on error. Resumes from existing partial file.
  Future<String> downloadToPath(
    String remotePath,
    String localPath, {
    void Function(int received, int total)? onProgress,
  }) async {
    final ops = await _getOps();
    final total =
        entries.where((e) => e.path == remotePath).firstOrNull?.size ?? 0;
    final file = File(localPath);
    int resumeOffset = 0;
    if (await file.exists()) {
      resumeOffset = await file.length();
      if (total > 0 && resumeOffset >= total) return localPath;
    }
    final sink = file.openWrite(
      mode: resumeOffset > 0 ? FileMode.append : FileMode.write,
    );
    try {
      await ops.downloadFromOffset(
        remotePath,
        sink,
        offset: resumeOffset,
        onProgress: (n) => onProgress?.call(resumeOffset + n, total),
      );
    } finally {
      await sink.close();
    }
    return localPath;
  }

  /// 读取文本文件，**并给出是否被截断的结论**。
  ///
  /// 上限 512 KB：超过的文件仍读前 512 KB，但 [ReadResult.truncated] 为 true，
  /// 调用方据此置为只读 —— 否则用户保存会把远端文件截断覆盖（见
  /// `sftp_read_result.dart` 的类文档）。
  ///
  /// 截断判据来自**实际读到的字节数 vs stat 得到的真实大小**，不再让 UI 拿
  /// `entry.size`（列表快照）去猜。快照过期是常态：文件在别处被追加、用户没
  /// 刷新目录。
  Future<ReadResult?> readTextFile(String remotePath) async {
    const maxBytes = 512 * 1024;
    isLoading = true;
    error = null;
    lastError = null;
    notifyListeners();
    _disconnected = false;
    try {
      final ops = await _getOps();
      // stat 失败不致命：拿不到真实大小就退化为「按读满上限判断」，
      // 仍然比旧行为（静默）安全。
      int? totalSize;
      try {
        totalSize = (await ops.stat(remotePath, followLink: true)).size;
      } catch (_) {
        totalSize = null;
      }
      final bytes = await ops.readBytes(remotePath, maxBytes: maxBytes);
      isLoading = false;
      _notify();
      return ReadResult.fromBytes(
        utf8.decode(bytes, allowMalformed: true),
        maxBytes: maxBytes,
        totalSize: totalSize,
      );
    } catch (e) {
      _recordError(e);
      isLoading = false;
      _notify();
      return null;
    }
  }

  Future<bool> writeTextFile(String remotePath, String content) async {
    isLoading = true;
    error = null;
    lastError = null;
    _disconnected = false;
    notifyListeners();
    try {
      final ops = await _getOps();
      await ops.writeBytes(
        remotePath,
        Uint8List.fromList(utf8.encode(content)),
      );
      isLoading = false;
      _notify();
      return true;
    } catch (e) {
      _recordError(e);
      isLoading = false;
      _notify();
      return false;
    }
  }

  Future<bool> rename(String oldPath, String newPath) async {
    error = null;
    lastError = null;
    _disconnected = false;
    notifyListeners();
    try {
      final ops = await _getOps();
      await ops.rename(oldPath, newPath);
      await listDirectory(currentPath);
      return true;
    } catch (e) {
      _recordError(e);
      _notify();
      return false;
    }
  }

  Future<bool> delete(String path, {required bool isDir}) async {
    error = null;
    lastError = null;
    _disconnected = false;
    notifyListeners();
    try {
      final ops = await _getOps();
      if (isDir) {
        await _deleteRecursive(ops, path);
      } else {
        await ops.remove(path);
      }
      await listDirectory(currentPath);
      return true;
    } catch (e) {
      _recordError(e);
      _notify();
      return false;
    }
  }

  /// Recursively deletes all contents of [path], then removes the directory.
  Future<void> _deleteRecursive(SftpOps ops, String path) async {
    final names = await ops.listdir(path);
    for (final n in names) {
      if (n.filename == '.' || n.filename == '..') continue;
      final child = '$path/${n.filename}';
      // **用 lstat 语义判断，不看 attr.isDirectory。**
      //
      // 软链一律当叶子：删链接本身，不递归进目标。跟随的话会删掉目标目录
      // 的内容，并且在 `a → b → a` 这种自指环上无限递归。
      //
      // 这里刻意不复用 SftpEntry.isDir —— 那个的语义是「可进入」（软链指向
      // 目录时也为 true），服务导航；安全性必须独立于它。
      final isDir = n.attr.isDirectory && !n.attr.isSymbolicLink;
      if (isDir) {
        await _deleteRecursive(ops, child);
      } else {
        await ops.remove(child);
      }
    }
    await ops.rmdir(path);
  }

  Future<bool> mkdir(String path) async {
    error = null;
    lastError = null;
    _disconnected = false;
    notifyListeners();
    try {
      final ops = await _getOps();
      await ops.mkdir(path);
      await listDirectory(currentPath);
      return true;
    } catch (e) {
      _recordError(e);
      _notify();
      return false;
    }
  }

  /// Creates an empty file at [path] (equivalent to `touch`).
  Future<bool> createFile(String path) async {
    error = null;
    lastError = null;
    _disconnected = false;
    notifyListeners();
    try {
      final ops = await _getOps();
      await ops.createFile(path);
      await listDirectory(currentPath);
      return true;
    } catch (e) {
      _recordError(e);
      _notify();
      return false;
    }
  }

  /// Changes the permission bits of [path] to [permissions] (lower 12 bits).
  Future<bool> chmod(String path, int permissions) async {
    error = null;
    lastError = null;
    _disconnected = false;
    try {
      final ops = await _getOps();
      await ops.setPermissions(path, permissions);
      await listDirectory(currentPath);
      return true;
    } catch (e) {
      _recordError(e);
      _notify();
      return false;
    }
  }

  /// Deletes all [entries] (files and/or directories) in a single batch.
  Future<bool> deleteAll(List<SftpEntry> entries) async {
    error = null;
    lastError = null;
    _disconnected = false;
    notifyListeners();
    try {
      final ops = await _getOps();
      for (final entry in entries) {
        if (entry.isDir) {
          await _deleteRecursive(ops, entry.path);
        } else {
          await ops.remove(entry.path);
        }
      }
      await listDirectory(currentPath);
      return true;
    } catch (e) {
      _recordError(e);
      _notify();
      return false;
    }
  }

  /// Returns the SFTP session's default directory (i.e. $HOME) via
  /// SFTP realpath('.').  More reliable than exec-channel $HOME because
  /// it uses the already-established SFTP subsystem with no extra round-trip.
  Future<String> queryHome() async {
    try {
      final ops = await _getOps().timeout(const Duration(seconds: 5));
      final path = await ops
          .absolutePath('.')
          .timeout(const Duration(seconds: 3));
      if (path.startsWith('/')) return path;
    } catch (_) {}
    return '/';
  }

  @override
  void dispose() {
    // 幂等：可能被 client.done listener 和 closeTab 同时触发。
    if (_disposed) return;
    _disposed = true;
    _ownedClient?.close();
    _ownedJumpClient?.close();
    super.dispose();
  }
}

/// Lightweight record used during folder scan to carry per-file metadata.
class _RemoteFile {
  final String remotePath;
  final String localPath;
  final int size;
  const _RemoteFile(this.remotePath, this.localPath, this.size);
}
