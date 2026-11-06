// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import '../agent_events.dart';
import '../agent_tool_context.dart';
import '../command_runner.dart';
import '../file_edit.dart';
import '../server_targets.dart';
import '../tool_models.dart';
import '../tool_registry.dart';
import '../turn_metrics.dart';

/// 写文件两件事：整篇覆盖（`write_file`）与按串替换（`edit_file`）。
///
/// 第四个搬进 `tool_executors/` 的域，也是**唯一一个会等两次审批**的：
/// `edit_file` 要先在远端读原文算出 diff、把 diff 摆给用户看，再等第二次
/// 批准才落盘。中间那次远端往返意味着取消可能落在两次审批之间 —— 这也是
/// [AgentToolContext.awaitApproval] 里那道「已取消就别再挂起」防线存在的
/// 原因，见它的 dartdoc。
///
/// `_runFileWrite` 是两条路径共用的落盘段，跟着一起搬 —— 它只被这个域调用。
class FileExecutors {
  final AgentToolContext ctx;

  FileExecutors(this.ctx);

  /// 执行 `write_file`：整份覆盖。
  ///
  /// 参数校验与大小检查都在弹审批**之前**做完 —— 注定要失败的操作不该先
  /// 占用用户一次点击，那种「点了同意然后看到报错」的体验比直接报错更差。
  Future<ToolResult> writeFile(ToolCall call,
      {bool preApproved = false, ToolMetrics? tm}) async {
    final path = call.args['path'];
    final content = call.args['content'];
    if (path is! String || path.trim().isEmpty) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id,
          content: 'Invalid arguments: `path` is required.',
          isError: true);
    }
    if (content is! String) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id,
          content: 'Invalid arguments: `content` is required and must be a '
              'string.',
          isError: true);
    }
    final bytes = utf8.encode(content);
    if (bytes.length > kMaxEditFileBytes) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id,
          content: 'That content is ${bytes.length} bytes; the limit is '
              '$kMaxEditFileBytes. Write a smaller file, or use `bash`.',
          isError: true);
    }
    ctx.resetInvalidArgs();

    final servers =
        await ctx.serverListProvider?.call() ?? const <ServerListEntry>[];
    final target = resolveServerTarget(call.args['server'], servers);
    if (!target.ok) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id, content: target.error!, isError: true);
    }

    final p = path.trim();
    final cwd = target.isRemote ? null : ctx.cwdProvider?.call();
    final desc = call.args['description'];
    final check = checkFileWrite(p,
        rules: ctx.rulesProvider(), mode: ctx.modeProvider(), cwd: cwd);

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: target.isRemote
          ? '[${target.serverName}] write $p (${_lineCount(content)} lines)'
          : 'write $p (${_lineCount(content)} lines)',
      description: desc is String ? desc : '',
      check: check,
      preview: FileEditPreview(path: p, newText: content),
      targetServerName: target.serverName,
    );
    ctx.addEvent(ev);

    if (!preApproved) {
      if (check.decision == ToolDecision.deferToPlan) {
        return ctx.deferWrite(ev, call);
      }
      if (check.decision == ToolDecision.needApproval) {
        final outcome = await ctx.timedAwaitApproval(ev, tm);
        if (outcome.decision == ApprovalDecision.reject) {
          return ctx.rejectedResult(ev, outcome);
        }
        if (outcome.decision == ApprovalDecision.addToPlan) {
          return ctx.deferOrRejectFromApproval(ev, call, check);
        }
      }
    }

    return _runFileWrite(ev, buildWriteFileCommand(p, bytes, seq: ev.seq), cwd,
        okMessage: 'Wrote ${bytes.length} bytes to $p.',
        backupPath: dotBackupPathForSeq(p, ev.seq),
        serverId: target.serverId,
        tm: tm);
  }

  /// 执行一条写文件命令并把结果整理成 ToolResult。
  ///
  /// 成功时**不回填文件内容** —— 模型自己刚给出的内容，回给它是纯浪费。
  Future<ToolResult> _runFileWrite(
    ToolCallEvent ev,
    String command,
    String? cwd, {
    required String okMessage,
    /// 这条写入命令里用的备份路径，成功后记到事件上供撤销使用。
    required String backupPath,
    /// 目标服务器。null = 当前会话那台。
    String? serverId,
    ToolMetrics? tm,
  }) async {
    // 结构性兜底：这是 write_file / edit_file（以及未来任何写文件工具）
    // 唯一的出口。前面两道闸（`_awaitApproval` 入口、edit_file 阶段三入口）
    // 覆盖了目前已知会绕过审批判定的路径，但那依赖「每个调用点都记得
    // 检查」。在这里再判一次，把「取消之后不写」从「我们检查了这些路径」
    // 变成「写入这个动作本身拒绝在取消后执行」，不管调用方是谁、走了
    // 哪条判定分支。
    if (ctx.cancelRequested || ctx.disposed) {
      ev.status = ToolCallStatus.rejected;
      ctx.notifyChanged();
      return ToolResult(
        callId: ev.callId,
        content: 'Session was cancelled before the write. Nothing was '
            'written.',
        isError: true,
      );
    }
    ev.status = ToolCallStatus.running;
    ev.startedAt = DateTime.now();
    ctx.enterState(AgentLoopState.executing);

    final CommandOutput out;
    try {
      out = await ctx.runnerProvider(serverId).run(command, cwd: cwd);
    } catch (e, st) {
      ctx.noteToolError(st);
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = toolErrorForCard(e, st);
      ctx.notifyChanged();
      return ToolResult(
          callId: ev.callId, content: 'Write failed: $e', isError: true);
    }

    ev.exitCode = out.exitCode;
    if (out.exitCode == kStaleFileExitCode) {
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = 'file changed on disk';
      ctx.notifyChanged();
      return ToolResult(
        callId: ev.callId,
        content: 'The file changed on disk between my read and this write. '
            'Nothing was written. Read it again if you still want the edit.',
        isError: true,
        exitCode: out.exitCode,
      );
    }
    if (!out.isSuccess) {
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = formatForModel(out);
      ctx.notifyChanged();
      return ToolResult(
          callId: ev.callId,
          content: ev.output!,
          isError: true,
          exitCode: out.exitCode,
          timedOut: out.timedOut);
    }

    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = okMessage;
    ev.backupPath = backupPath;
    ctx.notifyChanged();
    return ToolResult(
        callId: ev.callId, content: okMessage, exitCode: out.exitCode);
  }

  /// 执行 `edit_file`：读 → 改 → 审批 → 写。
  ///
  /// ## 为什么改在客户端做
  ///
  /// 不在远端拼 `sed`：唯一性校验靠正则不可靠，diff 也算不出来。读回本地做，
  /// 三样东西同时到手 —— 可靠的唯一性判断、能直接摆在审批卡上的 diff、
  /// 远端只承受一次写入。
  ///
  /// ## 两次判定，两个位置
  ///
  /// **读**按 `cat <path>` 判定（[checkReadFile]，与 `read_file` 完全一致，
  /// 见 `_resolve` 的说明）。这样它不会成为绕过规则读任意文件的后门：默认
  /// 清单有 `cat *` 所以通常直接放行；路径落在凭据清单里就照常先弹一次
  /// 审批。
  ///
  /// **写**按 [checkFileWrite] 判定，永远审批、永不可记住。
  ///
  /// 于是最坏情况是两次审批 —— 而那恰好发生在「用户本来就想被多问一次」
  /// 的场合（改 `~/.env` 一类的凭据文件）。正常情况只有写那一次，且带完整
  /// diff。
  ///
  /// ## 两个 `ToolCallEvent` 用同一个 `callId`——所以审批必须按 `seq` 走
  ///
  /// 读、写两个 `ToolCallEvent` 的 `callId` 相同（同一条 tool_use 消息只有
  /// 一个 id）。两个阶段的审批*确实*不会同时挂起等待——读的审批完成
  /// （`_pending.remove`）之后才会创建写的事件、注册写的审批——但这只保证
  /// 了「同一时刻只有一个 completer 在等」，保证不了「迟到的应答只会命中
  /// 它本该命中的那个」：用户对着读那张卡点的一次迟到点击，落地时 `_pending`
  /// 里可能已经换成了写审批的 completer，若索引用的是两者共享的 `callId`，
  /// 这次点击会把**写**批准掉。`_pending` 因此必须按 [ToolCallEvent.seq]
  /// 索引（会话内单调递增、逐张卡片唯一），[respondApproval] 也一样。
  /// 详见 `_pending` 字段上的注释与
  /// `agent_session_manager_test.dart` 里的回归测试。
  Future<ToolResult> editFile(ToolCall call,
      {bool preApproved = false, ToolMetrics? tm}) async {
    final path = call.args['path'];
    final oldS = call.args['old_string'];
    final newS = call.args['new_string'];
    if (path is! String || path.trim().isEmpty) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id,
          content: 'Invalid arguments: `path` is required.',
          isError: true);
    }
    if (oldS is! String || newS is! String) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id,
          content: 'Invalid arguments: `old_string` and `new_string` are '
              'both required and must be strings.',
          isError: true);
    }
    ctx.resetInvalidArgs();

    final servers =
        await ctx.serverListProvider?.call() ?? const <ServerListEntry>[];
    final target = resolveServerTarget(call.args['server'], servers);
    if (!target.ok) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id, content: target.error!, isError: true);
    }

    final p = path.trim();
    final cwd = target.isRemote ? null : ctx.cwdProvider?.call();
    final desc = call.args['description'];
    final rules = ctx.rulesProvider();
    final mode = ctx.modeProvider();

    // ---- 阶段一：读 ----
    final readCheck = checkReadFile(p, rules: rules, mode: mode, cwd: cwd);
    final readEv = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: target.isRemote
          ? '[${target.serverName}] read $p (to edit)'
          : 'read $p (to edit)',
      description: desc is String ? desc : '',
      check: readCheck,
      targetServerName: target.serverName,
    );
    ctx.addEvent(readEv);

    if (!preApproved && readCheck.decision == ToolDecision.needApproval) {
      // edit_file 可能等两次审批（读一次、写一次，见方法顶部 dartdoc）——
      // 两段都要计进 waitApprovalMs，用 `+=` 而不是 `=`，否则读阶段那段
      // 等待会漏计，混进最终的 execMs 里。
      final outcome = await ctx.timedAwaitApproval(readEv, tm);
      if (outcome.decision == ApprovalDecision.reject) {
        return ctx.rejectedResult(readEv, outcome);
      }
      if (outcome.decision == ApprovalDecision.addToPlan) {
        // 只有凭据命中才拒绝。
        //
        // 那一格的危害是**内容出境**：读一次就把私钥/凭据发进了模型厂商的
        // 请求体，而用户点的是「稍后再说」。这跟写阶段同一个理由，见
        // [_deferOrRejectFromApproval]。
        if (readCheck.denyHit) return ctx.rejectedResult(readEv, outcome);
        // 非凭据：**照常读下去**，不要拒绝。
        //
        // 曾经这里无条件拒绝，那是过度纠正。读卡在非凭据情形下照样会弹
        // （用户在规则页关掉了默认放行组，或路径含 shell 元字符），那时
        // 按钮写着「加入方案」、点下去却得到 rejected + 「User rejected
        // this command.」——按钮和行为相反，模型以为被拒，用户以为攒起来了，
        // 而且那个配置下 plan 模式的 `edit_file` 整条路走不通。
        //
        // 放过这次读是安全且正确的：plan 模式下非凭据路径的写阶段
        // `checkFileWrite` 必然返回 `deferToPlan`（plan 分支在 bypass 之后、
        // 凭据之下），所以**用户想要的入队会在阶段三自动发生**。读本身也是
        // 用户在这张卡上无论点哪个按钮都会授权的动作。
      }
    }

    readEv.status = ToolCallStatus.running;
    readEv.startedAt = DateTime.now();
    ctx.enterState(AgentLoopState.executing);

    final CommandOutput readOut;
    try {
      readOut = await ctx.runnerProvider(target.serverId)
          .run(buildReadForEditCommand(p), cwd: cwd);
    } catch (e, st) {
      ctx.noteToolError(st);
      ctx.finishToolCall(readEv, ToolCallStatus.failed);
      readEv.output = toolErrorForCard(e, st);
      ctx.notifyChanged();
      return ToolResult(
          callId: call.id, content: 'Could not read $p: $e', isError: true);
    }

    readEv.exitCode = readOut.exitCode;
    if (!readOut.isSuccess) {
      ctx.finishToolCall(readEv, ToolCallStatus.failed);
      readEv.output = formatForModel(readOut);
      ctx.notifyChanged();
      // 不当成「空文件」继续 —— edit_file 不负责创建，那是 write_file 的事。
      return ToolResult(
        callId: call.id,
        content: 'Could not read $p (exit ${readOut.exitCode}). '
            '${readOut.stderr.trim()}\n'
            'If the file does not exist yet, use `write_file`.',
        isError: true,
        exitCode: readOut.exitCode,
      );
    }

    final read = parseEditFileRead(readOut.stdout);
    if (read.error != null) {
      ctx.finishToolCall(readEv, ToolCallStatus.failed);
      readEv.output = read.error;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: read.error!, isError: true);
    }

    // ---- 阶段二：改（纯计算） ----
    final edit =
        applyEdit(content: read.content!, oldString: oldS, newString: newS);
    if (edit.error != null) {
      ctx.finishToolCall(readEv, ToolCallStatus.failed);
      readEv.output = edit.error;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: edit.error!, isError: true);
    }

    ctx.finishToolCall(readEv, ToolCallStatus.done);
    readEv.output = 'read ${read.content!.length} chars';
    ctx.notifyChanged();

    // 取消/关闭发生在读取执行期间时，这里是唯一能拦住写入的地方。
    //
    // 不能只靠 `_awaitApproval` 里那道闸：bypass 模式下 `checkFileWrite`
    // 返回 allow，阶段三根本不会调用它，于是「用户按了停止、UI 显示已
    // 取消，文件照样被重写」。edit_file 是第一条「一次调用做两件事、
    // 中间夹一次远端往返」的路径 —— `_run()` 的 `if (ctx.cancelRequested)
    // break` 在 `_executeOne` 返回之后才检查，拦不住调用内部的第二件事
    // （这里的写）。
    if (ctx.cancelRequested || ctx.disposed) {
      readEv.status = ToolCallStatus.rejected;
      ctx.notifyChanged();
      return ToolResult(
        callId: call.id,
        content: 'Session was cancelled before the edit was written. '
            'Nothing was written.',
        isError: true,
      );
    }

    // ---- 阶段三：审批 + 写 ----
    final writeCheck = checkFileWrite(p, rules: rules, mode: mode, cwd: cwd);
    final writeEv = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: target.isRemote
          ? '[${target.serverName}] edit $p:${edit.atLine}'
          : 'edit $p:${edit.atLine}',
      description: desc is String ? desc : '',
      check: writeCheck,
      preview: FileEditPreview(
        path: p,
        oldText: oldS,
        newText: newS,
        atLine: edit.atLine,
      ),
      targetServerName: target.serverName,
    );
    ctx.addEvent(writeEv);

    if (!preApproved) {
      if (writeCheck.decision == ToolDecision.deferToPlan) {
        return ctx.deferWrite(writeEv, call);
      }
      if (writeCheck.decision == ToolDecision.needApproval) {
        final outcome = await ctx.timedAwaitApproval(writeEv, tm);
        if (outcome.decision == ApprovalDecision.reject) {
          return ctx.rejectedResult(writeEv, outcome);
        }
        if (outcome.decision == ApprovalDecision.addToPlan) {
          return ctx.deferOrRejectFromApproval(writeEv, call, writeCheck);
        }
      }
    }

    return _runFileWrite(
      writeEv,
      buildWriteFileCommand(p, utf8.encode(edit.content!),
          expectedSha: read.sha256, seq: writeEv.seq),
      cwd,
      okMessage: 'Edited $p at line ${edit.atLine}.',
      backupPath: dotBackupPathForSeq(p, writeEv.seq),
      serverId: target.serverId,
      tm: tm,
    );
  }

  static int _lineCount(String s) => s.isEmpty ? 0 : s.split('\n').length;
}
