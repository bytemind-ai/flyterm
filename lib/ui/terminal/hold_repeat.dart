// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 长按一个键时的「自重复」。
///
/// ## 为什么需要它
///
/// 手机输入法按住退格不放时，有两种连发实现：
///
/// 1. 反复调用 `InputConnection.deleteSurroundingText()` —— 每次都是一次文本
///    编辑，在 Flutter 里表现为一串 `TextInputClient.updateEditingValue`。
/// 2. 反复调用 `InputConnection.sendKeyEvent(KEYCODE_DEL)` —— 首次按下是
///    `ACTION_DOWN`，之后**连发用的是 `ACTION_MULTIPLE`**。
///
/// 第 2 条在 Flutter 里是死的：引擎 `KeyChannelResponder.handleEvent` 只处理
/// `ACTION_DOWN` / `ACTION_UP`，其它 action 直接 `onKeyEventHandled(false)`
/// 返回，于是一个 `ACTION_MULTIPLE` 都不会进 Dart。真机表现就是——点一下删一
/// 个字，按住不放毫无反应（`IME cbs=0 … key d=1 u=1` 就是这个签名）。
///
/// 所以「按住可能连发」这件事只能我们自己补：收到 `KeyDownEvent` 后等一个
/// 起始延迟（躲开普通点按），仍没收到 `KeyUpEvent` 就按固定间隔重复触发；
/// 一旦收到 `KeyUpEvent` 或任何其它按键事件立刻停。
///
/// ## 为什么不会和真键盘打架
///
/// 硬件键盘自己会发 `KeyRepeatEvent`。收到它的第一时间就 [_stop]，让真重复
/// 继续由 xterm 正常处理，不会出现「系统重复 + 我们重复」双倍删除。
class HoldRepeat {
  HoldRepeat({
    required this.onFire,
    this.initialDelay = const Duration(milliseconds: 320),
    this.interval = const Duration(milliseconds: 40),
    this.maxRepeats = 150,
  });

  final VoidCallback onFire;

  /// 按住多久后才认为是「长按」。要明显大于一次点按的 down→up 间隔，
  /// 否则单击会多删一个字符。
  ///
  /// 320 ms 的取巧：Android 输入法自己的连发大约在 400 ms 后开始，但它们
  /// 走 `ACTION_MULTIPLE` 全被引擎丢了（见文件头）；真机上用户按住半秒就
  /// 松手，起始延迟比这还长就白等。
  final Duration initialDelay;

  final Duration interval;

  /// 上限。`KeyUpEvent` 万一丢了（输入法切走、焦点被抢），没有上限就会
  /// 一直删到命令行见底 —— 宁可少删也不能失控。
  final int maxRepeats;

  Timer? _delay;
  Timer? _tick;
  int _fired = 0;

  /// 当前是否正在自重复（仅供诊断/测试观察）。
  bool get isRepeating => _tick != null;

  /// 本次按住期间我们自己触发了多少次。
  int get firedCount => _fired;

  /// 喂一个按键事件。返回 true 表示这个事件被本类消费掉，调用方不必再把它
  /// 交给下游 —— 目前只有「停止自重复」会返回 true，按键本身永远返回 false，
  /// 保证按下/抬起那一次的语义完全不变。
  bool handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      _arm();
      return false;
    }
    if (event is KeyUpEvent) {
      final wasRepeating = _stop();
      return wasRepeating;
    }
    // KeyRepeatEvent：真键盘自己在重复，立刻让位。
    _stop();
    return false;
  }

  void _arm() {
    _stop();
    _fired = 0;
    _delay = Timer(initialDelay, () {
      _delay = null;
      if (_fired >= maxRepeats) return;
      _tick = Timer.periodic(interval, (_) {
        if (_fired >= maxRepeats) {
          _stop();
          return;
        }
        _fired++;
        onFire();
      });
    });
  }

  /// 停掉并返回「原本是否正在自重复」。
  bool _stop() {
    final was = _tick != null || _delay != null;
    _delay?.cancel();
    _delay = null;
    _tick?.cancel();
    _tick = null;
    return was;
  }

  void stop() => _stop();

  void dispose() => _stop();
}
