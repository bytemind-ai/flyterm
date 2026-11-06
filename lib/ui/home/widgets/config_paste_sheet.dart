// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../config_import/config_draft.dart';
import '../../../config_import/draft_parser.dart';
import '../../../l10n/l10n.dart';

/// 粘贴导入面板。
///
/// ## 为什么它不认识 `AIProviderService`
///
/// [llmComplete] 是个函数而不是 provider 实例：宿主传 null 就表示「这台设备
/// 没配 AI」，本组件因此一行 null 判断都不需要写 —— 「用 AI 试试」按钮的显隐
/// 直接由它是否为 null 决定。
///
/// ## 为什么解析结果不直接写库
///
/// 它只把 draft 交给 [onApplyServer]，由宿主填进表单让用户确认：
/// 用户必须是按下保存的那个人。
class ConfigPasteSheet extends StatefulWidget {
  /// 用户确定要用某一份服务器草稿时回调。
  final void Function(ServerDraft draft) onApplyServer;

  /// 解析出转发规则时回调。null = 宿主不处理转发（服务器表单就是这种）。
  final void Function(TunnelDraft draft)? onApplyTunnel;

  /// null = 没有可用的 AI，`用 AI 试试` 按钮不出现。
  final Future<String> Function(String prompt)? llmComplete;

  const ConfigPasteSheet({
    super.key,
    required this.onApplyServer,
    this.onApplyTunnel,
    this.llmComplete,
  });

  @override
  State<ConfigPasteSheet> createState() => _ConfigPasteSheetState();
}

class _ConfigPasteSheetState extends State<ConfigPasteSheet> {
  final _ctrl = TextEditingController();
  ConfigParseResult? _result;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _detect() async {
    final r = await parseConfigText(_ctrl.text);
    if (!mounted) return;
    setState(() => _result = r);
    _applyIfSingle(r);
  }

  Future<void> _detectWithAi() async {
    final llm = widget.llmComplete;
    if (llm == null) return;
    setState(() => _busy = true);
    final r = await parseWithLlm(_ctrl.text, llmComplete: llm);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = r;
    });
    _applyIfSingle(r);
  }

  /// 只有一份服务器草稿时直接应用；多份时留给用户选（默默取第一个是不可
  /// 接受的，用户会以为导错了）。
  void _applyIfSingle(ConfigParseResult r) {
    final t = r.tunnel;
    if (t != null && t.isUsable) widget.onApplyTunnel?.call(t);
    if (r.servers.length == 1) widget.onApplyServer(r.servers.single);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final r = _result;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.importPasteTitle,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            maxLines: 6,
            minLines: 3,
            decoration: InputDecoration(
              hintText: l.importPasteHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _detect,
            child: Text(l.importPasteAction),
          ),
          if (r != null) ...[
            const SizedBox(height: 12),
            ..._buildFeedback(l, r),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildFeedback(AppLocalizations l, ConfigParseResult r) {
    final out = <Widget>[];

    // 剥离提示优先于一切：用户必须知道他粘的私钥没有被发出去。
    if (r.strippedPrivateKey) out.add(_note(l.importStrippedKey));
    if (r.strippedPassword) out.add(_note(l.importStrippedPassword));
    if (r.sawInclude) out.add(_note(l.importSawInclude));

    switch (r.outcome) {
      case ParseOutcome.parsed:
        if (r.servers.length > 1) {
          out.add(Text(l.importPickHost));
          for (final d in r.servers) {
            out.add(ListTile(
              dense: true,
              title: Text(d.name ?? d.host ?? ''),
              subtitle: Text(d.host ?? ''),
              onTap: () => widget.onApplyServer(d),
            ));
          }
        } else {
          out.add(_note(l.importApplied));
          // 用长度判断代替 `singleOrNull`：避免给
          // lib/ui/home/widgets/ 引入新的 package:collection 依赖。
          if (r.servers.length == 1 && r.servers.first.needsManualKey) {
            out.add(_note(l.importNeedsManualKey));
          }
        }
      case ParseOutcome.needsLlm:
        out.add(_note(l.importNotRecognized));
        out.add(_note(l.importFormatExamples));
        if (widget.llmComplete != null) {
          out.add(TextButton(
            onPressed: _busy ? null : _detectWithAi,
            child: Text(l.importTryAi),
          ));
        }
      case ParseOutcome.failed:
        out.add(_note(l.importAiFailed));
        out.add(_note(l.importFormatExamples));
    }
    return out;
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(color: Colors.grey)),
      );
}
