// SPDX-License-Identifier: GPL-3.0-or-later
import '../../ai/agent/agent_loop.dart';

/// 每一类「只有最新那个是活的」事件的最后一个实例。
///
/// ## 为什么算一次而不是随用随查
///
/// 原先的写法是在 `itemBuilder` 里 `loop.events.whereType<T>().last`
/// （`agent_view.dart` 的编辑钮与重试钮两处），每个 item 都全表扫一遍，
/// 整体 O(n²) —— 与同一个文件里「分组算一次，别在 itemBuilder 里每次都
/// 算」那条注释直接打架。本类把判定扩展到五种事件，不收口会更糟。
///
/// ## 为什么用 identical 而不是 seq
///
/// `StoppedEvent` / `PlanUpdatedEvent` / `SessionInterruptedEvent` 都
/// **没有 seq 字段**（只有 `ToolCallEvent` / `BackgroundJobEvent` /
/// `TransferEvent` 有）。给它们补 seq 要动事件定义与归档序列化，超出
/// 「本次不碰 agent_loop.dart」的边界。事件对象在 `loop.events` 里是同一
/// 实例，引用比较安全 —— 而且比相等比较更准：内容一模一样的两次
/// `set_plan` 用 `==` 是分不开的。
class LatestEventIndex {
  final PlanUpdatedEvent? planUpdated;
  final StoppedEvent? stopped;
  final SessionInterruptedEvent? interrupted;
  final UserTurnEvent? userTurn;
  final AssistantTextEvent? assistantText;

  const LatestEventIndex({
    this.planUpdated,
    this.stopped,
    this.interrupted,
    this.userTurn,
    this.assistantText,
  });

  factory LatestEventIndex.from(List<AgentEvent> events) {
    PlanUpdatedEvent? plan;
    StoppedEvent? stop;
    SessionInterruptedEvent? interrupted;
    UserTurnEvent? user;
    AssistantTextEvent? assistant;
    for (final e in events) {
      switch (e) {
        case PlanUpdatedEvent():
          plan = e;
        case StoppedEvent():
          stop = e;
        case SessionInterruptedEvent():
          interrupted = e;
        case UserTurnEvent():
          user = e;
        case AssistantTextEvent():
          assistant = e;
        default:
          break;
      }
    }
    return LatestEventIndex(
      planUpdated: plan,
      stopped: stop,
      interrupted: interrupted,
      userTurn: user,
      assistantText: assistant,
    );
  }

  /// 这条事件是不是同类里最新的那个。
  ///
  /// 不参与活性判定的类型一律返回 true —— 调用方可以无条件地问，不必先
  /// 判断类型。
  bool isLatest(AgentEvent e) => switch (e) {
        PlanUpdatedEvent() => identical(e, planUpdated),
        StoppedEvent() => identical(e, stopped),
        SessionInterruptedEvent() => identical(e, interrupted),
        UserTurnEvent() => identical(e, userTurn),
        AssistantTextEvent() => identical(e, assistantText),
        _ => true,
      };
}
