// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import '../../../ai/agent/agent_events.dart';

/// 从一段归档 JSON 里抽出这段会话碰过的机器名，**去重保序**。
///
/// 扫的是 `ToolCallEvent.targetServerName` —— 它进归档（见 `agent_events.dart`
/// 该字段的文档），不是从给人看的 `displayCommand` 里解析。
///
/// **任何异常都吞掉并返回空列表**：一条畸形归档不该让整个入口区打不开。
/// 调用方拿到空列表时照常显示会话，只是少一行机器名。
List<String> machinesFromArchive(String archiveJson) {
  try {
    final decoded = jsonDecode(archiveJson);
    if (decoded is! Map) return const [];
    final events =
        agentEventsFromJson((decoded['events'] as List?) ?? const []);
    final out = <String>[];
    for (final e in events) {
      if (e is! ToolCallEvent) continue;
      final n = e.targetServerName;
      if (n != null && n.isNotEmpty && !out.contains(n)) out.add(n);
    }
    return out;
  } catch (_) {
    return const [];
  }
}
