// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io' show File;

import '../../../sftp/sftp_service.dart' show SftpOps;
import '../../../sftp/sftp_transfer_task.dart';
import '../agent_events.dart';
import '../agent_tool_context.dart';
import '../server_targets.dart';
import '../tool_models.dart';
import '../tool_registry.dart';
import '../transfer_guard.dart';
import '../turn_metrics.dart';

/// 文件传输三件事：下载、上传、服务器间直传。
///
/// 从 `agent_loop.dart` 搬出来的第一个 executor 域。选它开头是因为三个方法
/// 用到的 loop 内部成员**完全相同**（实测 11 个，无一独有），是验证
/// [AgentToolContext] 形状够不够用的最好样本 —— 如果连依赖最一致的一组都要
/// 往接口里加特例，那个接口就是错的。
///
/// 三个方法都不走 `checkCommand` / `checkFileWrite`：那两个判定的输入是 bash
/// 命令字符串与 `PermissionRuleSet`，传输两样都没有。传输永远弹卡，
/// 判定只回答「能不能开始」和「要不要示警」，那是
/// `checkTransferPath` 的职责。
/// 跨服务器拷贝的大小上限。
///
/// 中转要把整个文件先落到手机上，再传出去。超过这个数就直接拒绝而不是「警告
/// 会慢」——用户点了同意再等十几分钟，比一开始就说不行糟得多。
///
/// 抽成常量而不是散在判断里：以后要变成配置项时只有一个地方要改。
const int kMaxRelayBytes = 100 * 1024 * 1024;

class TransferExecutors {
  final AgentToolContext ctx;

  TransferExecutors(this.ctx);

  /// 下载一个远端文件到手机。
  ///
  /// **不走 `checkCommand` / `checkFileWrite`。** 那两个判定的输入是 bash
  /// 命令字符串与 `PermissionRuleSet`，传输两样都没有。传输永远弹卡，
  /// 判定只需回答「能不能开始」和「要不要示警」——
  /// 那是 `checkTransferPath` 的职责。
  Future<ToolResult> download(ToolCall call,
      {bool preApproved = false, ToolMetrics? tm}) async {
    final raw = call.args['remote_path'];
    if (raw is! String) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id,
          content: 'Invalid arguments: `remote_path` is required.',
          isError: true);
    }
    final guard = checkTransferPath(raw);
    if (!guard.ok) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id, content: guard.error!, isError: true);
    }
    ctx.resetInvalidArgs();

    final path = raw.trim();
    final filename = path.split('/').last;
    final desc = call.args['description'];

    final opsProvider = ctx.sftpOpsProvider;
    final dirProvider = ctx.downloadDirProvider;
    if (opsProvider == null || dirProvider == null) {
      return ToolResult(
        callId: call.id,
        content: 'File transfer is not available in this session.',
        isError: true,
      );
    }

    // stat 是免审批的只读探测 —— 审批卡必须先能说出「多大」。
    final SftpOps ops;
    final int totalBytes;
    try {
      ops = await opsProvider(null);
      totalBytes = (await ops.stat(path)).size ?? 0;
    } catch (e) {
      return ToolResult(
        callId: call.id,
        content: 'Cannot read `$path`: $e',
        isError: true,
      );
    }

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: 'download $path ($totalBytes bytes)',
      description: desc is String ? desc : '',
      // 传输不受 allowlist 影响，但审批卡要靠 `denyHit` 决定是否显示凭据
      // 警示 —— 那个 getter 从 reason 派生，所以这里必须给对应的 reason。
      check: CheckResult(
        decision: ToolDecision.needApproval,
        reason: guard.credentialDeny
            ? ApprovalReason.credentialDeny
            : ApprovalReason.fileWrite,
      ),
    );
    ctx.addEvent(ev);

    if (!preApproved) {
      final outcome = await ctx.timedAwaitApproval(ev, tm);
      if (outcome.decision == ApprovalDecision.reject) {
        return ctx.rejectedResult(ev, outcome);
      }
      if (outcome.decision == ApprovalDecision.addToPlan) {
        return ctx.transferNotQueueable(ev);
      }
    }

    final tev = TransferEvent(
      seq: ctx.nextSeq(),
      direction: TransferDirection.download,
      remotePath: path,
      filename: filename,
      totalBytes: totalBytes,
      credentialDeny: guard.credentialDeny,
    );
    ctx.addEvent(tev);
    ev.status = ToolCallStatus.running;
    ev.startedAt = DateTime.now();
    ctx.enterState(AgentLoopState.executing);
    ctx.notifyChanged();

    final token = TransferCancelToken();
    ctx.registerTransfer(tev.seq, token);
    final task = SftpTransferTask(
      ops: ops,
      cancelToken: token,
      onProgress: (p) {
        tev.bytesDone = p.bytesDone;
        ctx.notifyChanged();
      },
    );

    try {
      final saved = await task.download(
        remotePath: path,
        destDir: await dirProvider(),
        totalBytes: totalBytes,
        publishToPublicStore: ctx.publishToPublicStore?.call() ?? false,
      );
      tev.localPath = saved;
      tev.status = TransferStatus.done;
      ctx.finishToolCall(ev, ToolCallStatus.done);
      ev.output = 'downloaded to $saved';
      ctx.notifyChanged();
      // 回填**不含文件内容**：要不要读，用户点结果卡上的
      // 按钮决定。这里多说一句是为了让模型不去猜。
      final okMsg = 'Downloaded `$path` to the phone '
          '($totalBytes bytes, ${guessMimeType(filename)}). '
          'You have NOT been shown its contents — the user decides whether '
          'to share them with you.';
      return ToolResult(
        callId: call.id,
        content: okMsg,
      );
    } on TransferCancelledException catch (e) {
      tev.status = TransferStatus.cancelled;
      tev.bytesDone = e.bytesDone;
      ev.status = ToolCallStatus.rejected;
      ctx.notifyChanged();
      return ToolResult(
        callId: call.id,
        content: 'The user cancelled the download after ${e.bytesDone} of '
            '$totalBytes bytes. A partial file was kept, so retrying resumes.',
        isError: true,
      );
    } on TransferStalledException catch (e) {
      tev.status = TransferStatus.failed;
      tev.error = 'stalled at ${e.bytesDone} bytes';
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ctx.notifyChanged();
      return ToolResult(
        callId: call.id,
        content: 'The download stalled at ${e.bytesDone} of $totalBytes bytes '
            'with no progress. Retrying resumes from there.',
        isError: true,
      );
    } catch (e, st) {
      ctx.noteToolError(st);
      tev.status = TransferStatus.failed;
      tev.error = e.toString();
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = toolErrorForCard(e, st);
      ctx.notifyChanged();
      return ToolResult(
          callId: call.id, content: 'Download failed: $e', isError: true);
    } finally {
      ctx.unregisterTransfer(tev.seq);
    }
  }

  /// 上传一个用户选中的本地文件到远端目录。
  ///
  /// **picker 在审批卡之前**：审批卡的价值来自它显示的信息，
  /// 而在选文件之前那张卡说不出文件名、大小，尤其说不出「会覆盖什么」——
  /// 恰恰是最该示警的那一格。打开选择器本身不是破坏性动作。
  Future<ToolResult> upload(ToolCall call,
      {bool preApproved = false, ToolMetrics? tm}) async {
    final raw = call.args['remote_dir'];
    if (raw is! String) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id,
          content: 'Invalid arguments: `remote_dir` is required.',
          isError: true);
    }
    final guard = checkTransferPath(raw);
    if (!guard.ok) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id, content: guard.error!, isError: true);
    }
    ctx.resetInvalidArgs();

    final dir = raw.trim();
    final desc = call.args['description'];
    final opsProvider = ctx.sftpOpsProvider;
    final picker = ctx.pickLocalFile;
    if (opsProvider == null || picker == null) {
      return ToolResult(
        callId: call.id,
        content: 'File transfer is not available in this session.',
        isError: true,
      );
    }

    final localPath = await picker();
    if (localPath == null || localPath.isEmpty) {
      return ToolResult(
        callId: call.id,
        content: 'The user cancelled the file picker. Nothing was uploaded.',
      );
    }

    final filename = localPath.split('/').last;
    final remotePath = joinRemote(dir, filename);
    final localFile = File(localPath);
    final int localBytes;
    try {
      localBytes = await localFile.length();
    } catch (e) {
      return ToolResult(
          callId: call.id,
          content: 'Cannot read the picked file: $e',
          isError: true);
    }

    final SftpOps ops;
    try {
      ops = await opsProvider(null);
    } catch (e) {
      return ToolResult(
          callId: call.id,
          content: 'Cannot open an SFTP channel: $e',
          isError: true);
    }

    // 目标是否已存在 —— 决定要不要备份，以及卡上要不要示警。
    var willOverwrite = false;
    try {
      await ops.stat(remotePath);
      willOverwrite = true;
    } catch (_) {
      willOverwrite = false;
    }

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: willOverwrite
          ? 'upload $filename ($localBytes bytes) → $remotePath '
              '(overwrite, backup kept)'
          : 'upload $filename ($localBytes bytes) → $remotePath',
      description: desc is String ? desc : '',
      check: const CheckResult(
        decision: ToolDecision.needApproval,
        reason: ApprovalReason.fileWrite,
      ),
    );
    ctx.addEvent(ev);

    if (!preApproved) {
      final outcome = await ctx.timedAwaitApproval(ev, tm);
      if (outcome.decision == ApprovalDecision.reject) {
        return ctx.rejectedResult(ev, outcome);
      }
      if (outcome.decision == ApprovalDecision.addToPlan) {
        return ctx.transferNotQueueable(ev);
      }
    }

    final tev = TransferEvent(
      seq: ctx.nextSeq(),
      direction: TransferDirection.upload,
      remotePath: remotePath,
      filename: filename,
      totalBytes: localBytes,
      localPath: localPath,
    );
    ctx.addEvent(tev);
    ev.status = ToolCallStatus.running;
    ev.startedAt = DateTime.now();
    ctx.enterState(AgentLoopState.executing);
    ctx.notifyChanged();

    final token = TransferCancelToken();
    ctx.registerTransfer(tev.seq, token);
    final task = SftpTransferTask(
      ops: ops,
      cancelToken: token,
      onProgress: (p) {
        tev.bytesDone = p.bytesDone;
        ctx.notifyChanged();
      },
    );

    try {
      // 备份在传输之前做，不在之后 —— 传输一开始 truncate 就把原文件毁了。
      if (willOverwrite) {
        final backup = transferBackupPath(remotePath, ev.seq);
        await ops.rename(remotePath, backup);
        tev.backupPath = backup;
      }

      await task.upload(localPath: localPath, remotePath: remotePath);
      tev.status = TransferStatus.done;
      ctx.finishToolCall(ev, ToolCallStatus.done);
      ev.output = 'uploaded to $remotePath';
      ctx.notifyChanged();
      final okMsg =
          'Uploaded `$filename` ($localBytes bytes) to `$remotePath`.'
          '${tev.backupPath != null ? ' The previous file was kept at '
              '`${tev.backupPath}`.' : ''}';
      return ToolResult(
        callId: call.id,
        content: okMsg,
      );
    } on TransferCancelledException catch (e) {
      tev.status = TransferStatus.cancelled;
      tev.bytesDone = e.bytesDone;
      ev.status = ToolCallStatus.rejected;
      ctx.notifyChanged();
      return ToolResult(
        callId: call.id,
        content: 'The user cancelled the upload after ${e.bytesDone} of '
            '$localBytes bytes. `$remotePath` may be incomplete.'
            '${tev.backupPath != null ? ' The previous file is at '
                '`${tev.backupPath}`.' : ''}',
        isError: true,
      );
    } on TransferStalledException catch (e) {
      tev.status = TransferStatus.failed;
      tev.error = 'stalled at ${e.bytesDone} bytes';
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ctx.notifyChanged();
      return ToolResult(
        callId: call.id,
        content: 'The upload stalled at ${e.bytesDone} of $localBytes bytes.',
        isError: true,
      );
    } catch (e, st) {
      ctx.noteToolError(st);
      tev.status = TransferStatus.failed;
      tev.error = e.toString();
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = toolErrorForCard(e, st);
      ctx.notifyChanged();
      return ToolResult(
          callId: call.id, content: 'Upload failed: $e', isError: true);
    } finally {
      ctx.unregisterTransfer(tev.seq);
    }
  }

  /// 把一个文件从一台服务器拷到另一台，经手机中转。
  ///
  /// **只做中转，不做 scp 直连。** 同一句话在任何机器对之间走同一条路，不依赖
  /// 「这两台之间有没有互信」这个本应用并不知道、且会随密钥轮换而变的状态。
  /// 超过 [kMaxRelayBytes] 直接拒绝并在错误里指向 scp —— 不给退路，模型会把
  /// 同一个被拒的调用反复发几轮。
  Future<ToolResult> copyBetweenServers(ToolCall call,
      {bool preApproved = false, ToolMetrics? tm}) async {
    final srcRaw = call.args['remote_path'];
    if (srcRaw is! String) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id,
          content: 'Invalid arguments: `remote_path` is required.',
          isError: true);
    }
    final srcCheck = checkTransferPath(srcRaw);
    if (!srcCheck.ok) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id, content: srcCheck.error!, isError: true);
    }
    final srcPath = srcRaw.trim();

    final destRaw = call.args['dest_path'];
    final String destPath;
    if (destRaw == null) {
      // 省略 = 同路径。同构集群统一配置是最常见的意图。
      destPath = srcPath;
    } else {
      final destCheck = checkTransferPath(destRaw);
      if (!destCheck.ok) {
        ctx.noteInvalidArgs();
        return ToolResult(
            callId: call.id, content: destCheck.error!, isError: true);
      }
      destPath = (destRaw as String).trim();
    }

    final servers =
        await ctx.serverListProvider?.call() ?? const <ServerListEntry>[];
    final from = resolveServerTarget(call.args['from_server'], servers);
    if (!from.ok) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id, content: from.error!, isError: true);
    }
    final to = resolveServerTarget(call.args['to_server'], servers);
    if (!to.ok) {
      ctx.noteInvalidArgs();
      return ToolResult(callId: call.id, content: to.error!, isError: true);
    }
    if (!from.isRemote || !to.isRemote) {
      ctx.noteInvalidArgs();
      return ToolResult(
        callId: call.id,
        content: 'Both `from_server` and `to_server` are required and must '
            'name saved servers.',
        isError: true,
      );
    }
    if (from.serverId == to.serverId) {
      ctx.noteInvalidArgs();
      return ToolResult(
        callId: call.id,
        content: 'Source and destination are the same server. To copy a file '
            'within one machine, use `bash` with `cp`.',
        isError: true,
      );
    }
    ctx.resetInvalidArgs();

    final opsProvider = ctx.sftpOpsProvider;
    final tempProvider = ctx.relayTempDirProvider;
    if (opsProvider == null || tempProvider == null) {
      return ToolResult(
        callId: call.id,
        content: 'Cross-server copy is not available in this session.',
        isError: true,
      );
    }

    // stat 是免审批的只读探测：审批卡必须先能说出文件多大，而超限要在弹卡
    // 之前就拒掉。
    final SftpOps srcOps;
    final int totalBytes;
    try {
      srcOps = await opsProvider(from.serverId);
      totalBytes = (await srcOps.stat(srcPath)).size ?? 0;
    } catch (e) {
      return ToolResult(
        callId: call.id,
        content: 'Cannot read `$srcPath` on ${from.serverName}: $e',
        isError: true,
      );
    }

    if (totalBytes > kMaxRelayBytes) {
      return ToolResult(
        callId: call.id,
        content: '`$srcPath` is $totalBytes bytes, over the '
            '$kMaxRelayBytes limit for server-to-server copy (it relays '
            'through the phone). Do not retry this call. For a file this '
            'large, run `scp` or `rsync` on ${from.serverName} with `bash` '
            'instead — that requires ${from.serverName} to have key-based '
            'access to ${to.serverName}.',
        isError: true,
      );
    }

    final SftpOps dstOps;
    try {
      dstOps = await opsProvider(to.serverId);
    } catch (e) {
      return ToolResult(
        callId: call.id,
        content: 'Cannot open an SFTP channel to ${to.serverName}: $e',
        isError: true,
      );
    }

    var willOverwrite = false;
    try {
      await dstOps.stat(destPath);
      willOverwrite = true;
    } catch (_) {
      willOverwrite = false;
    }

    final filename = srcPath.split('/').last;
    final desc = call.args['description'];
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: willOverwrite
          ? 'copy ${from.serverName}:$srcPath → ${to.serverName}:$destPath '
              '($totalBytes bytes, overwrite, backup kept)'
          : 'copy ${from.serverName}:$srcPath → ${to.serverName}:$destPath '
              '($totalBytes bytes)',
      description: desc is String ? desc : '',
      check: CheckResult(
        decision: ToolDecision.needApproval,
        reason: srcCheck.credentialDeny
            ? ApprovalReason.credentialDeny
            : ApprovalReason.fileWrite,
      ),
    );
    ctx.addEvent(ev);

    // 无条件弹卡 —— 不查 PermissionRuleSet、不看 PermissionMode。
    if (!preApproved) {
      final outcome = await ctx.timedAwaitApproval(ev, tm);
      if (outcome.decision == ApprovalDecision.reject) {
        return ctx.rejectedResult(ev, outcome);
      }
      if (outcome.decision == ApprovalDecision.addToPlan) {
        return ctx.transferNotQueueable(ev);
      }
    }

    final tev = TransferEvent(
      seq: ctx.nextSeq(),
      direction: TransferDirection.relay,
      remotePath: srcPath,
      destPath: destPath,
      fromServerName: from.serverName,
      toServerName: to.serverName,
      filename: filename,
      totalBytes: totalBytes,
      credentialDeny: srcCheck.credentialDeny,
      phase: TransferPhase.downloading,
    );
    ctx.addEvent(tev);
    ev.status = ToolCallStatus.running;
    ev.startedAt = DateTime.now();
    ctx.enterState(AgentLoopState.executing);
    ctx.notifyChanged();

    final token = TransferCancelToken();
    ctx.registerTransfer(tev.seq, token);

    // 失败时也要能删，所以路径在 try 之外先算出来。`SftpTransferTask.download`
    // 落盘用的就是 `destDir/文件名`，续传中间态是它加 `.flyterm.part`。
    final tempDir = await tempProvider();
    final tempPath = '${tempDir.path}/$filename';

    try {
      // 备份必须在传输之前：上传一开始就 truncate 目标，之后再备份只能备份到
      // 一个空文件。
      if (willOverwrite) {
        final backup = transferBackupPath(destPath, ev.seq);
        await dstOps.rename(destPath, backup);
        tev.backupPath = backup;
        ctx.notifyChanged();
      }

      // 下载段占进度前半。
      final dl = SftpTransferTask(
        ops: srcOps,
        cancelToken: token,
        onProgress: (p) {
          tev.bytesDone = p.bytesDone ~/ 2;
          ctx.notifyChanged();
        },
      );
      await dl.download(
        remotePath: srcPath,
        destDir: tempDir,
        totalBytes: totalBytes,
        // 中转的临时文件绝不能发布进系统 Downloads 集合。
        publishToPublicStore: false,
      );
      tev.localPath = tempPath;

      // 上传段占进度后半。
      tev.phase = TransferPhase.uploading;
      ctx.notifyChanged();
      final ul = SftpTransferTask(
        ops: dstOps,
        cancelToken: token,
        onProgress: (p) {
          tev.bytesDone = totalBytes ~/ 2 + p.bytesDone ~/ 2;
          ctx.notifyChanged();
        },
      );
      await ul.upload(localPath: tempPath, remotePath: destPath);

      tev.bytesDone = totalBytes;
      tev.status = TransferStatus.done;
      ctx.finishToolCall(ev, ToolCallStatus.done);
      ev.output = 'copied to ${to.serverName}:$destPath';
      ctx.notifyChanged();
      final okMsg = 'Copied `$srcPath` from ${from.serverName} to '
          '${to.serverName}:`$destPath` ($totalBytes bytes).'
          '${tev.backupPath != null ? ' The previous file there was kept at '
              '`${tev.backupPath}`.' : ''}';
      return ToolResult(
        callId: call.id,
        content: okMsg,
      );
    } on TransferCancelledException catch (e) {
      tev.status = TransferStatus.cancelled;
      ev.status = ToolCallStatus.rejected;
      ctx.notifyChanged();
      final half = tev.phase == TransferPhase.uploading;
      return ToolResult(
        callId: call.id,
        content: 'The user cancelled the copy after ${e.bytesDone} bytes'
            '${half ? ', while uploading to ${to.serverName} — '
                '`$destPath` there may be incomplete' : ''}.'
            '${tev.backupPath != null ? ' The previous file is at '
                '`${tev.backupPath}`.' : ''}',
        isError: true,
      );
    } catch (e, st) {
      ctx.noteToolError(st);
      tev.status = TransferStatus.failed;
      tev.error = e.toString();
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = toolErrorForCard(e, st);
      ctx.notifyChanged();
      // 上传段失败会在目标机器上留下半截文件。不说明的话模型会以为拷贝成功、
      // 接着去重启服务。
      final duringUpload = tev.phase == TransferPhase.uploading;
      return ToolResult(
        callId: call.id,
        content: duringUpload
            ? 'Upload to ${to.serverName} failed: $e. '
                '`$destPath` there may be incomplete.'
                '${tev.backupPath != null ? ' The previous file is at '
                    '`${tev.backupPath}`.' : ''}'
            : 'Download from ${from.serverName} failed: $e. '
                '${to.serverName} was not touched.',
        isError: true,
      );
    } finally {
      ctx.unregisterTransfer(tev.seq);
      // 无条件删临时文件与它的续传中间态。本功能没有续传，所以任何终态下它们
      // 都没有保留价值。
      for (final p in [tempPath, '$tempPath.flyterm.part']) {
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {
          // 删不掉不该让整次拷贝报错 —— 文件已经到位了。
        }
      }
    }
  }
}
