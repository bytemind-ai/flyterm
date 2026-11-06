// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../ai/agent/agent_session_manager.dart';
import '../../../ai/agent/agent_tools.dart' show AgentToolTier, resolveToolTier;
import '../../../ai/ai_provider_service.dart';
import '../../../ai/provider_switch.dart';
import '../../../data/models/ai_provider_config.dart';
import '../../../data/repositories/ai_provider_repository.dart';
import '../../../data/secure_storage.dart';
import '../../../l10n/l10n.dart';

enum ModelDisabledReason { noApiKey, noToolSupport }

/// 这一条为什么不能选。null = 可选。
///
/// 判据是「**已知**不支持」，不是「未确认支持」。ollama 的 `supportsTools` 是
/// 运行时可翻转的字段（初值 true，第一次报错后翻 false），那条注释解释了为什么
/// 乐观：「Ollama 的支持名单变化太快，判错就是硬失败」。所以只有当前正在用的
/// 那条实例已经翻转过，才置灰它；其余 ollama 条目一律照常可选。
///
/// [currentToolsSupported] 传当前 provider 实例的 `supportsTools`，且**仅当这
/// 一条就是当前生效的那条**时才传；其余情况传 null。
ModelDisabledReason? modelDisabledReason(
  AIProviderConfig config, {
  required bool hasKey,
  required bool? currentToolsSupported,
}) {
  if (currentToolsSupported == false) return ModelDisabledReason.noToolSupport;
  switch (config.type) {
    case 'ollama':
      return null; // 不需要 key，且支持度只能试出来
    case 'openai':
    case 'anthropic':
    case 'gemini':
      return hasKey ? null : ModelDisabledReason.noApiKey;
    default:
      // 未知类型：AIProviderFactory.create 会直接抛 ArgumentError。
      return ModelDisabledReason.noToolSupport;
  }
}

/// 一条候选模型的展示数据。sheet 只负责渲染，取数与切换都在调用方。
class ModelChoice {
  final AIProviderConfig config;
  final bool isCurrent;
  final ModelDisabledReason? disabled;

  /// 这个模型会落到 lean 工具档吗（只有 bash / read_file / read_terminal）。
  ///
  /// **可选而不可用是两回事，所以它不走 [disabled]。** lean 档的模型完全能用，
  /// 只是少了写文件与文件传输那批工具。把它标出来是因为削减是静默的：切过去
  /// 之后 agent 被要求上传文件时，手上没有 `upload_file`，只会用自然语言接话
  /// （「好的，请选择要上传的文件」），用户看到的是「选择窗不弹了」。
  final bool leanTools;

  const ModelChoice({
    required this.config,
    required this.isCurrent,
    required this.disabled,
    this.leanTools = false,
  });
}

class ModelPickerSheet extends StatelessWidget {
  final List<ModelChoice> choices;
  final void Function(AIProviderConfig) onPick;

  const ModelPickerSheet({
    super.key,
    required this.choices,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(l.aiSwitchModel, style: theme.textTheme.titleMedium),
              ],
            ),
          ),
          ...choices.map((c) {
            final reason = c.disabled;
            // 逐段拼而不是三元套三元：现在有三种可能的后缀（档位、缺 key、
            // 不支持工具），继续套下去就没法读了。
            final sub = <String>[
              c.config.model,
              if (c.leanTools) l.aiModelLeanTools,
              if (reason == ModelDisabledReason.noApiKey) l.aiModelNoApiKey,
              if (reason == ModelDisabledReason.noToolSupport)
                l.aiModelNoToolSupport,
            ];
            return ListTile(
              dense: true,
              enabled: reason == null,
              title: Text(c.config.name),
              subtitle: Text(
                sub.join(' · '),
                style: theme.textTheme.bodySmall,
              ),
              trailing: c.isCurrent
                  ? Icon(Icons.check, color: theme.colorScheme.primary)
                  : null,
              onTap: reason == null
                  ? () {
                      Navigator.pop(context);
                      onPick(c.config);
                    }
                  : null,
            );
          }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// 取出当前所有可选模型，供 [ModelPickerSheet] 渲染。
///
/// 候选的可用性要先异步查一遍 key（`providerUsable`），所以这是个 Future ——
/// 调用方必须先 await 拿到结果、再弹 sheet，不能在 builder 里同步判断。
///
/// 抽到这里是因为全局 AI 页与终端页的 AI 面板都要这份取数逻辑，而它完全不
/// 绑服务器。**只抽取数**：`onPick` 之后的处理两边不同——AI 面板切完模型还要
/// 重算 agent 模式（它有两种模式），全局页只有 direct 一种，不需要那段。
Future<List<ModelChoice>> buildModelChoices(BuildContext context) async {
  final repo = context.read<AIProviderRepository>();
  final storage = context.read<SecureStorageService>();
  final svc = context.read<AIProviderService>();
  // 用户在设置里手动选的档压过自动判定。在 await 之前读掉：await 之后再碰
  // context 就要重新判 mounted，而这个值不会在这几毫秒里变。
  final tierOverride = context.read<AgentSessionManager>().toolTierOverride;
  final configs = await repo.findAll();

  final choices = <ModelChoice>[];
  for (final c in configs) {
    final hasKey = await providerUsable(c, storage);
    // 只有当前生效的那条才把实例的运行时判定传进去 —— 其余条目的
    // supportsTools 无从得知（ollama 要试过才知道）。
    final isCurrent = c.isDefault;
    choices.add(ModelChoice(
      config: c,
      isCurrent: isCurrent,
      disabled: modelDisabledReason(
        c,
        hasKey: hasKey,
        currentToolsSupported: isCurrent ? svc.provider?.supportsTools : null,
      ),
      // 与工具集用同一个判定函数，不在这里重写一遍「ollama 就是 lean」——
      // 那条规则将来若改（比如按模型名细分），两处会立刻漂移。
      leanTools: resolveToolTier(
            providerType: c.type,
            override: tierOverride,
          ) ==
          AgentToolTier.lean,
    ));
  }
  return choices;
}
