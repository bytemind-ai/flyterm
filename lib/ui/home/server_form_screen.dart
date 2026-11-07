// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../data/host_normalize.dart';
import '../../data/models/server.dart';
import '../../data/models/ssh_key.dart';
import '../../data/repositories/server_repository.dart';
import '../../data/repositories/ssh_key_repository.dart';
import '../../data/secure_storage.dart';
import '../../l10n/l10n.dart';
import '../../platform_capabilities.dart';
import '../../commerce/entitlement_service.dart';
import '../../commerce/feature_gate.dart';
import '../../ssh/transport/transport.dart';
import '../../ssh/aqt/aqt_port_spec.dart';
import '../../ai/agent/agent_session_manager.dart';
import '../../ai/agent/server_notes_manager.dart';
import '../../ai/agent/tool_registry.dart';
import '../../ai/ai_message.dart';
import '../../ai/ai_provider_service.dart';
import '../../config_import/config_draft.dart';
import '../design/fly_tokens.dart';
import '../settings/widgets/server_perm_section.dart';
import '../settings/agent_server_notes_sheet.dart';
import 'widgets/config_paste_sheet.dart';

class ServerFormScreen extends StatefulWidget {
  final Server? server; // null = create, non-null = edit

  const ServerFormScreen({super.key, this.server});

  @override
  State<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends State<ServerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _startupCommand;
  late final TextEditingController _groupName;

  String _authType = 'password';
  String _serverType = 'ssh';
  String? _selectedKeyId;
  bool _useTmux = false;
  bool _useDaemon = false;
  String _moshPortRange = '60000:61000';
  String _aqtPorts = '';
  bool _agentForwarding = false;
  bool _useJump = false;
  String? _jumpHostId;
  String _addressFamily = 'auto';
  Transport _transport = Transport.quic;
  List<Server> _allServers = [];
  List<SSHKey> _keys = [];
  // ADVANCED 折叠区默认收起（startupCommand / addressFamily / agentForwarding
  // / tmux / jumpHost / moshPortRange 等不常用项）。降低首屏字段密度。
  bool _advancedOpen = false;

  /// 本次从粘贴导入里解析到的字段名。用于给对应输入框加视觉标记。
  /// 空集 = 用户没用过导入，或导入的字段已被他改过。
  Set<String> _importedFields = const {};

  @override
  void initState() {
    super.initState();
    final s = widget.server;
    _name = TextEditingController(text: s?.name ?? '');
    _host = TextEditingController(text: s?.host ?? '');
    _port = TextEditingController(text: s?.port.toString() ?? '22');
    _username = TextEditingController(text: s?.username ?? '');
    _password = TextEditingController();
    _startupCommand = TextEditingController(text: s?.startupCommand ?? '');
    _groupName = TextEditingController(text: s?.groupName ?? '');
    _authType = s?.authType ?? 'password';
    _serverType = s?.serverType ?? 'ssh';
    // _selectedKeyId is intentionally NOT set here: the DropdownButtonFormField
    // requires value to be null or present in items. Since _keys loads async,
    // setting the id before items arrive causes a Flutter assertion and
    // renders the selected text at the wrong position. We restore it after load.
    _useTmux = s?.useTmux ?? false;
    _useDaemon = s?.useDaemon ?? false;
    _moshPortRange = s?.moshPortRange ?? '60000:61000';
    _aqtPorts = s?.aqtPorts ?? '';
    _agentForwarding = s?.agentForwarding ?? false;
    _addressFamily = s?.addressFamily ?? 'auto';
    _transport = s?.transport ?? Transport.quic;
    _loadKeys();
    _jumpHostId = widget.server?.jumpHostId;
    _useJump = _jumpHostId != null;
    _loadAllServers();
  }

  Future<void> _loadAllServers() async {
    final servers = await context.read<ServerRepository>().findAll();
    setState(() {
      _allServers = servers
          .where((s) => s.id != (widget.server?.id ?? ''))
          .toList();
      if (_jumpHostId != null && !_allServers.any((s) => s.id == _jumpHostId)) {
        _jumpHostId = null;
        _useJump = false;
      }
    });
  }

  Future<void> _loadKeys() async {
    final keys = await context.read<SSHKeyRepository>().findAll();
    setState(() {
      _keys = keys;
      // Now that items are ready, restore the saved selection safely.
      _selectedKeyId = widget.server?.keyId;
    });
  }

  /// Push the KeyManager onto the stack so the user can generate or
  /// import a key without losing this form's in-progress state. On
  /// return, reload the key list and — if exactly one new key was
  /// added — auto-select it so the user doesn't have to re-open the
  /// dropdown.
  Future<void> _openKeyManagerAndAutoSelect() async {
    final previousIds = _keys.map((k) => k.id).toSet();
    await Navigator.of(context).pushNamed('/settings/keys');
    if (!mounted) return;
    final keys = await context.read<SSHKeyRepository>().findAll();
    final added = keys.where((k) => !previousIds.contains(k.id)).toList();
    setState(() {
      _keys = keys;
      if (added.length == 1) _selectedKeyId = added.first.id;
    });
  }

  /// 打开粘贴导入面板。
  ///
  /// `llmComplete` 在没有可用 provider 时传 null —— 面板据此隐藏「用 AI 试试」
  /// 按钮，本方法因此不需要任何分支判断（见 `ConfigPasteSheet` 的类文档）。
  Future<void> _openPasteImport() async {
    final svc = context.read<AIProviderService?>();
    final provider = svc?.provider;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ConfigPasteSheet(
        llmComplete: provider == null
            ? null
            : (prompt) =>
                  provider.complete([AIMessage(role: 'user', content: prompt)]),
        onApplyServer: (draft) {
          Navigator.pop(context);
          _applyDraft(draft);
        },
      ),
    );
  }

  void _applyDraft(ServerDraft draft) {
    final a = ServerDraftApplication.from(draft);
    setState(() {
      _name.text = a.name;
      _host.text = a.host;
      _port.text = a.port;
      _username.text = a.username;
      _importedFields = a.highlightedFields;
      // 解析到密钥路径时切到密钥认证并展开高级区 —— 用户必须看到那个
      // 「请手动选密钥」的提示，折叠着等于没说。
      if (a.needsManualKey) {
        _authType = 'key';
        _advancedOpen = true;
      }
      // 跳板机别名能对上已存服务器才打开开关；对不上就只展开高级区，
      // 让用户自己选（别名在本机不一定存在）。
      if (a.jumpHostAlias != null) {
        _advancedOpen = true;
        final matches = _allServers
            .where(
              (s) => s.name == a.jumpHostAlias || s.host == a.jumpHostAlias,
            )
            .toList();
        if (matches.isNotEmpty) {
          _useJump = true;
          _jumpHostId = matches.first.id;
        }
      }
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.importApplied)));
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _startupCommand.dispose();
    _groupName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final isEditing = widget.server != null;
    final isSsh = _serverType == 'ssh';
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? l.editServer : l.newServer),
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          // SAVE 移到 AppBar action：移动设备上避免每次都滚到底部点保存按钮。
          // mono uppercase 与 HomeScreen / section header 视觉一致。
          TextButton(
            onPressed: _save,
            child: Text(
              (isEditing ? l.save : l.add).toUpperCase(),
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            OutlinedButton.icon(
              onPressed: _openPasteImport,
              icon: const Icon(Icons.content_paste_go),
              label: Text(context.l10n.importPasteTitle),
            ),
            const SizedBox(height: 12),

            // ── 服务器类型放在最顶部 ─────────────────────────────────
            // 这是新建服务器时**第一个决策**："连接对象是远程还是本地"。
            // 选 Local 后所有 host/port/auth/transport 字段都隐藏，避免
            // 用户填一堆字段后才发现可以切。Remote/Local 命名跟下方
            // TRANSPORT (QUIC/SSH/Mosh) 分层语义清晰。
            //
            // iOS 上本地 shell 不存在（`PlatformCapabilities.hasLocalShell`
            // = false）—— 只剩一个选项
            // 时这个分段控件只是噪音，直接不渲染，也不给用户选到 local 的
            // 机会（省得存进 DB 再在连接时才报错）。
            if (PlatformCapabilities.instance().hasLocalShell)
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'ssh', label: Text(l.serverTypeRemote)),
                  ButtonSegment(value: 'local', label: Text(l.serverTypeLocal)),
                ],
                selected: {_serverType},
                onSelectionChanged: (s) =>
                    setState(() => _serverType = s.first),
                style: SegmentedButton.styleFrom(
                  textStyle: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
              ),

            // ── IDENTITY ─────────────────────────────────────────────
            _sectionHeader(context, l.providerSectionIdentity),
            _field(
              TextFormField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: l.labelName,
                  suffixIcon: _importedMark(context, 'name'),
                ),
                validator: (v) => v!.isEmpty ? l.required : null,
              ),
            ),
            _field(
              TextFormField(
                controller: _groupName,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: l.serverGroup),
              ),
            ),

            if (isSsh) ...[
              // ── ENDPOINT ──────────────────────────────────────────
              _sectionHeader(context, l.providerSectionEndpoint),
              _field(
                TextFormField(
                  controller: _host,
                  decoration: InputDecoration(
                    labelText: l.labelHost,
                    helperText: l.labelHostHelper,
                    suffixIcon: _importedMark(context, 'host'),
                  ),
                  validator: (v) => v!.isEmpty ? l.required : null,
                ),
              ),
              _field(
                TextFormField(
                  controller: _port,
                  decoration: InputDecoration(
                    labelText: l.labelPort,
                    suffixIcon: _importedMark(context, 'port'),
                  ),
                  keyboardType: TextInputType.number,
                  validator: (v) =>
                      int.tryParse(v!) == null ? l.invalidPort : null,
                ),
              ),
              _field(
                TextFormField(
                  controller: _username,
                  decoration: InputDecoration(
                    labelText: l.labelUsername,
                    suffixIcon: _importedMark(context, 'username'),
                  ),
                  validator: (v) => v!.isEmpty ? l.required : null,
                ),
              ),

              // ── AUTH ──────────────────────────────────────────────
              _sectionHeader(context, l.providerSectionAuth),
              RadioListTile<String>(
                title: Text(l.authPassword),
                value: 'password',
                groupValue: _authType,
                onChanged: (v) => setState(() => _authType = v!),
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile<String>(
                title: Text(l.authSshKey),
                value: 'key',
                groupValue: _authType,
                onChanged: (v) => setState(() => _authType = v!),
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
              ),
              if (_authType == 'password')
                _field(
                  TextFormField(
                    controller: _password,
                    decoration: InputDecoration(labelText: l.labelPassword),
                    obscureText: true,
                  ),
                ),
              if (_authType == 'key') ...[
                _field(
                  DropdownButtonFormField<String>(
                    value: _keys.any((k) => k.id == _selectedKeyId)
                        ? _selectedKeyId
                        : null,
                    decoration: InputDecoration(labelText: l.selectKey),
                    isDense: true,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    icon: const Icon(Icons.expand_more, size: 18),
                    items: _keys
                        .map(
                          (k) => DropdownMenuItem(
                            value: k.id,
                            child: Text(
                              k.name,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _selectedKeyId = v),
                    validator: (v) => v == null ? l.keyRequired : null,
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _openKeyManagerAndAutoSelect,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l.addSshKey),
                  ),
                ),
              ],

              // ── TRANSPORT ─────────────────────────────────────────
              _sectionHeader(context, l.transport.toUpperCase()),
              Row(
                children: [
                  for (final t in Transport.values)
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          if (t == Transport.quic || t == Transport.mosh) {
                            final isPro = context
                                .read<EntitlementService>()
                                .isPro;
                            if (!isPro) {
                              final passed = await FeatureGate.checkOrShow(
                                context,
                                reason: 'pro_transport',
                              );
                              if (!passed) return;
                              if (!context.mounted) return;
                            }
                          }
                          _selectTransport(t);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Radio<Transport>(
                                value: t,
                                groupValue: _transport,
                                onChanged: (v) async {
                                  if (v == null) return;
                                  if (v == Transport.quic ||
                                      v == Transport.mosh) {
                                    final isPro = context
                                        .read<EntitlementService>()
                                        .isPro;
                                    if (!isPro) {
                                      final passed =
                                          await FeatureGate.checkOrShow(
                                            context,
                                            reason: 'pro_transport',
                                          );
                                      if (!passed) return;
                                      if (!context.mounted) return;
                                    }
                                  }
                                  _selectTransport(v);
                                },
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              Text(
                                _transportLabel(t),
                                style: const TextStyle(fontSize: 13),
                              ),
                              if (t == Transport.quic) ...[
                                const SizedBox(width: 4),
                                Text(
                                  l.transportRecommended,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (_transport == Transport.mosh)
                _field(
                  TextFormField(
                    initialValue: _moshPortRange,
                    decoration: InputDecoration(
                      labelText: l.moshPortRange,
                      hintText: '60000:61000',
                    ),
                    onChanged: (v) => _moshPortRange = v,
                    validator: (v) {
                      if (v == null || v.isEmpty) return null;
                      final parts = v.split(':');
                      if (parts.length != 2) return l.moshPortRangeFormat;
                      final a = int.tryParse(parts[0]);
                      final b = int.tryParse(parts[1]);
                      if (a == null || b == null) return l.moshPortMustBeInt;
                      if (a >= b) return l.moshStartBeforeEnd;
                      return null;
                    },
                  ),
                ),
              if (_transport == Transport.quic)
                SwitchListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(l.useDaemon),
                  subtitle: Text(
                    l.useDaemonDesc,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  value: _useDaemon,
                  onChanged: (v) => setState(() => _useDaemon = v),
                  contentPadding: EdgeInsets.zero,
                ),
              if (_transport == Transport.quic)
                _field(
                  TextFormField(
                    initialValue: _aqtPorts,
                    decoration: InputDecoration(
                      labelText: l.aqtPortsLabel,
                      hintText: AqtPortSpec.defaults.arg,
                      helperText: l.aqtPortsHint,
                      helperMaxLines: 3,
                    ),
                    onChanged: (v) => _aqtPorts = v,
                    validator: (v) =>
                        v == null || v.trim().isEmpty || AqtPortSpec.parse(v) != null
                            ? null
                            : l.aqtPortsInvalid,
                  ),
                ),

              // ── ADVANCED 折叠区 ───────────────────────────────────
              const SizedBox(height: 8),
              _collapsibleHeader(
                context,
                l.providerSectionAdvanced,
                _advancedOpen,
                () => setState(() => _advancedOpen = !_advancedOpen),
              ),
              if (_advancedOpen) ...[
                // 启动命令字段：shell 命令是技术输入，用 JetBrains Mono +
                // fontSize:13 跟其他配置 Dropdown / 紧凑控件字号一致；hint
                // 用 mono 11.5 +淡色凸显是示例而非占位。
                _field(
                  TextFormField(
                    controller: _startupCommand,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      labelText: l.labelStartupCommand,
                      hintText: l.hintStartupCommand,
                      hintStyle: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.onSurface
                            .withOpacity(0.35),
                      ),
                      isDense: true,
                    ),
                  ),
                ),
                _field(
                  DropdownButtonFormField<String>(
                    value: _addressFamily,
                    decoration: InputDecoration(
                      labelText: l.addressFamilyLabel,
                    ),
                    isDense: true,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    icon: const Icon(Icons.expand_more, size: 18),
                    items: [
                      DropdownMenuItem(
                        value: 'auto',
                        child: Text(
                          l.addressFamilyAuto,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'ipv4',
                        child: Text(
                          l.addressFamilyIpv4,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'ipv6',
                        child: Text(
                          l.addressFamilyIpv6,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _addressFamily = v ?? 'auto'),
                  ),
                ),
                if (_transport != Transport.quic)
                  SwitchListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title: Text(l.useTmux),
                    subtitle: Text(
                      l.useTmuxDesc,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    value: _useTmux,
                    onChanged: (v) => setState(() => _useTmux = v),
                    contentPadding: EdgeInsets.zero,
                  ),
                SwitchListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.agentForwarding),
                  subtitle: Text(
                    l.agentForwardingDesc,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  value: _agentForwarding,
                  onChanged: (v) => setState(() => _agentForwarding = v),
                ),
                SwitchListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.useJumpHost),
                  subtitle: Text(
                    l.useJumpHostDesc,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  value: _useJump,
                  onChanged: (v) {
                    if (v && _transport == Transport.mosh) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l.moshNotSupportedWithJump)),
                      );
                      return;
                    }
                    setState(() {
                      _useJump = v;
                      if (!v) _jumpHostId = null;
                    });
                  },
                ),
                if (_useJump) ...[
                  _field(
                    DropdownButtonFormField<String>(
                      value: _allServers.any((s) => s.id == _jumpHostId)
                          ? _jumpHostId
                          : null,
                      decoration: InputDecoration(
                        labelText: l.selectJumpServer,
                      ),
                      isDense: true,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      icon: const Icon(Icons.expand_more, size: 18),
                      items: _allServers
                          .map(
                            (s) => DropdownMenuItem(
                              value: s.id,
                              child: Text(
                                '${s.name}  (${s.username}@${s.host})',
                                style: const TextStyle(fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _jumpHostId = v),
                      validator: (v) =>
                          _useJump && v == null ? l.jumpServerRequired : null,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).pushNamed('/server-form');
                      _loadAllServers();
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l.addJumpServer),
                  ),
                ],
                // 只对已存在的服务器有意义（新建时还没有 id）。这里放的是
                // 真正按服务器变化的两样：权限档的**覆盖**，和这台机器的
                // 笔记（app 端 SQLite，见 ServerNotesManager）。其余 agent
                // 配置都是全局的，在 设置 → AI → AI Agent 里。
                if (widget.server != null)
                  Consumer2<AgentSessionManager, ServerNotesManager>(
                    builder: (context, mgr, notesMgr, _) {
                      final id = widget.server!.id;
                      final note = notesMgr.noteFor(id);
                      return Column(
                        children: [
                          // 权限节：跟随开关 + 三档分段选择器，与设置页同一套 UI。
                          // 内联而非弹窗 —— 用户在两处看到同一套词。
                          ServerPermSection(serverId: id),
                          const Divider(),
                          // 这台机器的笔记（app 端 SQLite，见
                          // ServerNotesManager）。
                          //
                          // 这个入口存在的意义不只是「能看」：它每轮都在被
                          // 拼进 system prompt——模型能通过 save_note 工具
                          // 悄悄往里写、沉淀卡片也会往里追加——但没有这个
                          // 入口时用户在界面上根本看不到它存在，也就不会
                          // 知道自己也能手写它。
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.description_outlined),
                            title: Text(l.agentServerNotesEntry),
                            subtitle: Text(
                              note == null
                                  ? l.agentServerNotesNone
                                  : l.agentServerNotesLines(
                                      note.split('\n').length,
                                    ),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () =>
                                AgentServerNotesSheet.show(context, id),
                          ),
                        ],
                      );
                    },
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// 字段若来自粘贴导入解析结果，给输入框加一个小图标做视觉提示
  /// （见 [_importedFields] 的字段文档）。没解析到就返回 null，不占位。
  Widget? _importedMark(BuildContext context, String field) {
    if (!_importedFields.contains(field)) return null;
    return Icon(
      Icons.auto_awesome,
      size: 16,
      color: Theme.of(context).colorScheme.primary,
      semanticLabel: context.l10n.importApplied,
    );
  }

  /// Section header: JetBrains Mono uppercase tertiary 灰 + 顶部留白。
  /// 把一个表单控件包上统一下间距。
  ///
  /// ## 为什么需要它
  ///
  /// 这些字段原先是一个扁平 `ListView` 里的裸序列，**彼此之间没有任何显式
  /// 间距** —— 全靠 `InputDecoration` 自带的空间撑着。实测相邻两框的包围盒
  /// 间距是 **0.0px**：边框直接贴在一起。带 `helperText` 的字段（如 host）
  /// 更糟，辅助文案的占位和下一个框的边框挤在一处，用户报的「行之间没有
  /// 间隔、内容重叠」就是这个。
  ///
  /// 用统一的 wrapper 而不是在每对字段间手插 `SizedBox`：后者要改 10 处，
  /// 漏一处就退回旧观感，而且新增字段时没人会记得补。
  Widget _field(Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: kFormFieldGap),
    child: child,
  );

  /// 与 HomeScreen `_GroupHeader` / 其他设置页 _SectionHeader 同调性
  /// （字号 11 / weight 700 / letterSpacing 1.2 / opacity 0.55 / top 20 bottom 8）。
  /// 父 ListView 已有 horizontal:16 padding，所以本 widget 左右用 0 补偿到视觉
  /// 16，跟其他配置项 16-indent 对齐。
  Widget _sectionHeader(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
          letterSpacing: 1.2,
          height: 1.0,
        ),
      ),
    );
  }

  /// 折叠 header（同 section style + 右侧 chevron）。tap 切换展开。
  Widget _collapsibleHeader(
    BuildContext context,
    String label,
    bool expanded,
    VoidCallback onTap,
  ) {
    final color = Theme.of(context).colorScheme.onSurface.withOpacity(0.55);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color,
                letterSpacing: 1.2,
                height: 1.0,
              ),
            ),
            const Spacer(),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: color,
            ),
          ],
        ),
      ),
    );
  }

  String _transportLabel(Transport t) {
    switch (t) {
      case Transport.quic:
        return 'QUIC';
      case Transport.ssh:
        return 'SSH';
      case Transport.mosh:
        return 'Mosh';
    }
  }

  void _selectTransport(Transport t) {
    if (t == Transport.mosh && _useJump) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.moshNotSupportedWithJump)),
      );
      return;
    }
    setState(() => _transport = t);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_transport == Transport.mosh && _useJump) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.moshNotSupportedWithJump)),
      );
      return;
    }
    // 防御：iOS 上 segment 已隐藏（build 里那道 if），但 DB 里已存的 local
    // 记录被编辑进来时 `_serverType` 仍是 'local'。此时不能存回去一条
    // 在本平台永远连不上的记录 —— 直接拒绝并提示。
    if (_serverType == 'local' &&
        !PlatformCapabilities.instance().hasLocalShell) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.localShellUnsupported)),
        );
      }
      return;
    }
    final repo = context.read<ServerRepository>();
    final storage = context.read<SecureStorageService>();
    final id = widget.server?.id ?? const Uuid().v4();
    final server = Server(
      id: id,
      name: _name.text.trim(),
      host: _serverType == 'local' ? 'localhost' : normalizeHost(_host.text),
      port: _serverType == 'local' ? 0 : int.parse(_port.text.trim()),
      username: _serverType == 'local' ? '' : _username.text.trim(),
      authType: _serverType == 'local' ? 'password' : _authType,
      keyId: (_serverType == 'ssh' && _authType == 'key')
          ? _selectedKeyId
          : null,
      startupCommand: _startupCommand.text.trim().isEmpty
          ? null
          : _startupCommand.text.trim(),
      useTmux: _serverType == 'local' ? false : _useTmux,
      moshPortRange: _moshPortRange.isEmpty ? '60000:61000' : _moshPortRange,
      jumpHostId: (_serverType == 'ssh' && _useJump) ? _jumpHostId : null,
      groupName: _groupName.text.trim().isEmpty ? null : _groupName.text.trim(),
      agentForwarding: _serverType == 'local' ? false : _agentForwarding,
      serverType: _serverType,
      addressFamily: _serverType == 'local' ? 'auto' : _addressFamily,
      transport: _serverType == 'local' ? Transport.ssh : _transport,
      useDaemon: _serverType == 'local' ? false : _useDaemon,
      // 存规范化后的写法（去掉空白）；空 = 默认范围。
      aqtPorts: _serverType == 'local' || _aqtPorts.trim().isEmpty
          ? null
          : AqtPortSpec.parse(_aqtPorts)?.arg,
    );
    if (_authType == 'password' && _password.text.isNotEmpty) {
      await storage.savePassword(id, _password.text);
    } else if (_authType == 'key') {
      await storage.deletePassword(id);
    }
    if (widget.server != null) {
      await repo.update(server);
    } else {
      await repo.insert(server);
    }
    if (mounted) Navigator.of(context).pop();
  }
}

/// 把一份 [ServerDraft] 翻译成表单控件需要的字符串。
///
/// ## 为什么单独成类而不是在 State 里写一个方法
///
/// 这段映射有真实的决策（port 缺省填 22、name 回落到 host、哪些字段算高亮），
/// 而它们正是最容易写错又最难在 widget 测试里看清的部分。独立成纯数据类之后，
/// 五条规则可以不搭 widget 树直接测 —— widget 测试只需要验「有没有接上」。
class ServerDraftApplication {
  final String name;
  final String host;
  final String port;
  final String username;

  /// 从草稿里真正解析到的字段名。UI 据此高亮，并把其余字段留在折叠区里。
  final Set<String> highlightedFields;

  /// 解析到了密钥路径 —— 表单要提示用户手动选一个本机密钥。
  final bool needsManualKey;

  /// `ProxyJump` 的别名。表单拿它去 `_allServers` 里找匹配的机器。
  final String? jumpHostAlias;

  const ServerDraftApplication({
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.highlightedFields,
    required this.needsManualKey,
    this.jumpHostAlias,
  });

  factory ServerDraftApplication.from(ServerDraft d) => ServerDraftApplication(
    // name 回落到 host：用户粘一行 `ssh root@1.2.3.4` 时没有名字可用，
    // 留空会让他面对一个必填的空框。
    name: d.name ?? d.host ?? '',
    host: d.host ?? '',
    // 22 是 ssh 默认端口，这里填的是**表单默认值**而不是解析结果 ——
    // 所以它不进 highlightedFields。
    port: d.port?.toString() ?? '22',
    username: d.username ?? '',
    highlightedFields: d.provenance.keys.toSet(),
    needsManualKey: d.needsManualKey,
    jumpHostAlias: d.jumpHostAlias,
  );
}
