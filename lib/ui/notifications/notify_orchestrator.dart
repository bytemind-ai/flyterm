// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../../util/dlog.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../ssh/session_manager.dart';
import '../../ssh/aqt/aqt_transport.dart' show AqtTransport;
import '../../ssh/aqt/aqt_ffi.dart' show NotifyPayload;
import '../../ssh/aqt/notify_dedup.dart';
import '../../ssh/aqt/notify_deep_link.dart';
import '../../ssh/aqt/notify_format.dart';
import '../../ssh/aqt/notify_seen_store.dart';
import '../../ssh/notification_service.dart';
import '../terminal/split_manager.dart';
import '../terminal/terminal_screen.dart';

/// widget 层的通知编排：把服务端推来的 [NotifyPayload] 决策成
/// "展示什么/怎么展示"，展示成功后才持久化去重窗口 + ack。
///
/// ## 为什么是 widget 层，而不是塞进 ReconnectService
///
/// 判定要不要抑制系统通知（10.2 步骤 2）需要知道分屏副屏/悬浮窗当前显示的
/// 是哪个 tab——这个信息只有 [SplitManager] 有。[SplitManager] 是分屏/悬浮
/// 窗状态的唯一持有者，且是本 app 里少数几个"故意"延迟到 widget 树内部才
/// 构造的单例（`main.dart` 里用 `ChangeNotifierProvider(create: (_) =>
/// SplitManager())`，不同于 `SessionManager`/`ReconnectService` 等在
/// `main()` 里提前构造再 `.value` 注入的模式）。要在 `main()`（widget 树外）
/// 拿到 [SplitManager] 实例就必须改动它的构造时机——而它是分屏/悬浮窗生命周
/// 期的承重结构，通知只是一个附加功能，没有资格让它的生命周期跟着改变。
///
/// 因此本类不在 `main()` 里持有 [SplitManager]，而是在需要判定的那一刻，
/// 通过 [navigatorKey].currentContext 里的 `Provider.of<SplitManager>` 现取。
/// [AqtTransport.onNotify] → [ReconnectService.registerAqtTab] 转发 →
/// [SessionManager.publishNotify] 这条链路把事件从 widget 树外带到这里。
///
/// ## Ack 时序（硬约束）
///
/// [_handleNotify] 只有在展示环节（系统通知或应用内 SnackBar）成功完成、且
/// 去重窗口持久化写入成功之后，才会调用 [AqtTransport.ackNotify]。中途任何
/// 一步抛异常都会被最外层 try/catch 吞掉且**不会** ack——服务端队列不会被
/// 清理，下次重连会重新推送这条事件（宁可重复展示，不可静默丢失）。
///
/// "展示成功"不是"[NotificationService.show] 没抛异常"——Android 的
/// `notify()` 在权限缺失/频道被禁用时同样不抛异常，只是静默不显示。
/// [NotificationService.show] 因此显式检查并返回 `bool`；这里据此决定是否
/// 需要降级为应用内提示，以及最终是否允许 remember/ack。
class NotifyOrchestrator with WidgetsBindingObserver {
  final SessionManager sessionManager;
  final GlobalKey<NavigatorState> navigatorKey;
  final NotifySeenStore _seenStore;

  bool _appInForeground = true;
  bool _started = false;

  /// 按 tab.id 串行化 [_handleNotifyLocked]：同一 tab 几乎同时收到两条
  /// Notify 时，两次 load→modify→save 可能交织，后写覆盖先写会冲掉部分
  /// remember 记录（最坏后果是下次重连多弹一次，落在"重复可接受，静默丢失
  /// 才不可接受"的既定取舍范围内，但序列化成本很低，顺手做掉）。不同 tab
  /// 之间不互相阻塞——scope 改成按 tab 之后竞态面本身已经比按 server 小
  /// 很多，这里只是把剩下的同 tab 竞态也堵上。
  final Map<String, Future<void>> _tabLocks = {};

  NotifyOrchestrator({
    required this.sessionManager,
    required this.navigatorKey,
    NotifySeenStore? seenStore,
  }) : _seenStore = seenStore ?? NotifySeenStore();

  // ── 供审批通知用的只读暴露 ────────────────────────────────────────────────
  //
  // agent 审批的前台抑制判定（`shouldNotifyApproval`）留在调用方
  // （main.dart），不搬进本类——搬进来的话这里就要同时认识 agent 审批和
  // QUIC notify 两套本来无关的东西。这里只加两个只读 getter。

  /// 当前 app 是否在前台（由 [didChangeAppLifecycleState] 维护）。
  bool get appInForeground => _appInForeground;

  /// 「用户此刻正看着哪个服务器」的最小正确映射。
  ///
  /// 本类本身只认识 tab（通过 [sessionManager] + widget 树里的
  /// `SplitManager`），并不知道 AI 面板是否真的展开——那是
  /// `_TerminalScreenState._aiPanelOpen`，一个纯 widget-local 的
  /// `setState` 布尔值，没有经任何 Provider 暴露出来，也不该为了这一个
  /// 判定就把它提升成跨 widget 状态。用当前 activeTab 的 server 作为
  /// 「可见服务器」是能拿到的最小正确近似：切到别的服务器的 tab 就不算
  /// 「正看着」；只要还停在这个服务器的任意 tab 上（哪怕 AI 面板当下没
  /// 展开）就当作「正看着」——错的方向是少弹一次通知，不是重复骚扰用户，
  /// 可接受。
  String? get visibleServerId => sessionManager.activeTab?.server.id;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    sessionManager.addNotifyListener(_handleNotify);
    NotificationService.onTap = _handleTap;
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    sessionManager.removeNotifyListener(_handleNotify);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 独立于 ReconnectService 自己的前后台跟踪（那份是给重连/watchdog 用
    // 的），不复用是为了不去动那条已经在承重的既有逻辑。
    if (state == AppLifecycleState.resumed) {
      _appInForeground = true;
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _appInForeground = false;
    }
  }

  /// 当被 [ReconnectService]（透过 [SessionManager.publishNotify]）通知时
  /// 调用。按 [tab.id] 把实际处理串行化，避免同一 tab 并发到达的两条
  /// Notify 交织写坏去重窗口（见 [_tabLocks] 文档）。
  Future<void> _handleNotify(SessionTab tab, NotifyPayload payload) {
    final key = tab.id;
    final prior = _tabLocks[key] ?? Future<void>.value();
    final chained = prior
        .catchError((_) {}) // 上一条的失败不该连带阻塞这一条
        .then((_) => _handleNotifyLocked(tab, payload));
    _tabLocks[key] = chained;
    return chained;
  }

  Future<void> _handleNotifyLocked(SessionTab tab, NotifyPayload payload) async {
    try {
      // 去重窗口按 tab 作用域，不是按 server：event_id 的编号空间绑定在
      // QUIC session 上，每个 tab 各自一条独立连接 = 各自一个 session，
      // 同一服务器上不同 tab 的 event_id 互相之间没有可比性（详见
      // notify_seen_store.dart 顶部注释）。这里曾经错误地用 serverId 做
      // key，会导致"同一服务器开两个 tab"这种日常操作下，新 tab 真实全新
      // 的通知被另一个 tab 早就记过的号码误判为"已展示过"而永久静默丢弃。
      final seenKey = tab.id;
      final seen = await _seenStore.load(seenKey);
      if (!NotifyDedup.shouldShow(seen, payload.eventId)) {
        return; // 已展示过，丢弃（ack 由首次展示时那次负责，这里不重复 remember/ack）。
      }

      final targetTabId = _resolveTargetTabId(tab.server.id, payload.tabId);
      final visibleTabIds = _computeVisibleTabIds();
      final suppress = NotifyDedup.shouldSuppressSystemNotification(
        appInForeground: _appInForeground,
        visibleTabIds: visibleTabIds,
        targetTabId: targetTabId,
      );

      final content = NotifyFormat.build(
        text: payload.text,
        serverName: tab.server.name,
        tabTitle: _tabTitleFor(targetTabId),
        tsUnixMs: payload.tsUnixMs,
      );

      var displayed = false;
      if (suppress) {
        displayed = _showInAppSnackBar(content);
      }
      if (!displayed) {
        // suppress==false，或者 suppress==true 但没有可用的 BuildContext
        // （理论上不该发生：suppress 为 true 意味着前台且看得见）。
        //
        // NotificationService.show 现在返回 bool：false 表示"确定无法
        // 展示"（Android areNotificationsEnabled()==false，或 flyterm_events
        // 频道被用户单独关闭）。系统级 notify() 本身不会因为权限缺失而抛
        // 异常，若这里盲目当成功处理就会 ack + remember，那条通知会永久
        // 消失且再也不会重试——这正是要堵的洞。
        displayed = await NotificationService.show(
          eventId: payload.eventId,
          text: content.title,
          subtitle: content.body,
          tabId: targetTabId,
        );
        if (!displayed && _appInForeground) {
          // 系统通知被权限/频道设置挡住，但 app 恰好在前台——降级为应用内
          // 提示，好歹让用户当场看到一次。
          displayed = _showInAppSnackBar(content);
        }
      }

      // 展示确实失败（后台 + 系统通知被拒，或前台但拿不到任何可用 UI 承
      // 载）：不 remember、不 ack。服务端队列不清理，下次重连会重新推送
      // ——宁可重复，不可静默丢失。
      if (!displayed) return;

      final updatedSeen = NotifyDedup.remember(seen, payload.eventId);
      await _seenStore.save(seenKey, updatedSeen);

      final transport = tab.transport;
      if (transport is AqtTransport) {
        transport.ackNotify(payload.eventId);
      }
    } catch (e, st) {
      dlog('NotifyOrchestrator',
          '处理 notify eventId=${payload.eventId} 失败，'
          '不 ack，等待下次重连补投: $e\n$st');
      // 埋点上报：C1/C2 都是"表面正常、实际静默丢了"的类型，没有埋点就无法
      // 验证"是否真的从不静默丢失"这条核心承诺。Sentry.captureException 在
      // 未 init（debug build / 无 DSN / 用户未同意崩溃上报）时是 no-op，
      // 不会抛错（同 telemetry/crash_zone.dart 的既有用法）。
      unawaited(Sentry.captureException(e, stackTrace: st));
    }
  }

  String? _resolveTargetTabId(String serverId, int? protocolTabId) {
    final candidates = sessionManager.tabs.map((t) {
      final transport = t.transport;
      final protoId = transport is AqtTransport ? transport.lastTabId : null;
      return TabCandidate(
          tabId: t.id, serverId: t.server.id, protocolTabId: protoId);
    }).toList();
    return NotifyDeepLink.resolveTargetTabId(
      candidates: candidates,
      serverId: serverId,
      protocolTabId: protocolTabId,
    );
  }

  String? _tabTitleFor(String? tabId) {
    if (tabId == null) return null;
    for (final t in sessionManager.tabs) {
      if (t.id == tabId) return t.title;
    }
    return null;
  }

  Set<String> _computeVisibleTabIds() {
    final activeId = sessionManager.activeTab?.id;
    final ctx = navigatorKey.currentContext;
    if (ctx == null) {
      return activeId != null ? {activeId} : <String>{};
    }
    try {
      final splitMgr = Provider.of<SplitManager>(ctx, listen: false);
      return splitMgr.visibleTabIds(activeId);
    } catch (_) {
      return activeId != null ? {activeId} : <String>{};
    }
  }

  bool _showInAppSnackBar(NotifyContent content) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    if (messenger == null) return false;
    messenger.showSnackBar(SnackBar(
      content: Text('${content.title}\n${content.body}'),
      duration: const Duration(seconds: 4),
    ));
    return true;
  }

  // ── Deep link (10.3) ───────────────────────────────────────────────────

  /// 通知被点击时调用（[NotificationService.onTap] 的 payload 就是
  /// [NotifyPayload] 展示时解析出的 target tab id）。
  ///
  /// 只 activate 目标 tab，绝不重排用户已经摆好的分屏/悬浮布局——若目标已经
  /// 在可见集合里（分屏副屏、悬浮窗、或已经是 activeTab），不触碰
  /// SessionManager/SplitManager 的任何状态，只确保 TerminalScreen 在屏幕
  /// 上；否则才调用 setActiveTab 把它带到前台。
  void _handleTap(String? tabId) {
    if (tabId == null) return;
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;

    final idx = sessionManager.tabs.indexWhere((t) => t.id == tabId);
    final visible = _computeVisibleTabIds();
    final action = NotifyDeepLink.decideAction(
      targetTabId: tabId,
      targetTabExists: idx >= 0,
      visibleTabIds: visible,
    );

    switch (action) {
      case NotifyDeepLinkAction.tabNotFound:
        // 用户点了通知，但那个 tab 在通知到达和点击之间被关掉了。这里曾是
        // 静默无操作——用户看到的是「点了通知，什么都没发生」，既不知道为
        // 什么、也不知道该怎么办，很容易当成 app 卡了。给一句提示，告诉他
        // 目标已失效（而非「失败」）。仍然不新建 tab、不退到该服务器其它
        // tab：静默跳到非预期的地方比什么都不做更糟。
        _showInAppMessage(_l10nOf(ctx)?.notifySessionGone);
        return;
      case NotifyDeepLinkAction.promoteToActive:
        sessionManager.setActiveTab(idx);
      case NotifyDeepLinkAction.alreadyVisible:
        break; // 不碰 SessionManager/SplitManager 的任何状态。
    }

    if (!TerminalScreen.isMounted) {
      Navigator.of(ctx).push(
        MaterialPageRoute(builder: (_) => const TerminalScreen()),
      );
    }
  }

  /// 从任意 BuildContext 拿 l10n。拿不到（理论上不该发生）就返回 null，
  /// 调用方据此跳过提示而不是去猜一个语言。
  AppLocalizations? _l10nOf(BuildContext ctx) {
    try {
      return AppLocalizations.of(ctx);
    } catch (_) {
      return null;
    }
  }

  /// 弹一条一次性应用内提示。[message] 为 null 时不做任何事。
  ///
  /// 与 [_showInAppSnackBar] 共用同一条路径的都是「告诉用户发生了什么事」；
  /// 区别只在于本方法只给一行正文、不带标题。
  void _showInAppMessage(String? message) {
    if (message == null) return;
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 4),
    ));
  }
}
