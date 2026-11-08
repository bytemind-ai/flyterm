// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'aqt_route.dart';
import 'aqt_ssh_relay.dart';
import 'aqt_transport.dart';
import 'conn/conn_types.dart';

/// 在**同一条** QUIC 连接里，于直连 UDP 与 SSH 中继之间换路（不重连、不
/// RESUME）。每个 AQT 会话一个，见设计 §4.4。
///
/// - 直连 → 中继：状态机发 `StartPathSwitch` 时 [onStartPathSwitch]。
/// - 中继 → 直连：走中继期间按 [probeIntervals] 探测直连（失败升级、换网或
///   切换成功后归零），探测通过后 `setPath` 过去，[confirmWindow] 内从直连
///   （当前目的地）收到数据报才算数，否则切回中继。
/// - 换网（[onNetworkChanged]）：走中继时立即探测并同时重建中继，谁先成功
///   用谁。走直连时什么都不做 —— `migrateEndpoint()` 仍由调用方负责。
/// - 中继自己断了：走中继时重建并探测；走直连时只清理。
///
/// 所有错误只记日志，不抛给调用方。
class AqtPathController {
  AqtPathController({
    required this._transport,
    required this._openRelay,
    required this._resolveDirect,
    required this._feed,
    required this._onRouteChanged,
    required this._isForeground,
    this._directAllowed = _always,
    this._relayBudget = const Duration(seconds: 8),
    this._confirmWindow = const Duration(seconds: 2),
    this._probeIntervals = const [
      Duration(seconds: 60),
      Duration(seconds: 120),
      Duration(seconds: 300),
    ],
  });

  final AqtTransport _transport;
  final Future<AqtSshRelay> Function(int daemonPort) _openRelay;
  final Future<({String ip, int port})?> Function() _resolveDirect;
  final void Function(Event e) _feed;
  final void Function() _onRouteChanged;
  final bool Function() _isForeground;

  /// 为 false 时（服务器设了「总是走 SSH 通道」）绝不探测、绝不切回直连；
  /// 中继断了照样重建（§4.5）。
  final bool Function() _directAllowed;
  static bool _always() => true;
  final Duration _relayBudget;
  final Duration _confirmWindow;
  final List<Duration> _probeIntervals;

  /// 确认窗口内查 `pathRxFromCurrent` 的间隔。
  static const Duration _confirmStep = Duration(milliseconds: 100);

  bool _disposed = false;
  final Completer<void> _disposeSignal = Completer<void>();

  /// 服务端不支持 relay（或 ForceCommand）：本会话不再尝试切中继（§5）。
  bool _relayUnsupported = false;

  /// 在途的「切到一个新中继」。同一时间只有一个；后来的调用加入它。
  Future<bool>? _relayOp;

  /// 每次真的改了路径（提交）就 +1。在途工作落地时比对它，判断自己是否
  /// 已经被另一边抢先（换网时探测与重建赛跑）。
  int _epoch = 0;

  /// 探测切回直连的确认窗口在途时非 null；重建中继落地要等它结束再决定。
  Completer<void>? _confirming;

  Timer? _probeTimer;
  int _probeLevel = 0;

  /// 每次把 [_probeLevel] 归零（换网）+1，在途探测据此判断还该不该升级。
  int _levelGen = 0;

  /// 原生探测结果槽没有代号：同一时间只允许一次探测。在途时再来的请求只
  /// 记一笔，结束后补一次。
  bool _probing = false;
  bool _probeAgain = false;

  Future<({String ip, int port})?>? _direct;

  final Set<AqtSshRelay> _watched = <AqtSshRelay>{};

  /// 若当前走中继：开始监视它并排第一次探测。
  void start() {
    if (_disposed) return;
    final relay = _transport.relay;
    if (_transport.route == AqtRoute.viaSsh && relay != null) _watch(relay);
    _scheduleProbe();
  }

  /// 状态机的 `StartPathSwitch`。**每次调用恰好喂回一个** `PathSwitched` 或
  /// `PathSwitchFailed` —— 状态机在听到回音前一直认为切换在途。
  Future<void> onStartPathSwitch() async {
    // 请求时刻：中继落地时若这之后直连收到过包，就算直连自己恢复了。
    final requestedAt = clock.now();
    var ok = false;
    try {
      if (_disposed) {
        _log('switch: disposed');
      } else if (_relayUnsupported) {
        _log('switch: relay unsupported on this server, not trying');
      } else if (!_isForeground()) {
        _log('switch: in background, not switching');
      } else {
        ok = await (_relayOp ?? _switchToRelay(requestedAt: requestedAt));
      }
    } catch (e) {
      _log('switch: $e');
      ok = false;
    }
    try {
      _feed(ok ? const PathSwitched() : const PathSwitchFailed());
    } catch (e) {
      _log('feed threw: $e');
    }
  }

  /// 换网。走中继时：间隔归零，立即探测直连，同时重建中继。
  void onNetworkChanged() {
    if (_disposed) return;
    _direct = null; // 换网后重新解析服务器地址
    _probeLevel = 0;
    _levelGen++;
    if (_transport.route != AqtRoute.viaSsh) {
      _probeTimer?.cancel();
      return;
    }
    if (!_isForeground()) {
      _scheduleProbe();
      return;
    }
    _probeTimer?.cancel();
    unawaited(_probe(escalate: false));
    if (!_relayUnsupported && _relayOp == null) {
      unawaited(_switchToRelay());
    }
  }

  /// 取消定时器与在途工作；在途打开的中继落地后关闭。已挂到 transport 上
  /// 的中继归 transport 管（它的 close 会关）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _probeTimer?.cancel();
    _probeTimer = null;
    _disposeSignal.complete();
  }

  // ---------------------------------------------------------------- 中继

  /// [requestedAt] 非 null（状态机发起的切换）时，落地前检查直连是否已恢复：
  /// 请求之后收到过任何包（`lastRecvAgeMs` < 距请求的时长）就放弃这次切换。
  Future<bool> _switchToRelay({DateTime? requestedAt}) {
    final op = _doSwitchToRelay(requestedAt).catchError((Object e) {
      _log('relay switch: $e');
      return false;
    });
    _relayOp = op;
    op.whenComplete(() {
      if (identical(_relayOp, op)) _relayOp = null;
    });
    return op;
  }

  Future<bool> _doSwitchToRelay(DateTime? requestedAt) async {
    final daemonPort = _transport.lastPort;
    if (daemonPort == null) {
      _log('relay switch: no daemon port');
      return false;
    }
    final epoch = _epoch;
    final fromRoute = _transport.route;
    final opening = closeIfLate<AqtSshRelay>(
      Future.sync(() => _openRelay(daemonPort)),
      _relayBudget,
      onLate: (r) => r.close(),
      timeoutMessage: 'relay did not open within $_relayBudget',
    );
    // 被 dispose 抛下的那次打开：落地后没人要，关掉。
    opening.then((r) {
      if (_disposed) r.close();
    }, onError: (Object _) {});

    final AqtSshRelay? relay;
    try {
      relay = await Future.any<AqtSshRelay?>([
        opening,
        _disposeSignal.future.then((_) => null),
      ]);
    } on AqtRelayUnsupportedException catch (e) {
      _relayUnsupported = true;
      _log('relay switch: $e — no more relay attempts this session');
      return false;
    } on AqtRelayStartException catch (e) {
      _relayUnsupported = true;
      _log('relay switch: $e — no more relay attempts this session');
      return false;
    }
    if (relay == null) {
      _log('relay switch: disposed while opening');
      return false;
    }
    // 探测切回直连的确认窗口在途：等它出结果再决定。
    while (_confirming != null && !_disposed) {
      await _confirming!.future;
    }
    String? reject;
    if (_disposed) {
      reject = 'disposed';
    } else if (epoch != _epoch) {
      reject = 'superseded (path already switched)';
    } else if (requestedAt != null &&
        _transport.lastRecvAgeMs <
            clock.now().difference(requestedAt).inMilliseconds) {
      reject = 'recovered (traffic is back)';
    } else if (!_transport.setPath('127.0.0.1', relay.localPort)) {
      reject = 'setPath refused';
    }
    if (reject != null) {
      _log('relay switch: $reject; closing the new relay');
      unawaited(relay.close());
      return false;
    }
    final old = _transport.replaceRelay(AqtRoute.viaSsh, relay);
    _epoch++;
    _watch(relay);
    if (old != null && !identical(old, relay)) unawaited(old.close());
    _log('switched to relay :${relay.localPort} (from ${fromRoute.name})');
    if (fromRoute != AqtRoute.viaSsh) _routeChanged();
    _probeLevel = 0;
    _scheduleProbe();
    return true;
  }

  void _watch(AqtSshRelay relay) {
    if (!_watched.add(relay)) return;
    relay.done.then((_) {
      _watched.remove(relay);
      _onRelayDone(relay);
    });
  }

  void _onRelayDone(AqtSshRelay relay) {
    if (_disposed) return;
    // 不是正在用的那个（被换下、被主动关）：只清理。
    if (!identical(_transport.relay, relay) ||
        _transport.route != AqtRoute.viaSsh) {
      return;
    }
    _log('relay dropped while in use');
    if (!_isForeground()) return;
    if (!_relayUnsupported && _relayOp == null) {
      unawaited(_switchToRelay());
    }
    _probeTimer?.cancel();
    unawaited(_probe(escalate: false));
  }

  // ---------------------------------------------------------------- 探测

  void _scheduleProbe() {
    _probeTimer?.cancel();
    _probeTimer = null;
    if (_disposed || _transport.route != AqtRoute.viaSsh) return;
    if (!_directAllowed()) return;
    final i = _probeLevel.clamp(0, _probeIntervals.length - 1);
    _probeTimer = Timer(_probeIntervals[i], () {
      _probeTimer = null;
      unawaited(_probe());
    });
  }

  /// [escalate]：失败是否升一级间隔。事件触发的探测（换网、中继断开）
  /// 不升级 —— 换网后的间隔要从 60 s 重新数起。
  Future<void> _probe({bool escalate = true}) async {
    if (_disposed || _transport.route != AqtRoute.viaSsh) return;
    if (!_directAllowed()) return;
    if (_probing) {
      _probeAgain = true;
      return;
    }
    if (!_isForeground()) {
      _scheduleProbe(); // 后台：不探测、不升级，到点再看
      return;
    }
    _probing = true;
    final levelGen = _levelGen;
    var switched = false;
    try {
      switched = await _probeAndSwitchBack();
    } catch (e) {
      _log('probe: $e');
    } finally {
      _probing = false;
    }
    if (_disposed) return;
    // 失败就升级，哪怕后面还排着一次补探测；但探测期间间隔被归零过
    // （换网）就不升 —— 那次失败属于旧网络。
    if (!switched && escalate && levelGen == _levelGen) _probeLevel++;
    if (_probeAgain) {
      _probeAgain = false;
      unawaited(_probe(escalate: false));
      return;
    }
    if (!switched) _scheduleProbe();
  }

  Future<bool> _probeAndSwitchBack() async {
    final epoch = _epoch;
    ({String ip, int port})? addr;
    try {
      addr = await (_direct ??= _resolveDirect());
    } catch (e) {
      // 解析抛错（换网刚发生、DNS 还没好）不能缓存：下一次探测要重新解析。
      _log('probe: resolve threw: $e');
      addr = null;
    }
    if (addr == null) {
      _direct = null;
      _log('probe: direct address unresolved');
      return false;
    }
    final ok = await _transport.probeDirect(addr.ip, addr.port);
    if (_disposed) return false;
    if (!ok) {
      _log('probe: ${addr.ip}:${addr.port} unreachable');
      return false;
    }
    if (epoch != _epoch || _transport.route != AqtRoute.viaSsh) {
      _log('probe: superseded');
      return false;
    }
    final confirming = Completer<void>();
    _confirming = confirming;
    try {
      if (!_transport.setPath(addr.ip, addr.port)) {
        _log('probe: setPath to direct refused');
        return false;
      }
      if (await _directTrafficWithin(_confirmWindow)) {
        if (_disposed) return false;
        final old = _transport.replaceRelay(AqtRoute.direct, null);
        _epoch++;
        if (old != null) unawaited(old.close());
        _probeLevel = 0;
        _log('switched back to direct ${addr.ip}:${addr.port}');
        _routeChanged();
        return true;
      }
      if (_disposed) return false;
      final relay = _transport.relay;
      _log('probe: no traffic on direct within $_confirmWindow, back to relay');
      if (relay == null) {
        _log('probe: no relay to revert to');
      } else if (!_transport.setPath('127.0.0.1', relay.localPort)) {
        _log('probe: revert setPath to relay :${relay.localPort} refused');
      }
      return false;
    } finally {
      _confirming = null;
      confirming.complete();
    }
  }

  /// [window] 内是否有数据报**从当前目的地**（刚切过去的直连）到达。
  ///
  /// 不能用 `lastRecvAgeMs`：它是 1 Hz 采样，切换前一秒内的包看起来也新鲜；
  /// 而且 RoutedSocket 仍接收上一个目的地（中继）的在途包，它们也会刷新它。
  /// 拿它确认会让死掉的直连「通过」，中继被关，会话卡死。
  Future<bool> _directTrafficWithin(Duration window) async {
    var elapsed = Duration.zero;
    while (elapsed < window && !_disposed) {
      await Future<void>.delayed(_confirmStep);
      elapsed += _confirmStep;
      if (_transport.pathRxFromCurrent > 0) return true;
    }
    return false;
  }

  void _routeChanged() {
    try {
      _onRouteChanged();
    } catch (e) {
      _log('onRouteChanged threw: $e');
    }
  }

  void _log(String msg) => debugPrint('[AqtPath] $msg');
}
