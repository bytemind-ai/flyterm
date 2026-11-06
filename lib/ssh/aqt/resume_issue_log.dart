// SPDX-License-Identifier: GPL-3.0-or-later
/// RESUME 发起点埋点缓冲。
///
/// 放在 `ssh/aqt/` 而不是 `ui/terminal/debug_log.dart`：`lib/ssh/` 至今对
/// `lib/ui/` 零依赖（CLAUDE.md 要求这层不带 Flutter 依赖），把缓冲放 ui/ 会
/// 反转依赖方向。反过来 ui/ 依赖 ssh/ 是既有常态（DebugOverlay 已经 read
/// ReconnectService），所以缓冲归 ssh/、由 ui/ 读取。
///
/// 本文件保持纯 Dart，不引入任何 import。
///
/// 存在的理由：服务端日志只看得见"几条连接进来了"，看不见是客户端**哪段代码**
/// 派出去的、带的是**哪一代** last_out_off。生产日志里出现过 2 秒内三条连接对
/// 同一个 tab 各做一次 RESUME、且三者 offset 分属三个世代（见
/// daemon.log 2026-08-18T14:32:09）——只有在客户端发起的那一刻记录，才分得清。
///
/// 客户端有 6 个地方会发 RESUME，各自独立算 lastOutOff：
///   prewarm         main.dart::_prewarmAqtSession（恒发 0 → cold）
///   coldHydrate     ReconnectService 冷启动补水（恒发 0 → cold）
///   preSsh          走 SSH 前的廉价 RESUME
///   fullreconn      完整重连链里的 RESUME
///   proactive/live  探测到 transport 死亡后，用它残留的元数据重试
///   proactive/disk  同上，但元数据从磁盘读
///
/// 时间戳到**毫秒**：上面那次三连全发生在 2 秒内，秒级精度分不出先后。
/// 序号 [_resumeIssueSeq] 单调递增，用来把 ISSUE 和它的 RESULT 配对——并发时
/// 两者不一定相邻。
final resumeIssueLog = <String>[];
const int _kResumeIssueCap = 20;
int _resumeIssueSeq = 0;

/// 清空缓冲与序号。仅供测试——全局状态会在用例之间泄漏。
void resetResumeIssueLog() {
  resumeIssueLog.clear();
  _resumeIssueSeq = 0;
}

String _msStamp() {
  final ts = DateTime.now();
  return '${ts.minute.toString().padLeft(2, "0")}:'
      '${ts.second.toString().padLeft(2, "0")}.'
      '${ts.millisecond.toString().padLeft(3, "0")}';
}

void _pushResumeIssue(String line) {
  resumeIssueLog.add(line);
  if (resumeIssueLog.length > _kResumeIssueCap) resumeIssueLog.removeAt(0);
}

/// 在**发起** RESUME 的那一刻调用。返回本次的序号，调用方拿它去配
/// [appendResumeResult]。
int appendResumeIssue({
  required String site,
  required String tabId,
}) {
  final seq = ++_resumeIssueSeq;
  final tid = tabId.length > 4 ? tabId.substring(0, 4) : tabId;
  // 不再有 off/hash 可记：RESUME 不携带位置信息，六个发起点因此完全同形。
  // 这个埋点原本就是为了分辨「哪个发起点带了哪一代 offset」（见文件头注释
  // 里那次 2 秒内三个世代的事故）—— 那个用途随 offset 一起消失了。
  _pushResumeIssue('${_msStamp()} #$seq→ $site [$tid]');
  return seq;
}

/// 记一条"没有发出 RESUME"的事件（去重命中、无会话信息等）。
///
/// 单列一个函数而不是复用 [appendResumeIssue]，是因为后者会给 off=0 打上
/// COLD 标记——而这里根本没往线上发东西，标 COLD 会把日志读成"又一次冷
/// RESUME"，正好和我们要查的问题混淆。
void appendResumeNote(String note) {
  _pushResumeIssue('${_msStamp()} ·  $note');
}

/// RESUME 落地时调用，[seq] 用 [appendResumeIssue] 的返回值。
/// [replayBytes] 为 null 表示没拿到（失败路径）。
void appendResumeResult({
  required int seq,
  required String outcome,
  int? replayBytes,
}) {
  _pushResumeIssue('${_msStamp()} #$seq← $outcome'
      '${replayBytes != null ? " replay=$replayBytes" : ""}');
}

