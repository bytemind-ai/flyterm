// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:uuid/uuid.dart';

import '../data/keybar_config.dart';
import '../data/keybar_settings.dart';
import '../data/models/server.dart';
import '../ai/agent/agent_skill_manager.dart';
import '../ai/agent/ai_command_manager.dart';
import '../ai/agent/server_notes_manager.dart';
import '../ai/agent/skill.dart';
import '../data/models/favorite_command.dart';
import '../data/models/ssh_key.dart';
import '../data/repositories/favorite_command_repository.dart';
import '../data/repositories/known_host_repository.dart';
import '../data/repositories/server_repository.dart';
import '../data/repositories/ssh_key_repository.dart';
import '../data/secure_storage.dart';
import '../data/terminal_settings.dart';
import '../ssh/key_service.dart';
import '../ssh/session_manager.dart';
import '../tunnel/tunnel_entry.dart';
import '../tunnel/tunnel_manager.dart';
import '../ui/terminal/split_manager.dart';
import '../ui/terminal/terminal_themes.dart' show AppTerminalTheme;
import 'app_change.dart';
import 'app_change_log.dart';
import 'key_sequence_parser.dart';
import 'writable_settings.dart';

/// 一次写操作的结果。
///
/// **返回结果对象而不是抛异常**：调用方是 agent executor，它要把失败原因
/// 原样回给模型，异常栈对模型毫无价值而结构化的 [error] 可以直接当工具输出。
class AppSetResult {
  final bool ok;

  /// 给模型看的失败说明（英文 —— 它进的是 prompt，不是 UI）。
  final String? error;

  final AppChange? change;

  const AppSetResult.success(this.change)
      : ok = true,
        error = null;

  const AppSetResult.failure(this.error)
      : ok = false,
        change = null;
}

/// app 自身控制的唯一门面。
///
/// ## 为什么是门面而不是让 executor 直接读写 provider
///
/// 撤销栈必须集中。若十几个 executor 各自读写 provider、各自记日志，「撤销」
/// 的语义会随工具数量增长而腐坏 —— 某个新工具忘了记旧值，整批回滚就缺一块，
/// 而这种缺失在类型层面完全合法。门面把「改动必须留痕」变成结构性保证。
///
/// ## 边界
///
/// 不依赖 agent，不依赖 BuildContext。导航一类必须触到 UI 的能力走回调注入，
/// 照搬 `AgentSessionManager.onApprovalPending` 的模式 —— service 不认识
/// Navigator。
class AppControlService {
  final TerminalSettings settings;
  final AppChangeLog changeLog;

  /// 下面四个都是**可空**的。
  ///
  /// null 时对应的 `app_state_read` 分区回「这个会话里不可用」，其余功能
  /// 照常。做成可空是为了让只关心设置读写的测试不必构造一整棵依赖树 ——
  /// 与 `AgentAssemblyDeps.settings` 的处理同理。
  final ServerRepository? servers;
  final SessionManager? sessions;
  final TunnelManager? tunnels;
  final KeybarSettings? keybar;
  final SplitManager? layout;
  final SSHKeyRepository? keys;
  final FavoriteCommandRepository? commands;
  final AgentSkillManager? skills;
  final KnownHostRepository? knownHosts;
  final AiCommandManager? commandManager;

  /// 删服务器时同步清掉它的机器笔记内存缓存（C1）。可空，与上面几个字段
  /// 同一套「可选依赖」模式——只关心别的分区的测试不必装配它。
  ///
  /// **这个字段要在生产环境生效，还需要 `main.dart` 构造 [AppControlService]
  /// 时把它已有的 `serverNotesManager` 局部变量传进来**（一行
  /// `serverNotes: serverNotesManager,`）。main.dart 不在本轮改动范围内，
  /// 这里先把注入点开好——没传时 [deleteServer] 的 `serverNotes?.delete`
  /// 只是安全地空跑，不会报错，但也不会真的同步缓存。
  final ServerNotesManager? serverNotes;

  /// 只给 `TunnelManager.addTunnelForServer` 用 —— 它要靠这个取登录凭据来
  /// 建 SSH 通道。**service 自己不读写任何凭据**，只是把句柄递过去。
  final SecureStorageService? storage;

  AppControlService({
    required this.settings,
    AppChangeLog? changeLog,
    this.servers,
    this.sessions,
    this.tunnels,
    this.keybar,
    this.layout,
    this.keys,
    this.commands,
    this.commandManager,
    this.skills,
    this.knownHosts,
    this.storage,
    this.serverNotes,
  }) : changeLog = changeLog ?? AppChangeLog();

  // ───────── 端口转发 ─────────

  /// 开一条端口转发。
  ///
  /// **`undo` 恒为 null —— 这是设计，不是遗漏。** `stopTunnel` 能把端口关
  /// 掉，但关掉 ≠ 撤销：端口已经对外开放过一段时间，那段暴露收不回来。
  /// 所以它走硬清单前置确认（`kAppHardApproval`），而不是事后可撤。
  /// `app_permission_test` 里有一条断言钉死它在 bypass 档也要审批。
  Future<AppSetResult> createTunnel({
    required String serverName,
    required int localPort,
    required String remoteHost,
    required int remotePort,
    String direction = 'local',
    String label = '',
  }) async {
    final mgr = tunnels;
    final store = storage;
    if (mgr == null || store == null) {
      return const AppSetResult.failure(
          'Port forwarding is not available in this session.');
    }
    final server = await _serverByName(serverName);
    if (server == null) {
      return AppSetResult.failure('No server named `$serverName`.');
    }
    for (final p in [localPort, remotePort]) {
      if (p < 1 || p > 65535) {
        return AppSetResult.failure('Ports must be 1–65535, got $p.');
      }
    }
    final dir = TunnelDirection.values
        .where((d) => d.name == direction)
        .firstOrNull;
    if (dir == null) {
      return AppSetResult.failure(
          'Direction must be one of: '
          '${TunnelDirection.values.map((d) => d.name).join(', ')}.');
    }
    if (mgr.tunnels.any((t) => t.localPort == localPort)) {
      return AppSetResult.failure(
          'Local port $localPort is already used by another tunnel.');
    }

    final entry = await mgr.addTunnelForServer(
      server: server,
      storage: store,
      direction: dir,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      label: label,
    );

    final change = AppChange(
      toolName: 'tunnel_create',
      field: 'tunnel:$localPort',
      oldValue: null,
      newValue: '$localPort → $remoteHost:$remotePort',
      undo: null, // 不可逆，见方法文档
    );
    changeLog.record(change);

    if (entry.status == TunnelStatus.error) {
      return AppSetResult.failure(
          'Tunnel failed to start: ${entry.errorMessage ?? 'unknown error'}');
    }
    return AppSetResult.success(change);
  }

  /// 关一条端口转发。可逆性同样为 null —— 重开是「新开一条」，不是「撤销」。
  Future<AppSetResult> closeTunnel(String id) async {
    final mgr = tunnels;
    if (mgr == null) {
      return const AppSetResult.failure(
          'Port forwarding is not available in this session.');
    }
    final hit = mgr.tunnels.where((t) => t.id == id).firstOrNull;
    if (hit == null) {
      return AppSetResult.failure('No tunnel with id `$id`.');
    }
    await mgr.stopTunnel(id);

    final change = AppChange(
      toolName: 'tunnel_close',
      field: 'tunnel:${hit.localPort}',
      oldValue: '${hit.localPort} → ${hit.remoteHost}:${hit.remotePort}',
      newValue: null,
      undo: null,
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  // ───────── 会话与布局 ─────────

  /// 由 UI 层注入 —— **service 不认识 Navigator**。
  ///
  /// `session_open` 在后台建好 tab 之后调它，让宿主有机会显示一张「已就绪，
  /// 点击进入」的提示。照搬 `AgentSessionManager.onApprovalPending` 的模式：
  /// 这一层只发出「有这么个事」，怎么呈现由 UI 决定。
  void Function(String tabId)? onSessionReady;

  /// 在后台开一个会话。**不切焦点**，见 [SessionManager.addTab] 的 activate。
  ///
  /// [command] 只预填进输入行、**不执行** —— 这是「替我往终端送命令」这档
  /// 最高风险能力的安全形态：AI 写，人按回车。
  Future<AppSetResult> openSession({
    required String serverName,
    String? command,
  }) async {
    final mgr = sessions;
    if (mgr == null) {
      return const AppSetResult.failure('Sessions are not available.');
    }
    final server = await _serverByName(serverName);
    if (server == null) {
      return AppSetResult.failure('No server named `$serverName`.');
    }

    final before = mgr.activeIndex;
    final tab = mgr.addTab(server, activate: false);
    if (command != null && command.trim().isNotEmpty) {
      mgr.stageCommand(server.id, command.trim());
    }
    onSessionReady?.call(tab.id);

    final change = AppChange(
      toolName: 'session_open',
      field: 'session:$serverName',
      oldValue: null,
      newValue: serverName,
      // 撤销 = 关掉这个 tab 并把焦点还原。新开的 tab 还没跑过任何东西，
      // 关掉它不丢数据。
      undo: () async {
        final idx = mgr.tabs.indexWhere((t) => t.id == tab.id);
        if (idx >= 0) mgr.closeTab(idx);
        if (before < mgr.tabs.length) mgr.setActiveTab(before);
      },
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 这个 tab 背后有没有活着的连接。
  ///
  /// `session_close` 的硬清单判据与 `app_state_read` 的 `connected` 字段
  /// **必须同源** —— 否则会出现「状态里说没连，关的时候却弹审批」。
  bool sessionHasLiveConnection(int index) {
    final mgr = sessions;
    if (mgr == null) return false;
    if (index < 0 || index >= mgr.tabs.length) return false;
    return mgr.tabs[index].transport != null;
  }

  /// 关一个会话。
  ///
  /// **不可撤销**：关掉的 SSH 连接恢复不了（远端进程已没），重开是「新开
  /// 一个」而不是「撤销」。有活跃连接时它还会走硬清单前置确认。
  Future<AppSetResult> closeSession(int index) async {
    final mgr = sessions;
    if (mgr == null) {
      return const AppSetResult.failure('Sessions are not available.');
    }
    if (index < 0 || index >= mgr.tabs.length) {
      return AppSetResult.failure(
          'No session at index $index. There are ${mgr.tabs.length}.');
    }
    final name = mgr.tabs[index].server.name;
    mgr.closeTab(index);

    final change = AppChange(
      toolName: 'session_close',
      field: 'session:$name',
      oldValue: name,
      newValue: null,
      undo: null,
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 切分屏布局。
  ///
  /// 只接受 off / horizontal / vertical —— 浮动窗口要绑定一个具体的
  /// `SessionTab` 并涉及位置/尺寸状态，那是另一件事，不塞进这个工具。
  AppSetResult setLayout(String mode) {
    final split = layout;
    if (split == null) {
      return const AppSetResult.failure('Layout control is not available.');
    }
    final target =
        SplitMode.values.where((m) => m.name == mode).firstOrNull;
    if (target == null) {
      return AppSetResult.failure(
          'Layout must be one of: ${SplitMode.values.map((m) => m.name).join(', ')}.');
    }
    final before = split.splitMode;
    if (before == target) {
      return AppSetResult.failure('Layout is already `$mode`.');
    }
    split.setSplitMode(target);

    final change = AppChange(
      toolName: 'layout_set',
      field: 'layout',
      oldValue: before.name,
      newValue: target.name,
      undo: () async => split.setSplitMode(before),
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  // ───────── 技能自管理 ─────────

  /// 列出全部技能，**含被挤出索引的和已禁用的**。
  ///
  /// 这是整组工具存在的理由：只有 enabled 且在 `kMaxIndexedSkills` 以内的
  /// 技能才进 system prompt，超出的静默沉底 —— AI 不知道它们存在，也就
  /// 无从清理。而 AI 自己正是那个一直在 `save_skill` 往里加的人。
  ///
  /// `hit_count` / `last_used` 一并给出：系统早就在记录使用情况，不给模型
  /// 看的话它只能靠名字猜哪个该删。
  List<Map<String, Object?>>? listSkills() {
    final mgr = skills;
    if (mgr == null) return null;
    final indexed = mgr.indexEntries.map((e) => e.name).toSet();
    return [
      for (final sk in mgr.skills)
        {
          'name': sk.name,
          'description': sk.description,
          'enabled': sk.enabled,
          'source': sk.source.name,
          'hit_count': sk.hitCount,
          if (sk.lastUsedAt != null)
            'last_used': sk.lastUsedAt!.toIso8601String().split('T').first,
          // 关键的一列：false = 存着但进不了 prompt，等于失效。
          'in_prompt': indexed.contains(sk.name),
        }
    ];
  }

  AgentSkill? _skillByName(String name) {
    final mgr = skills;
    if (mgr == null) return null;
    final key = name.trim().toLowerCase();
    for (final sk in mgr.skills) {
      if (sk.name.toLowerCase() == key) return sk;
    }
    return null;
  }

  /// 删一条技能。可撤销 —— 正文存在闭包里原样写回。
  Future<AppSetResult> deleteSkill(String name) async {
    final mgr = skills;
    if (mgr == null) {
      return const AppSetResult.failure('Skills are not available.');
    }
    final sk = _skillByName(name);
    if (sk == null) {
      return AppSetResult.failure('No skill named `$name`.');
    }
    await mgr.delete(sk.id);

    final change = AppChange(
      toolName: 'skill_delete',
      field: 'skill:${sk.name}',
      oldValue: sk.description,
      newValue: null,
      // 用 save 写回而不是 insert：id 会变，但技能靠名字引用，不靠 id。
      undo: () => mgr.save(
        name: sk.name,
        description: sk.description,
        body: sk.body,
        source: sk.source,
      ),
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 启用/禁用一条技能。禁用的不进 prompt，但留在库里。
  Future<AppSetResult> setSkillEnabled(String name, bool enabled) async {
    final mgr = skills;
    if (mgr == null) {
      return const AppSetResult.failure('Skills are not available.');
    }
    final sk = _skillByName(name);
    if (sk == null) {
      return AppSetResult.failure('No skill named `$name`.');
    }
    if (sk.enabled == enabled) {
      return AppSetResult.failure(
          'Skill `${sk.name}` is already ${enabled ? 'enabled' : 'disabled'}.');
    }
    await mgr.setEnabled(sk.id, enabled);

    final change = AppChange(
      toolName: 'skill_set_enabled',
      field: 'skill:${sk.name}',
      oldValue: sk.enabled,
      newValue: enabled,
      undo: () => mgr.setEnabled(sk.id, sk.enabled),
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 改技能的描述或正文。
  ///
  /// 描述尤其值得让 AI 改：它是唯一进 prompt 的部分，写得准不准直接决定
  /// 这条技能会不会在该用的时候被想起来。
  Future<AppSetResult> updateSkill(
    String name, {
    String? description,
    String? body,
  }) async {
    final mgr = skills;
    if (mgr == null) {
      return const AppSetResult.failure('Skills are not available.');
    }
    if (description == null && body == null) {
      return const AppSetResult.failure(
          'Pass at least one of `description` or `body`.');
    }
    final sk = _skillByName(name);
    if (sk == null) {
      return AppSetResult.failure('No skill named `$name`.');
    }
    await mgr.updateFields(sk.id, description: description, body: body);

    final change = AppChange(
      toolName: 'skill_update',
      field: 'skill:${sk.name}',
      oldValue: sk.description,
      newValue: description ?? sk.description,
      undo: () =>
          mgr.updateFields(sk.id, description: sk.description, body: sk.body),
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  // ───────── 已信任主机 ─────────

  /// 列出已信任的主机密钥。
  ///
  /// 「为什么连不上 X」的常见根因就是主机密钥变了，而这份清单是判断依据。
  Future<List<Map<String, Object?>>?> listKnownHosts() async {
    final repo = knownHosts;
    if (repo == null) return null;
    final all = await repo.findAll();
    return [
      for (final h in all)
        {
          'host': h.host,
          'port': h.port,
          'key_type': h.keyType,
          'fingerprint': h.fingerprintMd5,
          'last_seen': h.lastSeen.toIso8601String().split('T').first,
        }
    ];
  }

  /// 忘记一台主机的密钥。下次连接会重新要求用户确认指纹。
  ///
  /// **不可撤销**：撤销意味着把一个指纹重新标成「可信」，而那条信任本该
  /// 由用户在看到指纹后亲自给出。自动恢复它等于替用户做了信任决定。
  Future<AppSetResult> forgetKnownHost({
    required String host,
    int port = 22,
    required String keyType,
  }) async {
    final repo = knownHosts;
    if (repo == null) {
      return const AppSetResult.failure('Known hosts are not available.');
    }
    final hit = await repo.find(host: host, port: port, keyType: keyType);
    if (hit == null) {
      return AppSetResult.failure(
          'No trusted key for $host:$port ($keyType).');
    }
    await repo.delete(host: host, port: port, keyType: keyType);

    final change = AppChange(
      toolName: 'known_host_forget',
      field: 'host:$host:$port',
      oldValue: hit.fingerprintMd5,
      newValue: null,
      undo: null, // 见方法文档
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  // ───────── 快捷命令 ─────────

  /// 存一条快捷命令。
  ///
  /// `aiEnabled` 固定 true：这条是 AI 自己存的，它存的目的就是以后自己能
  /// 用 `run_saved_command` 调起来。用户想把它从 AI 的可见范围里摘掉，去
  /// 收藏命令的管理界面改。
  Future<AppSetResult> saveCommand({
    required String name,
    required String command,
  }) async {
    final repo = commands;
    final mgr = commandManager;
    if (repo == null || mgr == null) {
      return const AppSetResult.failure('Saved commands are not available.');
    }
    if (name.trim().isEmpty || command.trim().isEmpty) {
      return const AppSetResult.failure(
          '`name` and `command` must both be non-empty.');
    }
    if (mgr.byName(name.trim()) != null) {
      return AppSetResult.failure(
          'A saved command named `$name` already exists.');
    }

    // **显式 aiEnabled: true** —— `FavoriteCommand.create` 默认 false，
    // 而 AiCommandManager 只把 aiEnabled 的条目放进 _exposed。用 create
    // 的话这条命令存进去了却立刻被 run_saved_command 判为「找不到」，
    // 是个只在跨层调用时才暴露的静默失败。
    final cmd = FavoriteCommand(
      id: const Uuid().v4(),
      name: name.trim(),
      command: command.trim(),
      aiEnabled: true,
    );
    await repo.insert(cmd);
    await mgr.reload();

    final change = AppChange(
      toolName: 'saved_command_create',
      field: 'command:${cmd.name}',
      oldValue: null,
      newValue: cmd.command,
      undo: () async {
        await repo.delete(cmd.id);
        await mgr.reload();
      },
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 按名字删一条快捷命令。可撤销 —— 整条存在闭包里原样写回。
  Future<AppSetResult> deleteCommand(String name) async {
    final repo = commands;
    final mgr = commandManager;
    if (repo == null || mgr == null) {
      return const AppSetResult.failure('Saved commands are not available.');
    }
    final hit = mgr.byName(name.trim());
    if (hit == null) {
      return AppSetResult.failure('No saved command named `$name`.');
    }
    await repo.delete(hit.id);
    await mgr.reload();

    final change = AppChange(
      toolName: 'saved_command_delete',
      field: 'command:${hit.name}',
      oldValue: hit.command,
      newValue: null,
      undo: () async {
        await repo.insert(hit);
        await mgr.reload();
      },
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 列出全部快捷命令。
  List<Map<String, Object?>>? listCommands() {
    final mgr = commandManager;
    if (mgr == null) return null;
    return [
      for (final c in mgr.indexEntries)
        {'name': c.name, 'command': c.command, 'ai_enabled': c.aiEnabled}
    ];
  }

  // ───────── 界面导航 ─────────

  /// 由 UI 层注入 —— **service 不认识 Navigator**，照搬
  /// `AgentSessionManager.onApprovalPending` 的模式。
  ///
  /// 实现侧负责把 target 翻译成「切 tab」还是「push 路由」，那是 shell 的
  /// 知识，不该漏进这一层。
  void Function(String target)? onNavigate;

  /// 当前界面位置，UI 层注入。null = 宿主没提供（测试或非 shell 环境）。
  String Function()? currentLocationProvider;

  /// AI 可以把用户带到的地方。
  ///
  /// **这张表是 service 与 UI 的契约**：这里列出的每一项，UI 侧的
  /// `onNavigate` 实现都必须认得。`app_control_navigation_test` 里有一条
  /// 断言锚定两边不漂移 —— 漏实现一项的后果是「AI 说带你过去，然后什么
  /// 都没发生」，比报错更难查。
  static const navigationTargets = <String, String>{
    'ai': 'AI 对话',
    'servers': '服务器列表',
    'settings': '设置',
    'ssh_keys': 'SSH 密钥管理',
    'ai_providers': 'AI 服务商配置',
    'agent_settings': 'AI Agent 设置（含 app 控制开关）',
    'tunnels': '端口转发列表',
    'keybar': '按键栏编辑',
    'known_hosts': '已信任主机',
  };

  /// 把用户带到某个界面。
  ///
  /// **不进撤销栈** —— 导航不是状态变更，「撤销导航」没有意义（用户按返回
  /// 键就回来了）。它走权限档：ask 档弹确认（= 产品上「建议 + 用户点击」），
  /// bypass 档直接跳。
  AppSetResult navigateTo(String target) {
    if (!navigationTargets.containsKey(target)) {
      return AppSetResult.failure(
        'Unknown destination `$target`. One of: '
        '${navigationTargets.keys.join(', ')}.',
      );
    }
    final nav = onNavigate;
    if (nav == null) {
      return const AppSetResult.failure(
          'Navigation is not available in this session.');
    }
    nav(target);
    return const AppSetResult.success(null);
  }

  /// 当前界面位置 + 可去的地方。给 `app_state_read('ui')`。
  Map<String, Object?> readUiState() => {
        'current': currentLocationProvider?.call() ?? 'unknown',
        'can_navigate_to': navigationTargets.keys.toList(),
      };

  // ───────── SSH 密钥 ─────────

  /// 生成一对 SSH 密钥。
  ///
  /// ## 私钥永不出 keystore
  ///
  /// 生成出来的 PEM 直接写进 [SecureStorageService]，**不进返回值、不进
  /// `AppChange`、不进任何回给模型的字符串**。模型拿到的只有公钥和名字。
  ///
  /// 这条边界补上的是整套 app 控制里唯一一条必断的链：`server_entry_create`
  /// 不收凭据（对的），于是「帮我把这台机器加进来」走到配密钥这一步就断了。
  /// 现在 AI 可以生成密钥、把公钥念给用户去贴到服务器上，再把条目指向它 ——
  /// 全程私钥不经过模型。
  Future<AppSetResult> generateSshKey({
    required String name,
    String type = 'ed25519',
  }) async {
    final repo = keys;
    final store = storage;
    if (repo == null || store == null) {
      return const AppSetResult.failure('Key management is not available.');
    }
    if (name.trim().isEmpty) {
      return const AppSetResult.failure('`name` must not be empty.');
    }
    final all = await repo.findAll();
    if (all.any((k) => k.name == name.trim())) {
      return AppSetResult.failure('A key named `$name` already exists.');
    }
    if (type != 'ed25519' && type != 'rsa') {
      return AppSetResult.failure(
          'Key type must be `ed25519` or `rsa`, got `$type`.');
    }

    final result = type == 'rsa'
        ? await KeyService.generateRSA()
        : await KeyService.generateEd25519();

    final id = const Uuid().v4();
    final key = SSHKey(
      id: id,
      name: name.trim(),
      type: type,
      publicKey: result.publicKeyOpenSSH,
    );
    await repo.insert(key);
    await store.savePrivateKey(id, result.privateKeyPem);

    final change = AppChange(
      toolName: 'ssh_key_generate',
      field: 'key:${key.name}',
      oldValue: null,
      // **只记公钥**，与回给模型的内容一致 —— AppChange 会被渲染进卡片。
      newValue: type,
      undo: () async {
        await repo.delete(id);
        await store.deletePrivateKey(id);
      },
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 列出已有密钥。**只给名字、类型、公钥** —— 私钥没有任何读取路径。
  Future<List<Map<String, Object?>>?> listSshKeys() async {
    final repo = keys;
    if (repo == null) return null;
    final all = await repo.findAll();
    return [
      for (final k in all)
        {'name': k.name, 'type': k.type, 'public_key': k.publicKey}
    ];
  }

  // ───────── 自定义按键栏 ─────────

  /// 往键栏加一个按钮。
  ///
  /// [sequence] 是方括号占位符字符串（见 `key_sequence_parser.dart`），
  /// 不是嵌套 JSON —— KeyToken 是 sealed 层级，让模型构造嵌套结构既费
  /// token 又容易写坏。
  Future<AppSetResult> addKeybarItem({
    required String label,
    required String sequence,
    bool sticky = false,
    bool repeatable = false,
  }) async {
    final kb = keybar;
    if (kb == null) {
      return const AppSetResult.failure('Key bar is not available.');
    }
    if (label.trim().isEmpty) {
      return const AppSetResult.failure('`label` must not be empty.');
    }
    if (kb.items.any((i) => i.label == label.trim())) {
      return AppSetResult.failure('A key labelled `$label` already exists.');
    }

    final List<KeyToken> tokens;
    try {
      tokens = parseKeySequence(sequence);
    } on KeySequenceParseError catch (e) {
      return AppSetResult.failure(e.message);
    }

    final item = KeyBarItem(
      id: const Uuid().v4(),
      label: label.trim(),
      sequence: tokens,
      sticky: sticky,
      repeatable: repeatable,
    );
    await kb.add(item);

    final change = AppChange(
      toolName: 'keybar_item_add',
      field: 'key:${item.label}',
      oldValue: null,
      newValue: item.label,
      undo: () => kb.remove(item.id),
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 按 label 删一个键栏按钮。可撤销 —— 整个 [KeyBarItem] 存在闭包里。
  Future<AppSetResult> removeKeybarItem(String label) async {
    final kb = keybar;
    if (kb == null) {
      return const AppSetResult.failure('Key bar is not available.');
    }
    final hit = kb.items.where((i) => i.label == label.trim()).firstOrNull;
    if (hit == null) {
      return AppSetResult.failure('No key labelled `$label`.');
    }
    await kb.remove(hit.id);

    final change = AppChange(
      toolName: 'keybar_item_remove',
      field: 'key:${hit.label}',
      oldValue: hit.label,
      newValue: null,
      undo: () => kb.add(hit),
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 读一个非 settings 分区。
  ///
  /// 返回 null = 这个分区的依赖没注入。调用方据此回一句明确的「不可用」，
  /// 而不是回一个空列表 —— 空列表会让模型以为「真的一台服务器都没有」。
  Future<List<Map<String, Object?>>?> readSection(String section) async {
    switch (section) {
      case 'servers':
        final repo = servers;
        if (repo == null) return null;
        final all = await repo.findAll();
        // **不含 creds_ok**，那是 `list_servers` 的职责（它要为「挑一台来跑
        // 命令」服务，必须预告连不上的机器）。这里的用途是「看看有哪些条目」
        // ——为 server_entry_update / delete 定位目标，查 keystore 不值得。
        return [
          for (final s in all)
            {
              'name': s.name,
              'host': s.host,
              'port': s.port,
              'user': s.username,
              if (s.groupName != null && s.groupName!.isNotEmpty)
                'group': s.groupName,
            }
        ];

      case 'sessions':
        final mgr = sessions;
        if (mgr == null) return null;
        // 只给标识和连接态，**不给 scrollback** —— 那是 read_terminal 的事，
        // 而且整屏文本塞进这里会让一次状态查询吃掉上千 token。
        return [
          for (final (i, t) in mgr.tabs.indexed)
            {
              'index': i,
              'name': t.server.name,
              'host': t.server.host,
              // `transport != null` 即「这个 tab 背后有一条活着的连接」。
              // session_close 的硬清单判据用的也是这个 —— 两处必须同源，
              // 否则会出现「状态里说没连，关的时候却弹审批」。
              'connected': t.transport != null,
              'active': i == mgr.activeIndex,
            }
        ];

      case 'tunnels':
        final mgr = tunnels;
        if (mgr == null) return null;
        return [
          for (final t in mgr.tunnels)
            {
              'id': t.id,
              'server': t.server.name,
              'direction': t.direction.name,
              'local_port': t.localPort,
              'remote_host': t.remoteHost,
              'remote_port': t.remotePort,
              'status': t.status.name,
              if (t.label.isNotEmpty) 'label': t.label,
            }
        ];

      case 'keybar':
        final kb = keybar;
        if (kb == null) return null;
        return [
          for (final item in kb.items)
            {
              'label': item.label,
              'sticky': item.sticky,
              'repeatable': item.repeatable,
            }
        ];

      default:
        return null;
    }
  }

  /// 读白名单内的设置。
  ///
  /// 键集合**恰好**是 [kAgentWritableSettings] —— 硬禁区是「连读都不给」，
  /// 读写共用一张表让这条约束只有一个真相来源。`app_control_service_test`
  /// 里有一条断言锚定这个相等关系，两边漂移会立刻挂掉。
  Map<String, Object?> readSettings() => {
        'fontSize': settings.fontSize,
        'fontFamily': settings.fontFamily,
        'lineHeight': settings.lineHeight,
        'terminalTheme': settings.terminalTheme.name,
        'cursorStyle': settings.cursorStyle.name,
        'keyboardTrigger': settings.keyboardTrigger.name,
        'commandCompletion': settings.commandCompletion,
        'sshCompression': settings.sshCompression,
        'backgroundKeepAlive': settings.backgroundKeepAlive,
        'fetY': settings.fetY,
        'fetHidden': settings.fetHidden,
        'fetOpacity': settings.fetOpacity,
        'fetAutoFade': settings.fetAutoFade,
        'fetEnabled': settings.fetEnabled,
      };

  /// 写一个白名单内的设置。
  ///
  /// 两道闸的顺序是刻意的：**先查禁区，再查白名单**。禁区命中要的是「这个键
  /// 不存在于你的世界里」，与「这个键存在但不可写」在模型眼里应当没有区别 ——
  /// 两者返回同一句 `not writable`，不泄露禁区的存在和边界。
  Future<AppSetResult> setSetting(String key, Object? value) async {
    if (isForbiddenSettingKey(key) || !kAgentWritableSettings.contains(key)) {
      return AppSetResult.failure(
        'Setting `$key` is not writable. Writable keys: '
        '${kAgentWritableSettings.join(', ')}.',
      );
    }

    final oldValue = readSettings()[key];

    try {
      switch (key) {
        case 'fontSize':
          await settings.setFontSize(_asDouble(key, value));
        case 'lineHeight':
          await settings.setLineHeight(_asDouble(key, value));
        case 'fontFamily':
          await settings.setFontFamily(_asString(key, value));
        case 'terminalTheme':
          await settings
              .setTerminalTheme(_asEnum(key, value, AppTerminalTheme.values));
        case 'cursorStyle':
          await settings
              .setCursorStyle(_asEnum(key, value, TerminalCursorStyle.values));
        case 'keyboardTrigger':
          await settings.setKeyboardTrigger(
              _asEnum(key, value, KeyboardTriggerMode.values));
        case 'commandCompletion':
          await settings.setCommandCompletion(_asBool(key, value));
        case 'sshCompression':
          await settings.setSshCompression(_asBool(key, value));
        case 'backgroundKeepAlive':
          await settings.setBackgroundKeepAlive(_asBool(key, value));
        case 'fetY':
          await settings.setFetY(_asDouble(key, value));
        case 'fetOpacity':
          await settings.setFetOpacity(_asDouble(key, value));
        case 'fetHidden':
          await settings.setFetHidden(_asBool(key, value));
        case 'fetAutoFade':
          await settings.setFetAutoFade(_asBool(key, value));
        case 'fetEnabled':
          await settings.setFetEnabled(_asBool(key, value));
        default:
          // 白名单与这个 switch 漂移了。白名单是真相来源，这里是遗漏。
          return AppSetResult.failure(
            'Setting `$key` is whitelisted but has no writer. This is a bug.',
          );
      }
    } on _CoerceError catch (e) {
      return AppSetResult.failure(e.message);
    }

    // **读回生效后的真实值**，不是 value —— setter 普遍带 clamp，记请求值
    // 会让撤销卡片显示一个从未生效过的数字。
    final newValue = readSettings()[key];

    final change = AppChange(
      toolName: 'app_settings_set',
      field: key,
      oldValue: oldValue,
      newValue: newValue,
      undo: () => _restore(key, oldValue),
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  // ───────── 服务器条目 ─────────

  /// 按名字找一条服务器。名字是模型唯一能稳定引用的标识 —— 内部 id 不给
  /// 模型看（见 `ServerListEntry` 的注释）。
  Future<Server?> _serverByName(String name) async {
    final repo = servers;
    if (repo == null) return null;
    final all = await repo.findAll();
    for (final s in all) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// 新建一条服务器条目。
  ///
  /// **不接受任何凭据字段**（密码、私钥、key id）。`authType` 固定为
  /// `'password'`，用户之后在服务器表单里自己补 —— 凭据经由模型就等于经由
  /// 模型的上下文、日志和服务端，这条边界在参数层面就堵死，不靠运行时判断。
  Future<AppSetResult> createServer({
    required String name,
    required String host,
    int port = 22,
    required String username,
    String? groupName,
  }) async {
    final repo = servers;
    if (repo == null) {
      return const AppSetResult.failure('Server list is not available.');
    }
    if (name.trim().isEmpty || host.trim().isEmpty || username.trim().isEmpty) {
      return const AppSetResult.failure(
          '`name`, `host` and `user` must all be non-empty.');
    }
    if (await _serverByName(name) != null) {
      return AppSetResult.failure(
          'A server named `$name` already exists. Use server_entry_update '
          'to change it.');
    }
    if (port < 1 || port > 65535) {
      return AppSetResult.failure('Port must be 1–65535, got $port.');
    }

    final server = Server(
      id: const Uuid().v4(),
      name: name.trim(),
      host: host.trim(),
      port: port,
      username: username.trim(),
      authType: 'password',
      groupName: (groupName?.trim().isEmpty ?? true) ? null : groupName!.trim(),
    );
    await repo.insert(server);

    final change = AppChange(
      toolName: 'server_entry_create',
      field: 'server:$name',
      oldValue: null,
      newValue: name,
      undo: () => repo.delete(server.id),
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 改一条服务器条目的连接参数。**只这五项**，凭据与传输协议不在其中。
  Future<AppSetResult> updateServer({
    required String name,
    String? host,
    int? port,
    String? username,
    String? groupName,
  }) async {
    final repo = servers;
    if (repo == null) {
      return const AppSetResult.failure('Server list is not available.');
    }
    final old = await _serverByName(name);
    if (old == null) {
      return AppSetResult.failure('No server named `$name`.');
    }
    if (port != null && (port < 1 || port > 65535)) {
      return AppSetResult.failure('Port must be 1–65535, got $port.');
    }

    final updated = old.copyWith(
      host: host?.trim(),
      port: port,
      username: username?.trim(),
      groupName: groupName?.trim(),
    );
    await repo.update(updated);

    final change = AppChange(
      toolName: 'server_entry_update',
      field: 'server:$name',
      oldValue: '${old.username}@${old.host}:${old.port}',
      newValue: '${updated.username}@${updated.host}:${updated.port}',
      undo: () => repo.update(old),
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 删一条服务器条目。
  ///
  /// **可撤销**：整个 `Server` 对象存在闭包里，undo 原样写回。私钥本来就
  /// 存在 SecureStorage 的 `ssh_key_<id>` 下、不随条目删除，所以 undo
  /// 之后连密钥引用也是完整的。机器笔记也在可撤销范围内（I2）——
  /// `ServerRepository.delete` 的事务会把 `server_notes` 行一起删掉，不提前
  /// 存一份快照的话，undo 只能插回 `servers` 行，笔记永久丢了，「可撤销」就
  /// 名不副实。
  ///
  /// 它同时还在 `kAppHardApproval` 里（删除前必弹确认）—— 双保险是刻意的，
  /// 误删的心理成本高于一次多余的确认。
  Future<AppSetResult> deleteServer(String name) async {
    final repo = servers;
    if (repo == null) {
      return const AppSetResult.failure('Server list is not available.');
    }
    final old = await _serverByName(name);
    if (old == null) {
      return AppSetResult.failure('No server named `$name`.');
    }
    // 删之前先把笔记原文捞一份——这里拿不到 BuildContext，只能靠构造注入
    // 的 [serverNotes]（可能是 null，那样笔记本来就恢复不了，undo 退化成
    // 只还原 servers 行，不算回归，是改造前的行为）。
    final oldNote = serverNotes?.noteFor(old.id);
    await repo.delete(old.id);
    // C1：repo.delete 的事务级联删了 server_notes 行，但 ServerNotesManager
    // 的内存缓存不会跟着失效——不补这一下，笔记总览会继续显示这条直到下次
    // 冷启动。见 [serverNotes] 字段注释：main.dart 还要补一行构造参数这条
    // 链才算接通。
    await serverNotes?.delete(old.id);

    final change = AppChange(
      toolName: 'server_entry_delete',
      field: 'server:$name',
      oldValue: name,
      newValue: null,
      undo: () async {
        await repo.insert(old);
        // oldNote 为 null 分两种情况：这台机器本来就没笔记，或者
        // serverNotes 没装配——两种都不该写出一个空笔记行。
        if (oldNote != null) {
          await serverNotes?.replaceNote(serverId: old.id, body: oldNote);
        }
      },
    );
    changeLog.record(change);
    return AppSetResult.success(change);
  }

  /// 撤销用：把键写回旧值。
  ///
  /// 走 [setSetting] 之外的私有路径，否则撤销本身会再记一条变更 ——
  /// `undoAll` 遍历到一半栈被追加，既污染历史又可能无限增长。
  Future<void> _restore(String key, Object? oldValue) async {
    switch (key) {
      case 'fontSize':
        await settings.setFontSize(oldValue as double);
      case 'lineHeight':
        await settings.setLineHeight(oldValue as double);
      case 'fontFamily':
        await settings.setFontFamily(oldValue as String);
      case 'terminalTheme':
        await settings.setTerminalTheme(
            AppTerminalTheme.values.firstWhere((e) => e.name == oldValue));
      case 'cursorStyle':
        await settings.setCursorStyle(
            TerminalCursorStyle.values.firstWhere((e) => e.name == oldValue));
      case 'keyboardTrigger':
        await settings.setKeyboardTrigger(
            KeyboardTriggerMode.values.firstWhere((e) => e.name == oldValue));
      case 'commandCompletion':
        await settings.setCommandCompletion(oldValue as bool);
      case 'sshCompression':
        await settings.setSshCompression(oldValue as bool);
      case 'backgroundKeepAlive':
        await settings.setBackgroundKeepAlive(oldValue as bool);
      case 'fetY':
        await settings.setFetY(oldValue as double);
      case 'fetOpacity':
        await settings.setFetOpacity(oldValue as double);
      case 'fetHidden':
        await settings.setFetHidden(oldValue as bool);
      case 'fetAutoFade':
        await settings.setFetAutoFade(oldValue as bool);
      case 'fetEnabled':
        await settings.setFetEnabled(oldValue as bool);
    }
  }

  // ───────── 类型强制 ─────────
  //
  // 模型回传的 JSON 类型不可靠：数字可能是 "16"，布尔可能是 "true"。
  // 宽进（接受字符串形式）但不静默 —— 真的解析不了就报错，不要退回默认值，
  // 那会让模型以为设置成功了。

  double _asDouble(String key, Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) {
      final p = double.tryParse(v);
      if (p != null) return p;
    }
    throw _CoerceError('Setting `$key` expected a number, got `$v`.');
  }

  bool _asBool(String key, Object? v) {
    if (v is bool) return v;
    if (v is String) {
      if (v.toLowerCase() == 'true') return true;
      if (v.toLowerCase() == 'false') return false;
    }
    throw _CoerceError('Setting `$key` expected a boolean, got `$v`.');
  }

  String _asString(String key, Object? v) {
    if (v is String) return v;
    throw _CoerceError('Setting `$key` expected a string, got `$v`.');
  }

  T _asEnum<T extends Enum>(String key, Object? v, List<T> values) {
    final s = v is String ? v : '$v';
    for (final e in values) {
      if (e.name == s) return e;
    }
    throw _CoerceError(
      'Setting `$key` must be one of: ${values.map((e) => e.name).join(', ')}. '
      'Got `$s`.',
    );
  }
}

/// 类型强制失败。**私有** —— 它只在 [AppControlService.setSetting] 内部跨越
/// 几层调用，不是公开契约（公开契约是 [AppSetResult]）。
class _CoerceError implements Exception {
  final String message;
  _CoerceError(this.message);
}
