// SPDX-License-Identifier: GPL-3.0-or-later
/// 状态转移轨迹。
///
/// 存在的理由：现有 `resumeIssueLog` 是 20 条的内存环，app 一被杀就没了 ——
/// 这正是前 9 轮稳定性优化"改完无法证明没回归"的直接原因。
///
/// 输出格式与 `test/ssh/aqt/conn/conn_test_dsl.dart` 的 `machineCase` 输入
/// 一一对应：真机复现 → 导出轨迹 → 粘成用例 → 永久回归。
///
/// **隐私**：只记事件类型名、facts 的数值、phase 与 action 类型名。
/// `TransportClosed.reason` 这类可能夹带远端内容的字符串**不记**。
library;

import 'conn_types.dart';

class ConnTrace {
  final int cap;
  final List<String> _lines = [];

  ConnTrace({this.cap = 512});

  List<String> get lines => List.unmodifiable(_lines);

  void record({
    required Event event,
    required Facts facts,
    required ConnPhase from,
    required ConnPhase to,
    required List<Action> actions,
  }) {
    final acts = actions.map((a) => a.runtimeType.toString()).join(',');
    _lines.add('${event.runtimeType} '
        'now=${facts.nowMs} raw=${facts.rawRecvAgeMs} '
        'rebind=${facts.rebindCount} fg=${facts.isForeground} '
        'net=${facts.networkType} '
        '${from.name}→${to.name} [$acts]');
    while (_lines.length > cap) {
      _lines.removeAt(0);
    }
  }

  /// 导出成可粘进测试的文本。落盘由调用方负责（runner 持有 IO）。
  String export() => _lines.join('\n');
}
