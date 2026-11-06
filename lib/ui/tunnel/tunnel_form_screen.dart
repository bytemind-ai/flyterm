// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:dartssh2/dartssh2.dart';
import '../../ai/ai_message.dart';
import '../../ai/ai_provider_service.dart';
import '../../config_import/config_draft.dart';
import '../../data/models/server.dart';
import '../../data/repositories/server_repository.dart';
import '../../data/secure_storage.dart';
import '../../l10n/l10n.dart';
import '../../tunnel/tunnel_entry.dart';
import '../../tunnel/tunnel_manager.dart';
import '../home/widgets/config_paste_sheet.dart';

/// Arguments passed to /tunnels/form route.
class TunnelFormArgs {
  /// Pre-selected server (locks server dropdown). Pass when opening from terminal.
  final Server? server;

  /// Pre-existing client to reuse (skips new SSH connection).
  final SSHClient? existingClient;

  const TunnelFormArgs({this.server, this.existingClient});
}

// ── Section header (Industrial Console style) ────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  static bool _isAscii(String s) {
    for (final c in s.codeUnits) {
      if (c > 0x7E) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final ascii = _isAscii(label);
    final color =
        Theme.of(context).colorScheme.onSurface.withOpacity(0.55);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
      child: Text(
        ascii ? label.toUpperCase() : label,
        style: TextStyle(
          fontFamily: ascii ? 'JetBrainsMono' : null,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: ascii ? 1.2 : 0,
          height: 1.0,
        ),
      ),
    );
  }
}

// ── Screen ───────────────────────────────────────────────────────────────────

class TunnelFormScreen extends StatefulWidget {
  final TunnelFormArgs args;

  const TunnelFormScreen({super.key, required this.args});

  @override
  State<TunnelFormScreen> createState() => _TunnelFormScreenState();
}

class _TunnelFormScreenState extends State<TunnelFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _localPortCtrl = TextEditingController(text: '8080');
  final _remoteHostCtrl = TextEditingController(text: 'localhost');
  final _remotePortCtrl = TextEditingController(text: '80');
  final _labelCtrl = TextEditingController();

  TunnelDirection _direction = TunnelDirection.local;
  Server? _selectedServer;
  List<Server> _servers = [];
  bool _submitting = false;
  bool _autoStart = false;

  /// 本次从粘贴导入里解析到的字段名，用于给对应输入框加视觉标记。
  Set<String> _importedFields = const {};

  /// 打开粘贴导入面板。
  ///
  /// 与服务器表单共用同一个 [ConfigPasteSheet]，只是这边接的是
  /// `onApplyTunnel` 而不是 `onApplyServer` —— 同一段 `ssh -L ... user@host`
  /// 两边都能解析，各取所需。
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
        // 这个面板在转发表单里打开时，服务器草稿没有去处 —— 用户要的是
        // 那条转发规则。空实现而不是报错：同一段命令同时含两者是常态。
        onApplyServer: (_) {},
        onApplyTunnel: (draft) {
          Navigator.pop(context);
          _applyTunnelDraft(draft);
        },
      ),
    );
  }

  void _applyTunnelDraft(TunnelDraft draft) {
    final a = TunnelDraftApplication.from(draft, _servers);
    setState(() {
      _direction = a.direction;
      _localPortCtrl.text = a.localPort;
      _remoteHostCtrl.text = a.remoteHost;
      _remotePortCtrl.text = a.remotePort;
      _importedFields = a.highlightedFields;
      // 匹配不上就保持原样，让用户自己在下拉里选。
      if (a.matchedServer != null) _selectedServer = a.matchedServer;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.importApplied)),
    );
  }

  @override
  void initState() {
    super.initState();
    _selectedServer = widget.args.server;
    if (_selectedServer == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadServers());
    }
  }

  Future<void> _loadServers() async {
    final servers = await context.read<ServerRepository>().findAll();
    if (mounted) setState(() => _servers = servers);
  }

  String _autoLabel() {
    if (_direction == TunnelDirection.socks5) {
      return 'SOCKS5 :${_localPortCtrl.text}';
    }
    final remote = '${_remoteHostCtrl.text}:${_remotePortCtrl.text}';
    return _direction == TunnelDirection.local
        ? 'localhost:${_localPortCtrl.text} → $remote'
        : '$remote → localhost:${_localPortCtrl.text}';
  }

  Future<void> _submit({required bool save}) async {
    if (!_formKey.currentState!.validate()) return;
    final server = _selectedServer;
    if (server == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.pleaseSelectServer)));
      return;
    }

    setState(() => _submitting = true);

    final mgr = context.read<TunnelManager>();
    final storage = context.read<SecureStorageService>();
    final localPort = int.parse(_localPortCtrl.text);
    final remotePort =
        _direction == TunnelDirection.socks5 ? 0 : int.parse(_remotePortCtrl.text);
    final remoteHost =
        _direction == TunnelDirection.socks5 ? '' : _remoteHostCtrl.text;
    final label = _labelCtrl.text.isEmpty ? _autoLabel() : _labelCtrl.text;

    TunnelEntry entry;
    if (save) {
      entry = await mgr.saveAndAdd(
        existingClient: widget.args.existingClient,
        server: server,
        storage: storage,
        direction: _direction,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort,
        label: label,
        autoStart: _autoStart,
      );
    } else if (widget.args.existingClient != null) {
      entry = await mgr.addTunnel(
        existingClient: widget.args.existingClient!,
        server: server,
        direction: _direction,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort,
        label: label,
      );
    } else {
      entry = await mgr.addTunnelForServer(
        server: server,
        storage: storage,
        direction: _direction,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort,
        label: label,
      );
    }

    if (!mounted) return;
    setState(() => _submitting = false);

    if (entry.status == TunnelStatus.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(context.l10n.tunnelFailed(entry.errorMessage ?? ''))),
      );
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _localPortCtrl.dispose();
    _remoteHostCtrl.dispose();
    _remotePortCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  // ── Mono field style ─────────────────────────────────────────────────────

  InputDecoration _monoDecoration(String label,
      {String? hint, bool highlighted = false}) {
    const accent = Color(0xFF00C896);
    return InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      // 粘贴导入解析到的字段：边框用 accent 色高亮。
      enabledBorder: highlighted
          ? const OutlineInputBorder(
              borderSide: BorderSide(color: accent, width: 1.2))
          : null,
      suffixIcon: highlighted
          ? const Icon(Icons.auto_awesome, size: 16, color: accent)
          : null,
      isDense: true,
      labelStyle: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    const accent = Color(0xFF00C896);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.newTunnel),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            OutlinedButton.icon(
              onPressed: _openPasteImport,
              icon: const Icon(Icons.content_paste_go),
              label: Text(context.l10n.importPasteTitle),
            ),
            const SizedBox(height: 12),

            // ── CONNECTION ───────────────────────────────────────────────
            const _SectionHeader('CONNECTION'),

            // Server selector
            if (widget.args.server == null) ...[
              DropdownButtonFormField<Server>(
                value: _selectedServer,
                hint: Text(
                  l.selectServer,
                  style: const TextStyle(
                      fontFamily: 'JetBrainsMono', fontSize: 12.5),
                ),
                decoration: _monoDecoration(l.selectServer),
                items: _servers
                    .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(
                            '${s.name}  ${s.username}@${s.host}',
                            style: const TextStyle(
                                fontFamily: 'JetBrainsMono', fontSize: 12.5),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: (s) => setState(() => _selectedServer = s),
                validator: (v) => v == null ? l.required : null,
              ),
            ] else ...[
              // Pre-selected server display
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: cs.surfaceVariant.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: cs.onSurface.withOpacity(0.08), width: 0.5),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: cs.surfaceVariant.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: cs.onSurface.withOpacity(0.08), width: 0.5),
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.dns_outlined,
                          size: 16, color: cs.onSurface.withOpacity(0.75)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.args.server!.name,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${widget.args.server!.username}@${widget.args.server!.host}',
                            style: TextStyle(
                              fontFamily: 'JetBrainsMono',
                              fontSize: 11.5,
                              color: cs.onSurface.withOpacity(0.6),
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // ── PORTS ────────────────────────────────────────────────────
            const _SectionHeader('PORTS'),

            // Direction toggle
            SegmentedButton<TunnelDirection>(
              segments: [
                ButtonSegment(
                    value: TunnelDirection.local,
                    label: Text(l.tunnelDirLocal),
                    icon: const Icon(Icons.arrow_forward, size: 16)),
                ButtonSegment(
                    value: TunnelDirection.remote,
                    label: Text(l.tunnelDirRemote),
                    icon: const Icon(Icons.arrow_back, size: 16)),
                const ButtonSegment(
                    value: TunnelDirection.socks5,
                    label: Text('SOCKS5'),
                    icon: Icon(Icons.public, size: 16)),
              ],
              selected: {_direction},
              onSelectionChanged: (sel) =>
                  setState(() => _direction = sel.first),
            ),
            const SizedBox(height: 6),
            Text(
              _direction == TunnelDirection.local
                  ? l.tunnelDescLocal
                  : _direction == TunnelDirection.remote
                      ? l.tunnelDescRemote
                      : l.tunnelDescSocks5,
              style: TextStyle(
                fontSize: 11.5,
                color: cs.onSurface.withOpacity(0.55),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),

            // Local port
            TextFormField(
              controller: _localPortCtrl,
              decoration: _monoDecoration(l.labelLocalPort,
                  highlighted: _importedFields.contains('localPort')),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style:
                  const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n < 1 || n > 65535) {
                  return l.invalidTunnelPort;
                }
                return null;
              },
            ),

            if (_direction != TunnelDirection.socks5) ...[
              const SizedBox(height: 10),
              // Remote host
              TextFormField(
                controller: _remoteHostCtrl,
                decoration: _monoDecoration(l.labelRemoteHost,
                    highlighted: _importedFields.contains('remoteHost')),
                style:
                    const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
                validator: (v) =>
                    v == null || v.isEmpty ? l.required : null,
              ),
              const SizedBox(height: 10),
              // Remote port
              TextFormField(
                controller: _remotePortCtrl,
                decoration: _monoDecoration(l.labelRemotePort,
                    highlighted: _importedFields.contains('remotePort')),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style:
                    const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  if (n == null || n < 1 || n > 65535) {
                    return l.invalidTunnelPort;
                  }
                  return null;
                },
              ),
            ],

            // ── ADVANCED ─────────────────────────────────────────────────
            const _SectionHeader('ADVANCED'),

            // Label (optional)
            TextFormField(
              controller: _labelCtrl,
              decoration: _monoDecoration(l.labelTunnelLabel,
                  hint: l.hintTunnelLabel),
              style:
                  const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
            ),
            const SizedBox(height: 10),

            // Auto-start toggle
            Container(
              decoration: BoxDecoration(
                color: cs.surfaceVariant.withOpacity(0.25),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: cs.onSurface.withOpacity(0.08), width: 0.5),
              ),
              child: SwitchListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                title: Text(l.autoStartTunnel,
                    style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  l.autoStartTunnelDesc,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withOpacity(0.55)),
                ),
                value: _autoStart,
                activeColor: accent,
                onChanged: (v) => setState(() => _autoStart = v),
              ),
            ),
            const SizedBox(height: 24),

            // ── Submit buttons ────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _submitting ? null : () => _submit(save: false),
                    child: Text(l.submitOnce),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: _submitting ? null : () => _submit(save: true),
                    child: _submitting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.black54))
                        : Text(l.submitSaveAndStart),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 把一份 [TunnelDraft] 翻译成转发表单控件需要的字符串。
///
/// 与 `ServerDraftApplication` 同构，但多一件事：把 `serverHostHint` 匹配到
/// 本机已保存的服务器。匹配**不是必须成功的** —— 先拿到一条转发命令、还没加
/// 那台机器是很常见的顺序，匹配不上时留给用户自己选，不是错误。
class TunnelDraftApplication {
  final TunnelDirection direction;
  final String localPort;
  final String remoteHost;
  final String remotePort;

  /// 匹配到的服务器。null = 没匹配上，表单保持未选状态。
  final Server? matchedServer;

  final Set<String> highlightedFields;

  const TunnelDraftApplication({
    required this.direction,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.highlightedFields,
    this.matchedServer,
  });

  factory TunnelDraftApplication.from(TunnelDraft d, List<Server> servers) {
    Server? match;
    final hint = d.serverHostHint;
    if (hint != null && hint.isNotEmpty) {
      for (final s in servers) {
        // host 与 name 都试：用户可能写 `ssh root@10.0.0.6`（host），也可能
        // 写 `ssh root@db-prod`（ssh config 里的别名，本机存成了名字）。
        if (s.host == hint || s.name == hint) {
          match = s;
          break;
        }
      }
    }
    return TunnelDraftApplication(
      direction: d.direction,
      // effectiveLocalPort 已经处理了「两段式写法省略本地端口」的回落。
      localPort: d.effectiveLocalPort?.toString() ?? '',
      remoteHost: d.remoteHost ?? '',
      remotePort: d.remotePort?.toString() ?? '',
      matchedServer: match,
      highlightedFields: d.provenance.keys.toSet(),
    );
  }
}
