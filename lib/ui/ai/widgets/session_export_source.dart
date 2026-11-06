// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';

import '../../../ai/agent/agent_events.dart';

/// 导出某一段会话时，事件该从哪来。
///
/// **这条判断两个入口（终端页 AI 面板 / 全局 AI 页）各写过一遍**，收口成
/// 一份，免得两边漂移 —— 它的分支不算复杂，但错一半的后果是**静默**的：
/// 回表读到的是节流落盘的版本，会缺最近几轮，用户看不出来。
@immutable
class SessionExportSource {
  const SessionExportSource({required this.events, required this.fromMemory});

  /// 要导的事件。
  final List<AgentEvent> events;

  /// true = 读的是内存里正在跑的那份（`AgentLoop.events`）。
  final bool fromMemory;
}

/// 决定导出哪一份事件。
///
/// 规则：**被导的那一段恰好是当前活跃段时走内存，其余回表。**
///
/// 理由是活跃段按 `updated_at DESC` 排在历史列表**第一条**，是最容易被点到
/// 的那一条；而回表读到的是节流落盘的版本（见 `AgentSessionManager` 的
/// `_kPersistThrottle`），会缺最近几轮，且用户完全看不出来。静默的数据缺失
/// 比少一个入口糟糕得多。
///
/// **`archiveById` 而不是 `takeById`**：后者会把这一行认领为活跃段，导致当前
/// 正在跑的会话之后的落盘错位到这一行上。
///
/// [archive] 由调用方回表取好传进来（这个函数不做 IO，便于测试 —— 也因为它
/// 要能被 widget 与纯函数两种调用点共用）。archive 为 null 或结构畸形时给
/// 空列表，不抛：那一行可能已经被删掉，为这个窄窗口崩掉导出路径不值得。
///
/// **`filenameHint` 由调用方给，不在这里拼 `session_$id`。** 两个入口对
/// 「活跃段」用的文件名与「历史某段」不同（终端页用服务器名、全局页用
/// `global_session`），这层差异属于调用点，不属于「取哪份事件」这件事。
SessionExportSource exportEventsFor({
  required int id,
  required int? activeRowId,
  required List<AgentEvent> liveEvents,
  Map<String, dynamic>? archive,
}) {
  if (activeRowId == id) {
    return SessionExportSource(events: liveEvents, fromMemory: true);
  }
  final raw = archive?['events'];
  final events = raw is List
      ? agentEventsFromJson(raw)
      : const <AgentEvent>[];
  return SessionExportSource(events: events, fromMemory: false);
}
