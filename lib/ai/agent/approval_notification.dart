// SPDX-License-Identifier: GPL-3.0-or-later
/// 是否该为一条待审批推系统通知。
///
/// 前台抑制的判据是「用户此刻是不是正看着这个会话」—— 卡片就在眼前时再弹
/// 一条通知是纯骚扰。切到别的服务器、切到别的 app、锁屏都要弹。
bool shouldNotifyApproval({
  required bool appInForeground,
  required String? visibleServerId,
  required String serverId,
}) {
  if (!appInForeground) return true;
  return visibleServerId != serverId;
}

/// 去重键。由 `AgentSessionManager` 里的内存 `Set<String>` 消费（**不是**
/// 8-16 的 `NotifySeenStore` 200 条窗口 —— 那是给 QUIC notify 离线补投用
/// 的，要持久化；审批没有离线补投语义，进程重启后 loop 本身也没了）。
///
/// 用 callId 而非命令内容 —— 同一条命令可能合法地被调用两次，那是两次审批。
///
/// **但 callId 单独不够**：`edit_file` 的读、写两个阶段共用同一个 callId
/// （见 `agent_loop.dart` `_executeEditFile` 的说明 —— `_pending` 按 callId
/// 索引的 map 里两个阶段的审批不会同时存在，所以那样写不会互相冲突）。如果
/// 去重键只看 (serverId, callId)，读审批推送通知、把键消费掉之后，写审批
/// ——真正带 diff、真正会改文件的那张卡——就再也推不出通知，agent 无声挂起。
///
/// [ToolCallEvent.seq] 是会话内单调递增的，edit_file 的两个阶段各拿一个
/// 不同的 seq（正是 seq 存在的原因——UI 也用它而不是 callId 做列表 key）。
/// 掺进去重键之后，两个阶段各自独立通知，而同一个 (callId, seq) 组合重复
/// 触发时仍然去重（这是这个机制本来要解决的问题，不能修坏）。
String approvalDedupKey(String serverId, String callId, int seq) =>
    'agent:$serverId:$callId:$seq';

/// 审批通知的通知 id 分配器。
///
/// ## 为什么不是哈希
///
/// 这里曾经是 `Object.hash(serverId, seq) & 0x7fffffff`，两个问题：
///
/// 1. **不同通知可能撞同一个 id。** Android 通知 id 相同即**覆盖** —— 后一条
///    会把前一条顶掉。32 位空间里撞车概率低，但审批通知的唯一性要求不是
///    「概率低」，是「不能覆盖已有的那条」：两台服务器同时等你、命令又不同
///    时撞上，就是一条审批通知静默消失、agent 无声挂起。
/// 2. **它不单调。** `NotificationService.show` 的契约是「同一 eventId 再次
///    展示会覆盖旧的，这是期望行为」—— 那个契约成立的前提是 eventId 只对应
///    一条真实事件，哈希不满足。
///
/// 单调递增计数器两者同时解决。
///
/// ## 为什么不持久化
///
/// 审批没有离线补投语义（进程重启后 loop 本身也没了），通知 id 只需在**本次
/// 进程内**唯一 —— 重启后重新从 1 开始是安全的，因为系统通知栏里旧进程留下
/// 的那几条与新生进程的编号没有语义关联，覆盖它们也不会造成事件丢失（那几条
/// 对应的审批在重启后已不存在）。
class ApprovalNotificationIds {
  int _next = 0;

  /// 分配下一个 id。从 1 开始 —— 0 是「没有通知」的惯用哨兵值。
  ///
  /// 高 32 位裁剪：Android 通知 id 是 32-bit int，长期运行下 2^31 次审批不是
  /// 现实场景，但裁剪成本为零，顺手把不变量钉死。
  int next() {
    _next += 1;
    return _next & 0x7fffffff;
  }
}

/// 系统通知弹不出来时，是否该降级为应用内提示。
///
/// ## 为什么需要这层判定
///
/// `NotificationService.show()` 返回 `false` 表示「确定弹不出来」（权限被拒 /
/// 频道被关）。QUIC notify 那条路径对这个返回值有完整处理（降级 SnackBar、
/// 不 ack、等下轮补投），但**审批这条路曾经把它丢了**：
/// `unawaited(NotificationService.show(...))` —— 返回值直接不要了。
///
/// 后果：权限被拒时审批通知**静默消失且没有任何前台降级**，用户既没收
/// 到锁屏通知、app 里也没提示，只看到 agent 停在那里。审批没有离线补投语义
/// （进程重启 loop 就没了），所以补偿只能是「当场改用别的渠道让用户看见」。
///
/// ## 为什么后台不降级
///
/// 后台时应用内提示挂在用户看不见的页面上，什么也解决不了 —— 此时返回
/// `false` 是为了不让调用方做无用功，而不是「放弃这条通知」。审批卡本身
/// 还在面板里，用户回到 app 自然看得到。
bool shouldFallbackToInApp({
  required bool systemNotificationShown,
  required bool appInForeground,
}) =>
    !systemNotificationShown && appInForeground;

/// 把「已通知过的 key 集合」与「此刻仍在等审批的 key 集合」对账。
///
/// ## 为什么需要它
///
/// `AgentSessionManager._notified` 曾经是个**只加不减**的 `Set<String>`：每
/// 条新审批都把一个 `approvalDedupKey` 塞进去，再没有任何路径把它取出来
/// （只有整个 manager `dispose` 才随对象一起消失）。后果有两层：
///
/// 1. **内存只涨不落。** 长期挂后台的会话里，每条审批留一个字符串，永远不
///    回收。
/// 2. **语义错位。** 这个集合的语义应该是「此刻仍在等审批、且已经通知过」，
///    而不是「历史上出现过的所有审批」。一张已经被用户应答掉的卡不再需要被
///    记住；若它因为任何原因重新进入待审批状态（那是一次**新的**等待），
///    应该重新通知，而不是被一条陈旧的记录永久压住。
///
/// ## 只删不增
///
/// 对账只保留 `notified ∩ stillPending`。`stillPending` 里那些**还没通知过**
/// 的 key 不会被加进来 —— 它们的加入由调用方在真正推送通知时完成。
///
/// 返回新集合，**不修改入参**：调用方可能还在别处持有原来那个。
Set<String> reconcileNotified({
  required Set<String> notified,
  required Set<String> stillPending,
}) =>
    notified.where(stillPending.contains).toSet();
