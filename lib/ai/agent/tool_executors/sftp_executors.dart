// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import '../../../sftp/sftp_service.dart' show SftpOps;
import '../agent_events.dart';
import '../agent_tool_context.dart';
import '../server_targets.dart';
import '../tool_models.dart';
import '../tool_registry.dart';
import 'arg_parsing.dart';

/// SFTP 文件管理工具。
///
/// ## 为什么不是让模型用 bash
///
/// `mv` / `rm` / `mkdir` / `chmod` 走 shell 要么命中放行规则（`rm *` 不在
/// 清单里，每次弹审批），要么被元字符一票否决。而这些操作经由 SFTP 协议
/// 有确切的语义和错误码，不受 shell 引用规则影响 —— 路径里有空格、引号、
/// 中括号时尤其明显：`rm "$(weird name)"` 的引用一旦写错就是删错文件，
/// 而 `ops.remove(path)` 没有这个失败模式。
///
/// ## 权限
///
/// 走 [checkFileWrite] 而非 app 侧的 [checkAppControl]：这些操作的对象是
/// **远端文件**，和 `write_file` / `edit_file` 同类，理应共用同一套路径
/// 判定（凭据目录保护、per-server 档位）。app 控制那套管的是本机 app 状态。
class SftpExecutors {
  final AgentToolContext ctx;

  SftpExecutors(this.ctx);

  static const _writeTools = {
    'sftp_mkdir',
    'sftp_rename',
    'sftp_remove',
    'sftp_chmod',
  };

  Future<ToolResult> run(ToolCall call, {bool preApproved = false}) async {
    final opsProvider = ctx.sftpOpsProvider;
    if (opsProvider == null) {
      return _fail(call, 'SFTP is not available in this session.');
    }

    final path = call.args['path'];
    if (path is! String || path.trim().isEmpty) {
      return _fail(call, missingArgMessage('path'));
    }
    final p = path.trim();

    // 跨机：复用与其余工具同一套目标解析，不另造一份。
    final servers = ctx.serverListProvider == null
        ? const <ServerListEntry>[]
        : await ctx.serverListProvider!();
    final target = resolveServerTarget(call.args['server'], servers);
    if (!target.ok) return _fail(call, target.error!);

    final isWrite = _writeTools.contains(call.name);

    // 判定用 `cat <path>` 这个口径 —— 与 read_file 一致，不给绕过凭据
    // 目录保护的后门（见 tool_registry 里 checkReadFile 的说明）。
    final check = isWrite
        ? checkFileWrite(p, rules: ctx.rulesProvider(), mode: ctx.modeProvider())
        : checkReadFile(p, rules: ctx.rulesProvider(), mode: ctx.modeProvider());

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: _display(call, p, target.serverName),
      description: call.args['description'] is String
          ? call.args['description'] as String
          : '',
      check: check,
      targetServerName: target.serverName,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    final SftpOps ops;
    try {
      ops = await opsProvider(target.serverId);
    } catch (e) {
      return _finishErr(call, ev, 'Could not open SFTP: $e');
    }

    try {
      final out = await _dispatch(call, ops, p);
      ctx.finishToolCall(ev, ToolCallStatus.done);
      ev.output = out;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: out);
    } catch (e) {
      return _finishErr(call, ev, '${call.name} failed: $e');
    }
  }

  Future<String> _dispatch(ToolCall call, SftpOps ops, String p) async {
    switch (call.name) {
      case 'sftp_list':
        final entries = await ops.listdir(p);
        if (entries.isEmpty) return 'Empty directory.';
        return const JsonEncoder.withIndent('  ').convert([
          for (final e in entries)
            {
              'name': e.filename,
              'dir': e.attr.isDirectory,
              if (e.attr.size != null) 'size': e.attr.size,
            }
        ]);

      case 'sftp_stat':
        final a = await ops.stat(p);
        return const JsonEncoder.withIndent('  ').convert({
          'path': p,
          'size': a.size,
          'dir': a.isDirectory,
          if (a.mode != null) 'mode': '${a.mode}',
        });

      case 'sftp_mkdir':
        await ops.mkdir(p);
        return 'Created directory `$p`.';

      case 'sftp_rename':
        final to = call.args['to'];
        if (to is! String || to.trim().isEmpty) {
          throw ArgumentError('`to` is required for sftp_rename.');
        }
        await ops.rename(p, to.trim());
        return 'Renamed `$p` → `${to.trim()}`.';

      case 'sftp_remove':
        // 目录和文件是两个不同的 SFTP 操作，选错会报一个对模型没有信息量
        // 的协议错误。先 stat 一次把这个分支判掉。
        final attr = await ops.stat(p);
        if (attr.isDirectory) {
          await ops.rmdir(p);
          return 'Removed directory `$p`.';
        }
        await ops.remove(p);
        return 'Removed `$p`.';

      case 'sftp_chmod':
        final mode = call.args['mode'];
        final parsed = mode is int
            ? mode
            : int.tryParse('$mode'.replaceFirst('0o', ''), radix: 8);
        if (parsed == null) {
          throw ArgumentError('`mode` must be an octal string like "644".');
        }
        await ops.setPermissions(p, parsed);
        return 'Set mode of `$p` to ${parsed.toRadixString(8)}.';

      default:
        throw ArgumentError('Unknown SFTP tool ${call.name}.');
    }
  }

  String _display(ToolCall call, String p, String? server) {
    final verb = switch (call.name) {
      'sftp_list' => 'ls',
      'sftp_stat' => 'stat',
      'sftp_mkdir' => 'mkdir',
      'sftp_rename' => 'mv',
      'sftp_remove' => 'rm',
      _ => 'chmod',
    };
    final extra = switch (call.name) {
      'sftp_rename' => ' ${call.args['to']}',
      'sftp_chmod' => ' ${call.args['mode']}',
      _ => '',
    };
    final base = '$verb $p$extra';
    return server == null ? base : '[$server] $base';
  }

  ToolResult _finishErr(ToolCall call, ToolCallEvent ev, String msg) {
    ctx.finishToolCall(ev, ToolCallStatus.failed);
    ev.output = msg;
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: msg, isError: true);
  }

  ToolResult _fail(ToolCall call, String msg) => ctx.failToolBare(call, msg);
}
