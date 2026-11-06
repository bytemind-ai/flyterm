// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import '../ai_provider.dart';
import 'agent_instructions.dart' show kMaxInstructionBytes;
import 'agent_loop.dart';
import 'knowledge.dart';
import 'output_sanitizer.dart' show redactSecrets;
import 'skill.dart';

/// 从事件流里榨出提炼所需的素材。
///
/// ## 凭据处理，以及它拦不住什么
///
/// 三处自由文本（意图、动作、结论）都过一遍 `redactSecrets()`。它覆盖
/// key-value（`--password=hunter2`）、URL 凭据（`postgres://u:pw@h`）、
/// auth header 三类。
///
/// **`mysql -phunter2` 这种紧贴 flag 的形式它匹配不到** —— `output_sanitizer`
/// 的注释里把这条列为已知限制，说明由 deny 清单侧负责。但 deny 清单是
/// 审批侧的（拦住不该跑的命令），不是打码侧的：用户手动批准跑过的那条
/// 命令会原样到这里。
///
/// 这件事在自动沉淀里比在一次性对话里严重：对话里的凭据随归档消失、会被
/// compaction 回收；沉淀之后它变成每轮索引可见、可被 `load_skill` 取出、
/// 可随 skill 导出的**持久资产**。兜底是卡片展示正文全文那一道人工闸门，
/// 别在这里假装已经拦干净了。
KnowledgeDistillInput buildDistillInput({
  required List<AgentEvent> events,
  required List<SkillIndexEntry> existingSkills,
  required String? currentMachineNotes,
}) {
  var goal = '';
  var conclusion = '';
  final actions = <String>[];

  for (final e in events) {
    switch (e) {
      // 第一句：这次排查是冲什么去的。后续追问不算——那是过程，不是目标。
      case UserTurnEvent(:final text):
        if (goal.isEmpty) goal = text.trim();
      // 最后一句：模型给的结论。中间的思考过程对提炼没有增量。
      case AssistantTextEvent(:final text):
        if (text.trim().isNotEmpty) conclusion = text.trim();
      case ToolCallEvent ev:
        if (ev.status != ToolCallStatus.done) continue;
        final desc = ev.description.trim();
        actions.add(
            desc.isEmpty ? ev.displayCommand : '$desc :: ${ev.displayCommand}');
      default:
        break;
    }
  }

  final used = utf8.encode(currentMachineNotes ?? '').length;

  return KnowledgeDistillInput(
    userGoal: redactSecrets(goal).text,
    actions: actions.map((a) => redactSecrets(a).text).toList(growable: false),
    conclusion: redactSecrets(conclusion).text,
    existingSkills: existingSkills,
    currentMachineNotes: currentMachineNotes,
    machineNotesRemainingBytes:
        used >= kMaxInstructionBytes ? 0 : kMaxInstructionBytes - used,
  );
}

/// 一次独立的提炼调用。
///
/// 走 `AIProvider.complete()` 而不是 `completeWithTools()`：不需要工具、
/// 不需要流式，而 `complete` 是抽象基类的必实现方法，三家 provider 都有
/// ——包括 Ollama 上的本地小模型。
///
/// **不持有 `AgentLoop`**：它只吃一个纯数据的 input、吐一组候选，因此能被
/// 单测直接构造。loop 那边通过注入的回调用它。
class KnowledgeDistiller {
  /// 现取而非定死 —— 与 `AgentLoop.providerProvider` 同理由：用户换 provider
  /// 之后，这次提炼也该用新的。
  final AIProvider Function() _providerProvider;

  const KnowledgeDistiller(this._providerProvider);

  Future<List<KnowledgeCandidate>> distill(KnowledgeDistillInput input) async {
    try {
      final raw = await _providerProvider().complete([
        AIMessage(role: 'system', content: _systemPrompt(input)),
        AIMessage(role: 'user', content: _userPrompt(input)),
      ]);
      return parseDistillCandidates(
        raw,
        existingSkillNames:
            input.existingSkills.map((e) => e.name).toList(growable: false),
      );
    } catch (_) {
      // 网络失败、429、provider 不支持、超时——一律当作「这次没有提议」。
      // 见类文档：用户不该知道它发生过。
      return const [];
    }
  }

  String _systemPrompt(KnowledgeDistillInput input) {
    final buf = StringBuffer();
    buf.writeln(
        'You extract reusable operations knowledge from a finished '
        'troubleshooting session. Output ONLY a JSON array — no prose, no '
        'markdown fences.');
    buf.writeln();
    buf.writeln('Each element has: `target`, `name`, `description`, `body`.');
    buf.writeln(
        '- `target: "skill"` — a reusable PROCEDURE that would apply on any '
        'machine. `name` is a short slug like `nginx-502`. `description` is '
        'ONE line saying WHEN it applies (not what it contains) — it stays in '
        'every future prompt, so keep it under 200 bytes. `body` is markdown, '
        'max 8 KiB.');
    buf.writeln(
        '- `target: "server_note"` — a FACT about THIS ONE machine (its '
        'conventions, quirks, where things live). `name` is a short heading. '
        '`description` is ignored.');
    buf.writeln();
    buf.writeln(
        'Return at most ONE element per target, and return `[]` when nothing '
        'here is worth keeping. `[]` is the right answer most of the time: a '
        'session that just confirmed something works produces no knowledge.');
    buf.writeln();
    // 防重：让模型复用原名，这样 upsert 撞得上、走更新而不是新建一个
    // 名字略有不同的兄弟。
    if (input.existingSkills.isNotEmpty) {
      buf.writeln(
          'The user already has these skills. If what you learned overlaps '
          'with one of them, reuse ITS EXACT NAME so the existing skill gets '
          'updated instead of a near-duplicate being created:');
      for (final s in input.existingSkills) {
        buf.writeln('${s.name}: ${s.description}');
      }
      buf.writeln();
    }
    if (input.machineNotesRemainingBytes <= 0) {
      buf.writeln(
          'This machine\'s notes file is FULL — do not return a `server_note` '
          'element.');
    } else {
      buf.writeln(
          'This machine\'s notes file has ${input.machineNotesRemainingBytes} '
          'bytes left; keep any `server_note` body well under that.');
    }
    buf.writeln();
    // 第 2 道凭据防线。第 1 道（redactSecrets）拦不住紧贴 flag 的形式，
    // 第 3 道是用户在卡片上看到正文全文。
    buf.writeln(
        'NEVER copy credentials, tokens, or passwords into your output — use '
        'placeholders like `<password>` instead, even if you see real values '
        'in the commands below.');
    return buf.toString();
  }

  String _userPrompt(KnowledgeDistillInput input) {
    final buf = StringBuffer();
    buf.writeln('## What the user asked');
    buf.writeln(input.userGoal);
    buf.writeln();
    buf.writeln('## What was done');
    for (final a in input.actions) {
      buf.writeln('- $a');
    }
    buf.writeln();
    buf.writeln('## Conclusion');
    buf.writeln(input.conclusion);
    return buf.toString();
  }
}
