// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import '../../../app_control/app_control_service.dart';
import '../agent_events.dart';
import '../agent_tool_context.dart';
import '../app_permission.dart';
import '../tool_models.dart';
import '../tool_registry.dart';
import 'arg_parsing.dart';

/// app 自身控制工具的执行。
///
/// **薄转发层**：解析 args → 调 `AppControlService` → 包 `ToolResult`。
/// 所有业务判断（白名单、禁区、类型强制、记账）都在 service 里 —— 这里
/// 多写一行业务逻辑，就是在 service 之外开一条不留痕的改动路径。
class AppExecutors {
  final AgentToolContext ctx;

  AppExecutors(this.ctx);

  static const _sections = [
    'settings',
    'servers',
    'sessions',
    'tunnels',
    'keybar',
    'ui',
  ];

  Future<ToolResult> stateRead(ToolCall call) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }

    // 只读工具在 ask / bypass 档都是 allow，但仍然走判定而不是硬编码 ——
    // off 档要拒绝。正常路径下 off 档不会声明这个工具，这是第二道防线。
    final check = checkAppControl(call.name, mode: ctx.modeProvider());
    if (check.decision != ToolDecision.allow) {
      return _fail(call, 'App control is disabled in settings.');
    }

    final section = call.args['section'];
    if (section is! String || !_sections.contains(section)) {
      return _fail(call,
          'Unknown section `$section`. One of: ${_sections.join(', ')}.');
    }

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: 'read app $section',
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    final Object? payload;
    if (section == 'settings') {
      payload = svc.readSettings();
    } else if (section == 'ui') {
      payload = svc.readUiState();
    } else {
      final rows = await svc.readSection(section);
      if (rows == null) {
        // **回「不可用」而不是空列表** —— 空列表会让模型以为「真的一台
        // 服务器都没有」，然后基于这个错误前提往下推理。
        final msg = 'Section `$section` is not available in this session.';
        ctx.finishToolCall(ev, ToolCallStatus.failed);
        ev.output = msg;
        ctx.notifyChanged();
        return ToolResult(callId: call.id, content: msg, isError: true);
      }
      payload = rows;
    }

    final json = const JsonEncoder.withIndent('  ').convert(payload);
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = json;
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: json);
  }

  Future<ToolResult> settingsSet(
    ToolCall call, {
    bool preApproved = false,
  }) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }

    final key = call.args['key'];
    if (key is! String || key.isEmpty) {
      return _fail(call, missingArgMessage('key'));
    }
    if (!call.args.containsKey('value')) {
      return _fail(call, missingArgMessage('value'));
    }

    // 权限判定 —— **必须在这里做，不能硬编码 allow**。
    // app 工具在 `_executeOneInner` 的 switch 里有自己的 arm，不会落到
    // `_executeCommandTool` 的默认分支，所以 `checkCommand` 那条路不会替
    // 它判。这里不判就等于没有权限模型。
    final check = checkAppControl(call.name, mode: ctx.modeProvider());

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: 'set $key = ${call.args['value']}',
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      // 白名单式：只有 allowOnce 放行。addToPlan 对 app 工具没有意义
      // （app 侧不走提案队列），当成拒绝。
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    final r = await svc.setSetting(key, call.args['value']);

    if (!r.ok) {
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = r.error!;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: r.error!, isError: true);
    }

    final c = r.change!;
    final msg = 'Changed `${c.field}`: ${c.oldValue} → ${c.newValue}. '
        'The user can undo this.';
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = msg;
    _ensureChangeCard();
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: msg);
  }

  // ───────── 服务器条目 ─────────

  Future<ToolResult> serverEntry(
    ToolCall call, {
    bool preApproved = false,
  }) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }

    final name = call.args['name'];
    if (name is! String || name.trim().isEmpty) {
      return _fail(call, missingArgMessage('name'));
    }

    final check = checkAppControl(call.name, mode: ctx.modeProvider());
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: switch (call.name) {
        'server_entry_create' => 'add server $name',
        'server_entry_update' => 'update server $name',
        _ => 'delete server $name',
      },
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      // **白名单式**：只有 allowOnce 放行，其余（reject / addToPlan，以及
      // 将来可能新增的值）一律当拒绝。列举拒绝项的写法会让新增的 enum 值
      // 默认获得放行 —— 那是权限模型里最不该有的默认。
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    final r = switch (call.name) {
      'server_entry_create' => await svc.createServer(
          name: name.trim(),
          host: '${call.args['host'] ?? ''}',
          port: _asPort(call.args['port']) ?? 22,
          username: '${call.args['user'] ?? ''}',
          groupName: call.args['group'] as String?,
        ),
      'server_entry_update' => await svc.updateServer(
          name: name.trim(),
          host: call.args['host'] as String?,
          port: _asPort(call.args['port']),
          username: call.args['user'] as String?,
          groupName: call.args['group'] as String?,
        ),
      _ => await svc.deleteServer(name.trim()),
    };

    return _finish(call, ev, r);
  }

  // ───────── 端口转发 ─────────

  Future<ToolResult> tunnel(ToolCall call, {bool preApproved = false}) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }

    final isCreate = call.name == 'tunnel_create';
    if (isCreate) {
      for (final k in ['server', 'local_port', 'remote_host', 'remote_port']) {
        if (!call.args.containsKey(k)) {
          return _fail(call, missingArgMessage('\$k'));
        }
      }
    } else if (call.args['id'] is! String) {
      return _fail(call, missingArgMessage('id'));
    }

    final check = checkAppControl(call.name, mode: ctx.modeProvider());
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: isCreate
          ? 'forward ${call.args['local_port']} -> '
              '${call.args['remote_host']}:${call.args['remote_port']}'
          : 'close tunnel ${call.args['id']}',
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    final r = isCreate
        ? await svc.createTunnel(
            serverName: '${call.args['server']}',
            localPort: _asPort(call.args['local_port']) ?? -1,
            remoteHost: '${call.args['remote_host']}',
            remotePort: _asPort(call.args['remote_port']) ?? -1,
            direction: '${call.args['direction'] ?? 'local'}',
            label: '${call.args['label'] ?? ''}',
          )
        : await svc.closeTunnel('${call.args['id']}');

    return _finish(call, ev, r);
  }

  // ───────── 自定义按键栏 ─────────

  Future<ToolResult> keybar(ToolCall call, {bool preApproved = false}) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }

    final label = call.args['label'];
    if (label is! String || label.trim().isEmpty) {
      return _fail(call, missingArgMessage('label'));
    }
    final isAdd = call.name == 'keybar_item_add';
    if (isAdd && call.args['sequence'] is! String) {
      return _fail(call, missingArgMessage('sequence'));
    }

    final check = checkAppControl(call.name, mode: ctx.modeProvider());
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: isAdd ? 'add key "$label"' : 'remove key "$label"',
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    final r = isAdd
        ? await svc.addKeybarItem(
            label: label.trim(),
            sequence: call.args['sequence'] as String,
            sticky: call.args['sticky'] == true,
            repeatable: call.args['repeatable'] == true,
          )
        : await svc.removeKeybarItem(label.trim());

    return _finish(call, ev, r);
  }

  // ───────── 会话与布局 ─────────

  Future<ToolResult> session(ToolCall call, {bool preApproved = false}) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }

    final isOpen = call.name == 'session_open';
    int? index;
    if (isOpen) {
      if (call.args['server'] is! String) {
        return _fail(call, missingArgMessage('server'));
      }
    } else {
      index = _asPort(call.args['index']);
      if (index == null) {
        return _fail(call, 'Missing or invalid argument `index`.');
      }
    }

    // session_close 的不可逆性是**条件性**的：有活跃连接才不可逆（远端进程
    // 关了就没了），没连上的 tab 关掉重开即可。所以这里显式告诉判定函数
    // 该不该按硬清单对待，而不是让它只看工具名。
    final check = checkAppControl(
      call.name,
      mode: ctx.modeProvider(),
      hardApproval: isOpen ? null : svc.sessionHasLiveConnection(index!),
    );

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: isOpen
          ? 'open session on ${call.args['server']}'
          : 'close session #$index',
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    final r = isOpen
        ? await svc.openSession(
            serverName: '${call.args['server']}',
            command: call.args['command'] as String?,
          )
        : await svc.closeSession(index!);

    return _finish(call, ev, r);
  }

  Future<ToolResult> layoutSet(ToolCall call,
      {bool preApproved = false}) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }
    final mode = call.args['mode'];
    if (mode is! String) {
      return _fail(call, missingArgMessage('mode'));
    }

    final check = checkAppControl(call.name, mode: ctx.modeProvider());
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: 'layout: $mode',
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    return _finish(call, ev, svc.setLayout(mode));
  }

  // ───────── 技能自管理 / 已信任主机 ─────────

  /// 这两组共用一个入口：形状一致（一个只读 list + 若干按名字操作的写），
  /// 分开写会是两份只有工具名不同的代码。
  Future<ToolResult> manage(ToolCall call, {bool preApproved = false}) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }

    final isList = call.name == 'skill_list' || call.name == 'known_host_list';
    final check = checkAppControl(call.name, mode: ctx.modeProvider());

    if (isList) {
      if (check.decision != ToolDecision.allow) {
        return _fail(call, 'App control is disabled in settings.');
      }
      final rows = call.name == 'skill_list'
          ? svc.listSkills()
          : await svc.listKnownHosts();
      if (rows == null) {
        return _fail(call, '${call.name} is not available in this session.');
      }
      final ev = ToolCallEvent(
        seq: ctx.nextSeq(),
        callId: call.id,
        toolName: call.name,
        displayCommand:
            call.name == 'skill_list' ? 'list skills' : 'list trusted hosts',
        description: '',
        check: check,
      );
      ctx.addEvent(ev);
      final json = const JsonEncoder.withIndent('  ').convert(rows);
      ctx.finishToolCall(ev, ToolCallStatus.done);
      ev.output = json;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: json);
    }

    // ── 写操作 ──
    final isHost = call.name == 'known_host_forget';
    final nameArg = isHost ? call.args['host'] : call.args['name'];
    if (nameArg is! String || nameArg.trim().isEmpty) {
      return _fail(
          call, missingArgMessage(isHost ? 'host' : 'name'));
    }

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: switch (call.name) {
        'skill_delete' => 'delete skill "$nameArg"',
        'skill_set_enabled' =>
          '${call.args['enabled'] == false ? 'disable' : 'enable'} skill "$nameArg"',
        'skill_update' => 'update skill "$nameArg"',
        _ => 'forget host $nameArg',
      },
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    final r = switch (call.name) {
      'skill_delete' => await svc.deleteSkill(nameArg.trim()),
      'skill_set_enabled' => await svc.setSkillEnabled(
          nameArg.trim(), call.args['enabled'] != false),
      'skill_update' => await svc.updateSkill(
          nameArg.trim(),
          description: call.args['description'] as String?,
          body: call.args['body'] as String?,
        ),
      _ => await svc.forgetKnownHost(
          host: nameArg.trim(),
          port: _asPort(call.args['port']) ?? 22,
          keyType: '${call.args['key_type'] ?? ''}',
        ),
    };

    return _finish(call, ev, r);
  }

  // ───────── 快捷命令 ─────────

  Future<ToolResult> savedCommand(ToolCall call,
      {bool preApproved = false}) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }

    if (call.name == 'saved_command_list') {
      final check = checkAppControl(call.name, mode: ctx.modeProvider());
      if (check.decision != ToolDecision.allow) {
        return _fail(call, 'App control is disabled in settings.');
      }
      final rows = svc.listCommands();
      if (rows == null) {
        return _fail(call, 'Saved commands are not available in this session.');
      }
      final ev = ToolCallEvent(
        seq: ctx.nextSeq(),
        callId: call.id,
        toolName: call.name,
        displayCommand: 'list saved commands',
        description: '',
        check: check,
      );
      ctx.addEvent(ev);
      final json = const JsonEncoder.withIndent('  ').convert(rows);
      ctx.finishToolCall(ev, ToolCallStatus.done);
      ev.output = json;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: json);
    }

    final name = call.args['name'];
    if (name is! String || name.trim().isEmpty) {
      return _fail(call, missingArgMessage('name'));
    }
    final isCreate = call.name == 'saved_command_create';
    if (isCreate && call.args['command'] is! String) {
      return _fail(call, missingArgMessage('command'));
    }

    final check = checkAppControl(call.name, mode: ctx.modeProvider());
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand:
          isCreate ? 'save command "$name"' : 'delete command "$name"',
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    final r = isCreate
        ? await svc.saveCommand(
            name: name.trim(),
            command: call.args['command'] as String,
          )
        : await svc.deleteCommand(name.trim());

    return _finish(call, ev, r);
  }

  // ───────── 界面导航 ─────────

  Future<ToolResult> navigate(ToolCall call,
      {bool preApproved = false}) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }
    final target = call.args['target'];
    if (target is! String || target.trim().isEmpty) {
      return _fail(call, missingArgMessage('target'));
    }

    final check = checkAppControl(call.name, mode: ctx.modeProvider());
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: 'open $target',
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    final r = svc.navigateTo(target.trim());
    if (!r.ok) {
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = r.error!;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: r.error!, isError: true);
    }

    // **不走 _finish** —— 导航不进撤销栈，r.change 是 null。
    final msg = 'Opened `${target.trim()}`.';
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = msg;
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: msg);
  }

  // ───────── SSH 密钥 ─────────

  Future<ToolResult> sshKey(ToolCall call, {bool preApproved = false}) async {
    final svc = ctx.appControl;
    if (svc == null) {
      return _fail(call, 'App control is not available in this session.');
    }

    if (call.name == 'ssh_key_list') {
      final check = checkAppControl(call.name, mode: ctx.modeProvider());
      if (check.decision != ToolDecision.allow) {
        return _fail(call, 'App control is disabled in settings.');
      }
      final rows = await svc.listSshKeys();
      if (rows == null) {
        return _fail(call, 'Key management is not available in this session.');
      }
      final ev = ToolCallEvent(
        seq: ctx.nextSeq(),
        callId: call.id,
        toolName: call.name,
        displayCommand: 'list SSH keys',
        description: '',
        check: check,
      );
      ctx.addEvent(ev);
      final json = const JsonEncoder.withIndent('  ').convert(rows);
      ctx.finishToolCall(ev, ToolCallStatus.done);
      ev.output = json;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: json);
    }

    final name = call.args['name'];
    if (name is! String || name.trim().isEmpty) {
      return _fail(call, missingArgMessage('name'));
    }
    final type = '${call.args['type'] ?? 'ed25519'}';

    final check = checkAppControl(call.name, mode: ctx.modeProvider());
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: 'generate $type key "$name"',
      description: '',
      check: check,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.awaitApproval(ev);
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    final r = await svc.generateSshKey(name: name.trim(), type: type);
    if (!r.ok) return _finish(call, ev, r);

    // 成功时**额外把公钥回给模型** —— 它要念给用户去贴到服务器的
    // authorized_keys 里，这正是这个工具存在的意义。私钥不在其中。
    final rows = await svc.listSshKeys();
    final pub = rows
            ?.where((k) => k['name'] == name.trim())
            .map((k) => k['public_key'])
            .firstOrNull ??
        '';
    final msg = 'Generated $type key `${name.trim()}`. '
        'Public key (add this to the server\'s ~/.ssh/authorized_keys):\n$pub';
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = msg;
    _ensureChangeCard();
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: msg);
  }

  /// 端口宽进：模型常把数字回成字符串。解析不了回 null，由 service 层
  /// 的范围校验给出明确错误 —— 这里不静默兜底成 22。
  int? _asPort(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// 把 [AppSetResult] 收尾成 [ToolResult] 并打卡片终态。
  ToolResult _finish(ToolCall call, ToolCallEvent ev, AppSetResult r) {
    if (!r.ok) {
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = r.error!;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: r.error!, isError: true);
    }
    final c = r.change!;
    final msg = c.newValue == null
        ? 'Removed `${c.field}`. The user can undo this.'
        : 'Changed `${c.field}`: ${c.oldValue} → ${c.newValue}. '
            'The user can undo this.';
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = msg;
    _ensureChangeCard();
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: msg);
  }

  /// 保证事件流里有一张对应当前批次的卡，**且只有一张**。
  ///
  /// 同一轮里改三项设置应该是一张列出三行的卡，不是三张卡 —— 卡的单位是
  /// 批次，而批次的单位是一轮 agent 运行（`AgentLoop` 在每次 run 开始时调
  /// `startBatch()`）。
  void _ensureChangeCard() {
    final batch = ctx.appControl?.changeLog.currentBatch;
    if (batch == null) return;
    for (final e in ctx.events) {
      if (e is AppChangeEvent && e.batchId == batch.id) return;
    }
    ctx.addEvent(AppChangeEvent(batch.id));
  }

  /// 参数非法时的早退 —— **不发事件卡**。
  ///
  /// 与 `more_tools` 对未知组名的处理同理：这类失败是模型的参数问题，没有
  /// 实际执行发生，发一张卡只会让面板多一条噪音。
  ToolResult _fail(ToolCall call, String msg) => ctx.failToolBare(call, msg);
}
