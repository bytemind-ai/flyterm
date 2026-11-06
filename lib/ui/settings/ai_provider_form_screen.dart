// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../ai/ai_provider_service.dart';
import '../../ai/ai_provider.dart';
import '../../data/models/ai_provider_config.dart';
import '../../data/repositories/ai_provider_repository.dart';
import '../../data/secure_storage.dart';
import '../../l10n/l10n.dart';

class AIProviderFormScreen extends StatefulWidget {
  final AIProviderConfig? existing;

  const AIProviderFormScreen({super.key, this.existing});

  @override
  State<AIProviderFormScreen> createState() =>
      _AIProviderFormScreenState();
}

class _AIProviderFormScreenState extends State<AIProviderFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _baseUrlCtrl;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _extraParamsCtrl;
  String _type = 'openai';
  bool _isDefault = false;
  bool _saving = false;
  bool _apiKeyVisible = false;

  static const _typeOptions = ['openai', 'anthropic', 'gemini', 'ollama'];
  static const _accent = Color(0xFF00C896);

  /// OpenAI 兼容端点的快速填充预设。
  ///
  /// 预设的价值全在 [baseUrl]：它稳定，而且是整张表单里最容易抄错的一段。
  /// 注意智谱用 `/api/paas/v4` 而不是 `/v1` —— [OpenAIProvider] 拼的是
  /// `$baseUrl/chat/completions`，不硬塞版本段，所以这类端点能正常工作
  /// （很多工具在这里拼出 `/v4/v1/chat/completions` 然后 404）。
  ///
  /// [model] 相反，是**易变值**。两条实测事实：DeepSeek 在 2026-07-24 退役了
  /// 用了两年的 `deepseek-chat` 别名，Moonshot 在 2026-08-31 下线了整个
  /// `moonshot-v1` 系列。所以表里的值只是「核对日期那天官方文档的推荐值」，
  /// 过期是必然而非意外 —— 靠 model 字段可编辑 + `providerModelVolatileHint`
  /// 那行提示兜住，不要把它当成权威值去做校验或锁定。
  static const _presets = <_ProviderPreset>[
    // 核对日期 2026-09-02，来源为各家官方文档。
    _ProviderPreset('DeepSeek', 'https://api.deepseek.com/v1',
        'deepseek-v4-pro'),
    _ProviderPreset('Qwen',
        'https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen-plus'),
    // Moonshot 的国内与全球是两套独立账号，Key 不通用（填错 host 会 401）。
    // 这里给国内站；全球版是 https://api.moonshot.ai/v1。
    _ProviderPreset('Kimi', 'https://api.moonshot.cn/v1', 'kimi-k3'),
    _ProviderPreset('GLM', 'https://open.bigmodel.cn/api/paas/v4', 'glm-5.1'),
  ];

  /// 填 baseUrl 与 model，顺带填显示名 —— 但**只在显示名为空时**填。
  /// 用户特意起过名字（「生产用的 DeepSeek」）时把它冲掉是纯粹的破坏。
  ///
  /// 不碰 API key：预设与凭据无关，而清空一个已输入的 key 会让编辑场景下
  /// 「点一下预设」变成静默丢凭据。
  void _applyPreset(_ProviderPreset p) {
    setState(() {
      _type = 'openai';
      _baseUrlCtrl.text = p.baseUrl;
      _modelCtrl.text = p.model;
      if (_nameCtrl.text.trim().isEmpty) _nameCtrl.text = p.label;
    });
  }

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _modelCtrl = TextEditingController(text: e?.model ?? '');
    _baseUrlCtrl = TextEditingController(text: e?.baseUrl ?? '');
    _apiKeyCtrl = TextEditingController();
    _extraParamsCtrl = TextEditingController(text: e?.extraParams ?? '');
    if (e != null) {
      _type = e.type;
      _isDefault = e.isDefault;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _modelCtrl.dispose();
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _extraParamsCtrl.dispose();
    super.dispose();
  }

  String _modelHint(String type) {
    switch (type) {
      case 'openai':
        return 'e.g. gpt-4o';
      case 'anthropic':
        return 'e.g. claude-3-5-sonnet-20241022';
      case 'gemini':
        return 'e.g. gemini-2.5-flash';
      case 'ollama':
        return 'e.g. llama3';
      default:
        return '';
    }
  }

  /// baseUrl 输入框的占位提示。
  ///
  /// 必须四家都给对：`_needsBaseUrl` 是恒真的，任何一家都会看到这个框，而
  /// 用户会照抄提示。给错的后果是一个静默坏掉的配置（空着不填反而是对的
  /// —— 各 provider 自己会回退到默认端点）。
  String _baseUrlHint(String type) {
    switch (type) {
      case 'ollama':
        return 'http://localhost:11434';
      case 'anthropic':
        return 'https://api.anthropic.com/v1';
      case 'gemini':
        // 与 GeminiProvider.defaultBaseUrl 一致：不带尾斜杠、不以 /v1 结尾。
        return 'https://generativelanguage.googleapis.com/v1beta/openai';
      default:
        return 'https://api.openai.com/v1';
    }
  }

  bool get _needsApiKey => _type != 'ollama';
  // 四家全部可填：generativelanguage.googleapis.com 与 api.anthropic.com 在
  // 不少网络下不可直达，而这个 App 的用户天然有自己的服务器可做反代。
  bool get _needsBaseUrl => true;

  /// 哪些类型给填 extraParams。
  ///
  /// **必须与 `AIProviderFactory.create` 里转发 `extraParamsJson` 的 case
  /// 集合保持一致**（当前是 openai + gemini）。不一致的方向有两种，都很坏：
  /// 表单给填而 provider 不消费 = 填了没反应；provider 消费而表单不给填 =
  /// 功能只能靠「先建成别的类型填好再切过来」这种没人会发现的路径。
  bool get _needsExtraParams => _type == 'openai' || _type == 'gemini';

  // ── mono input decoration ──────────────────────────────────────────────────
  static InputDecoration _monoDeco({
    required String label,
    String? hint,
    bool alignHint = false,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      alignLabelWithHint: alignHint,
      suffixIcon: suffix,
      // Style set inline via style: on TextFormField
    );
  }

  static const TextStyle _monoStyle = TextStyle(
    fontFamily: 'JetBrainsMono',
    fontSize: 13,
    letterSpacing: 0,
    height: 1.4,
  );

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? l.editProvider : l.addProvider),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            // ── PRESETS ──────────────────────────────────────────────────────
            // 只在新建时出现。编辑已有配置时点一下就会把 baseUrl/model 冲掉，
            // 而那正是用户来这个页面要保护的东西。
            if (!isEdit) ...[
              _SectionHeader(l.providerSectionPresets),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in _presets)
                      ActionChip(
                        label: Text(p.label, style: _monoStyle),
                        onPressed: () => _applyPreset(p),
                      ),
                  ],
                ),
              ),
            ],

            // ── IDENTITY ─────────────────────────────────────────────────────
            _SectionHeader(l.providerSectionIdentity),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextFormField(
                controller: _nameCtrl,
                decoration: InputDecoration(labelText: l.displayName),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? l.required : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: DropdownButtonFormField<String>(
                value: _type,
                decoration: InputDecoration(labelText: l.providerType),
                items: _typeOptions
                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                    .toList(),
                onChanged: (v) => setState(() => _type = v!),
              ),
            ),

            // ── ENDPOINT ──────────────────────────────────────────────────────
            _SectionHeader(l.providerSectionEndpoint),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextFormField(
                controller: _modelCtrl,
                style: _monoStyle,
                decoration: _monoDeco(
                  label: l.model,
                  hint: _modelHint(_type),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? l.required : null,
              ),
            ),
            // 模型名会过期（见 [_presets] 的说明）。与其等用户对着一句
            // 「model not found」猜是自己填错还是服务商改名，不如先说清楚
            // 该去哪里核对。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: Text(
                l.providerModelVolatileHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withOpacity(0.55),
                    ),
              ),
            ),
            if (_needsBaseUrl)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextFormField(
                  controller: _baseUrlCtrl,
                  style: _monoStyle,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  decoration: _monoDeco(
                    label: l.baseUrl,
                    hint: _baseUrlHint(_type),
                  ),
                ),
              ),

            // ── AUTH ──────────────────────────────────────────────────────────
            if (_needsApiKey) ...[
              _SectionHeader(l.providerSectionAuth),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextFormField(
                  controller: _apiKeyCtrl,
                  obscureText: !_apiKeyVisible,
                  style: _monoStyle,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  decoration: _monoDeco(
                    label: isEdit ? l.apiKeyEditHint : l.apiKey,
                    suffix: IconButton(
                      icon: Icon(
                        _apiKeyVisible
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 18,
                        color: cs.onSurface.withOpacity(0.55),
                      ),
                      onPressed: () =>
                          setState(() => _apiKeyVisible = !_apiKeyVisible),
                    ),
                  ),
                  validator: (v) {
                    if (!isEdit && (v == null || v.trim().isEmpty)) {
                      return l.required;
                    }
                    return null;
                  },
                ),
              ),
            ],

            // ── ADVANCED ──────────────────────────────────────────────────────
            if (_needsExtraParams) ...[
              _SectionHeader(l.providerSectionAdvanced),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextFormField(
                  controller: _extraParamsCtrl,
                  style: _monoStyle,
                  maxLines: 3,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  decoration: _monoDeco(
                    label: l.extrasJson,
                    hint: '{"reasoning":{"enabled":true},"temperature":0}',
                    alignHint: true,
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    try {
                      final decoded = _tryParseJson(v.trim());
                      if (decoded == null) return l.invalidJson;
                    } catch (_) {
                      return l.invalidJson;
                    }
                    return null;
                  },
                ),
              ),
            ],

            // ── DEFAULT toggle ────────────────────────────────────────────────
            const SizedBox(height: 8),
            SwitchListTile(
              title: Text(l.setAsDefault),
              dense: true,
              visualDensity: VisualDensity.compact,
              activeColor: _accent,
              value: _isDefault,
              onChanged: (v) => setState(() => _isDefault = v),
            ),

            // ── Save button ───────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(isEdit ? l.save : l.add),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Map<String, dynamic>? _tryParseJson(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final repo = context.read<AIProviderRepository>();
    final storage = context.read<SecureStorageService>();
    final svc = context.read<AIProviderService>();

    final id = widget.existing?.id ?? const Uuid().v4();
    final baseUrl = _baseUrlCtrl.text.trim().isEmpty
        ? null
        : _baseUrlCtrl.text.trim();
    final extraParamsRaw = _extraParamsCtrl.text.trim();
    final config = AIProviderConfig(
      id: id,
      name: _nameCtrl.text.trim(),
      type: _type,
      model: _modelCtrl.text.trim(),
      baseUrl: baseUrl,
      isDefault: _isDefault,
      extraParams: extraParamsRaw.isEmpty ? null : extraParamsRaw,
    );

    if (widget.existing != null) {
      await repo.update(config);
    } else {
      await repo.insert(config);
    }

    final newApiKey = _apiKeyCtrl.text.trim();
    if (newApiKey.isNotEmpty) {
      await storage.saveAIKey(id, newApiKey);
    }

    if (_isDefault) {
      final effectiveKey = newApiKey.isNotEmpty
          ? newApiKey
          : (await storage.loadAIKey(id) ?? '');
      svc.setProvider(AIProviderFactory.create(config, effectiveKey));
    }

    if (mounted) Navigator.of(context).pop();
  }
}

// ── Provider preset ───────────────────────────────────────────────────────────

/// 一条 OpenAI 兼容端点的快速填充项。取值口径见
/// [_AIProviderFormScreenState._presets]。
class _ProviderPreset {
  final String label;
  final String baseUrl;
  final String model;

  const _ProviderPreset(this.label, this.baseUrl, this.model);
}

// ── Section Header ────────────────────────────────────────────────────────────

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
    final color = Theme.of(context).colorScheme.onSurface.withOpacity(0.55);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
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
