// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

/// 一次恢复的结果，与 [AqtDisposition]（见 `aqt_ffi.dart`）三态对应：
/// restored / newSession / tabGone。
///
/// 只留三个具名 factory、私有构造，不让调用方拼出「既 restored 又 tabGone」
/// 之类的非法组合——这类互斥态用 sealed class 更地道，但这里字段少、调用方
/// 只关心「是哪一种」，用 bool 标记 + 单构造省掉一层 switch 样板，权衡后选
/// 这个写法。
class ResumeOutcome {
  /// 会话与 PTY 都还在，服务端已经把恢复负载送出。
  ///
  /// 这里曾经没有独立标记，调用方靠 `scrollbackHeadLine != null` 来判「是否
  /// 已恢复」—— 那个字段随 `FetchScrollback` 通道一起删了。用一个显式 bool
  /// 顶上，而不是换另一个字段去承担同样的隐式含义：三态里「是哪一种」本来
  /// 就该问得直白。
  final bool isRestored;
  final int? exitStatus;
  final bool isNewSession;
  final bool isTabGone;

  const ResumeOutcome._({
    this.isRestored = false,
    this.exitStatus,
    this.isNewSession = false,
    this.isTabGone = false,
  });

  factory ResumeOutcome.restored() => const ResumeOutcome._(isRestored: true);
  factory ResumeOutcome.newSession() =>
      const ResumeOutcome._(isNewSession: true);
  factory ResumeOutcome.tabGone({int? exitStatus}) =>
      ResumeOutcome._(isTabGone: true, exitStatus: exitStatus);
}

/// 恢复发起的合并点。
///
/// 客户端曾经有六个地方各自发 RESUME、各自算 lastOutOff（prewarm /
/// coldHydrate / preSsh / fullreconn / proactive-live / proactive-disk，
/// 见 `resume_issue_log.dart` 文件头注释）——生产日志里出现过 2 秒内三条
/// 连接对同一个 tab 各做一次、三个 offset 分属三个世代。
///
/// offset 那一半已经从协议里整体删除，剩下的「重复发起」这一半由这个类
/// 处理。**它不是字面意义上的唯一入口**——哪些走这里、哪些不走以及为什么，
/// 见下面「谁走这里，谁不走」。
///
/// **因果关系必须搞清楚，这是这个类最容易被误解的地方**：
///
/// 重构后的协议里已经没有 offset——恢复传的是**幂等的屏幕快照**，重复
/// 应用、乱序应用、六路并发应用的结果完全相同。也就是说，即便完全没有
/// 这个 coordinator、六个发起点继续各自裸发 RESUME，结果也是**正确**的，
/// 只是**浪费**：六次网络往返、六份快照、六次终端重绘。
///
/// 这个类要解决的正是那份浪费，不是正确性。它把六次请求合并成一次，但
/// 合并本身不产生任何正确性保证——协议的幂等性才是正确性的来源。
///
/// 这件事反过来说会更清楚：**不能**把这个 coordinator 当成「保证恢复只
/// 发生一次、所以别处不用管时序」的机制去依赖。一旦这样用，就是把正确性
/// 又押回了「谁先谁后」上——而这正是被推翻的上一版设计（offset + 世代
/// 竞态）反复出问题的地方。协议层不能因为客户端有了 coordinator 就退化
/// 成非幂等的，coordinator 也不能被当作弥补非幂等协议的补丁。两者的
/// 依赖方向只能是「幂等允许合并」，不能反过来。
///
/// ## 谁走这里，谁不走
///
/// 接入的是 **prewarm ↔ coldHydrate** 这一对。它们之间原来没有任何共享
/// 状态：prewarm 在 `main.dart` 里、跑在 `ReconnectService` 存在**之前**，
/// 两边各自从磁盘加载同一份会话状态、各发一个 RESUME，用同一个 token ——
/// 生产日志里 23 次同秒双连接就是这么来的。
///
/// 其余四个发起点**刻意不接**，因为它们之间的并发已经被既有守卫覆盖，
/// 接进来是零收益、负代价：
///
/// * `proactive/live` 与 `proactive/disk` 不是两个发起点，是同一次发起的
///   两种参数来源（内存里还被引用着的 transport 残留优先，磁盘兜底）。
///   `_proactiveResuming` 保证同一 tab 只有一次在飞。
/// * `coldHydrate` / `preSsh` / `fullreconn` 同在 `_reconnectWithRetry` 里，
///   `_retrying` 保证同一 tab 串行；而且三者是**回退链的先后阶段**
///   （preSsh 失败才走 SSH，SSH 完成才 fullreconn），天然不并发。
/// * proactive 与重连链之间由
///   `_proactiveResuming` / `_reconnecting` / `_retrying` 三者交叉检查挡住，
///   每个入口（onDisconnected / onSessionDead / 网络切换 / 恢复定时器）都查。
///
/// 而强行接入要付两样代价：`decideResumeRetry` 硬依赖
/// `AqtResumeFailReason` 区分「路径还没通」（可重试）和「会话没了」
/// （不可重试），[ResumeOutcome] 表达的却是「连上之后服务端的处置」——
/// 要接就得把传输层失败原因塞进来，让这个类从「协调发起」扩张成「传递
/// 传输层细节」；另外 `preSsh` 的凭据取自内存 transport 对象，改走磁盘会
/// 在「新会话刚建立、尚未持久化」的窗口里用错 token。
///
/// 归根结底：协议幂等之后并发 RESUME 不再影响正确性，这个类消除的是
/// **浪费**——而那四条路径之间没有实际的浪费可消除。
///
/// 因此 [ensureResumed] **不判断「要不要 resume」——总是 resume**。任何
/// 「这次可以跳过」的判断，都需要先回答「我现在是什么状态、上次恢复到
/// 哪了」，而那个问题的答案正是旧实现里 offset 扮演的角色。跳过判断＝
/// 重新引入 offset 的近亲。合并请求可以做（且应该做，为了省网络），跳过
/// 请求不能做。
class SessionResumeCoordinator {
  final Future<ResumeOutcome> Function(String tabId) _doResume;

  /// tabId → 正在进行的恢复。只用来合并**在途**请求，不是结果缓存——见
  /// [ensureResumed] 里的移除逻辑。
  final Map<String, Future<ResumeOutcome>> _inFlight = {};

  SessionResumeCoordinator({
    required Future<ResumeOutcome> Function(String tabId) doResume,
  }) : _doResume = doResume;

  /// 确保 [tabId] 已恢复。同一 tab 的并发调用共享同一次 RESUME——包括
  /// 失败：一起成功或一起失败，不会有人只拿到半个结果。不同 tab 之间
  /// 互不影响，各自独立发起、独立完成。
  ///
  /// 完成（无论成功还是失败）后立即从 in-flight 表里移除：合并的是
  /// *在途请求*，不是*结果*。上一次恢复结束后，下一次调用要真的重新发一次
  /// RESUME，而不是把上次的快照继续复用下去——协议没有「这份快照还新鲜
  /// 吗」的概念，新不新鲜由服务端在下一次 RESUME 里重新给出。
  ///
  /// 失败也从表里移除，这点尤其重要：如果失败的 Future 粘在表里不走，
  /// 一次网络抖动就会把这个 tab 的恢复能力永久禁掉，往后所有 ensureResumed
  /// 调用都会立刻复现同一个旧异常，而不会给 [_doResume] 机会再试一次。
  Future<ResumeOutcome> ensureResumed(String tabId) {
    final existing = _inFlight[tabId];
    if (existing != null) return existing;

    final fut = _doResume(tabId);
    _inFlight[tabId] = fut;
    // whenComplete 返回的是一个新派生的 Future，不是 fut 本身——它的错误
    // 通道和 fut 的错误通道是分开的。fut 已经会被调用方 await/catchError，
    // 但这个派生 Future 没人管，失败时会被判定成「unhandled」并让运行时
    // 打一条虚假的未捕获异常日志。用 .ignore() 显式声明「这个派生 Future
    // 的结果我不关心」，这不影响 fut 本身——调用方依然能拿到（并处理）
    // 原始异常。
    fut.whenComplete(() {
      // 用 identical 判断而不是直接 remove：如果这次恢复完成的同时，
      // 刚好有新的一轮 ensureResumed 已经把表项换成了别的 Future（理论上
      // 不会发生——fut 完成前表项只会是它自己——但保留这层判断防止未来
      // 改动引入的竟态误删别人的在途请求）。
      if (identical(_inFlight[tabId], fut)) _inFlight.remove(tabId);
    }).ignore();
    return fut;
  }
}
