// SPDX-License-Identifier: GPL-3.0-or-later
import 'config_draft.dart';
import 'llm_draft_parser.dart';
import 'sensitive_stripper.dart';
import 'ssh_command_parser.dart';
import 'ssh_config_parser.dart';
import 'ssh_forward_parser.dart';

/// 一次解析的结局。
enum ParseOutcome {
  /// 拿到了至少一个可用草稿。
  parsed,

  /// 第 1 层认不出。UI 据此显示「用 AI 试试？」按钮 —— 注意这**不是**错误，
  /// 只是确定性解析器的能力边界。
  needsLlm,

  /// 第 2 层也失败了。
  failed,
}

/// 解析结果。
class ConfigParseResult {
  final ParseOutcome outcome;
  final List<ServerDraft> servers;
  final TunnelDraft? tunnel;
  final bool sawInclude;
  final bool strippedPrivateKey;
  final bool strippedPassword;

  const ConfigParseResult({
    required this.outcome,
    this.servers = const [],
    this.tunnel,
    this.sawInclude = false,
    this.strippedPrivateKey = false,
    this.strippedPassword = false,
  });
}

/// 第 1 层：确定性解析。**永不调用 LLM**，哪怕调用方传了 [llmComplete]。
///
/// [llmComplete] 之所以仍在签名里，是为了让调用方能用同一个参数表先试这一层、
/// 再在用户点按钮后调 [parseWithLlm] —— 两个函数共用一套参数，调用点不必准备
/// 两组不同的东西。
///
/// ## 为什么第 2 层不在这里自动触发
///
/// 成本必须可见：用户粘错东西（比如一段日志）时不该平白产生费用，
/// 而「认不出」本身恰恰是最可能粘错的时候。
Future<ConfigParseResult> parseConfigText(
  String input, {
  Future<String> Function(String prompt)? llmComplete,
}) async {
  final stripped = stripSensitive(input);
  final text = stripped.text;

  // ssh config 优先：它能一次产出多台，信息量最大。
  final cfg = parseSshConfigDetailed(text);
  if (cfg.drafts.any((d) => d.isUsable)) {
    return ConfigParseResult(
      outcome: ParseOutcome.parsed,
      servers: cfg.drafts.where((d) => d.isUsable).toList(),
      tunnel: parseSshForward(text),
      sawInclude: cfg.sawInclude,
      strippedPrivateKey: stripped.strippedPrivateKey,
      strippedPassword: stripped.strippedPassword,
    );
  }

  final cmd = parseSshCommand(text);
  if (cmd != null && cmd.isUsable) {
    return ConfigParseResult(
      outcome: ParseOutcome.parsed,
      servers: [cmd],
      tunnel: parseSshForward(text),
      sawInclude: cfg.sawInclude,
      strippedPrivateKey: stripped.strippedPrivateKey,
      strippedPassword: stripped.strippedPassword,
    );
  }

  // 只有转发、没有服务器 —— 仍算成功，UI 会引导用户选一台已存的机器。
  final fwd = parseSshForward(text);
  if (fwd != null && fwd.isUsable) {
    return ConfigParseResult(
      outcome: ParseOutcome.parsed,
      tunnel: fwd,
      sawInclude: cfg.sawInclude,
      strippedPrivateKey: stripped.strippedPrivateKey,
      strippedPassword: stripped.strippedPassword,
    );
  }

  return ConfigParseResult(
    outcome: ParseOutcome.needsLlm,
    sawInclude: cfg.sawInclude,
    strippedPrivateKey: stripped.strippedPrivateKey,
    strippedPassword: stripped.strippedPassword,
  );
}

/// 第 2 层：LLM 兜底。**只应在用户显式点击后调用。**
///
/// 剥离在这里**再跑一次**而不是信任调用方：这个函数是把文本发给第三方服务的
/// 唯一出口，安全边界应当由出口自己守，不依赖调用顺序正确。重复剥离是幂等的，
/// 成本是一次正则匹配。
Future<ConfigParseResult> parseWithLlm(
  String input, {
  required Future<String> Function(String prompt) llmComplete,
}) async {
  final stripped = stripSensitive(input);
  final draft = await llmParseServerDraft(
    stripped.text,
    complete: llmComplete,
  );
  if (draft == null) {
    return ConfigParseResult(
      outcome: ParseOutcome.failed,
      strippedPrivateKey: stripped.strippedPrivateKey,
      strippedPassword: stripped.strippedPassword,
    );
  }
  return ConfigParseResult(
    outcome: ParseOutcome.parsed,
    servers: [draft],
    strippedPrivateKey: stripped.strippedPrivateKey,
    strippedPassword: stripped.strippedPassword,
  );
}
