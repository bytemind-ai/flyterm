// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// 键盘弹收时的「画面冻结」状态机（纯逻辑，不碰 widget / 图像）。
///
/// 背景：SSH / QUIC 是裸字节流，键盘弹收时本地先 resize（xterm 的
/// `Buffer.resize` 对 alt buffer 只截断、不 reflow），远端 tmux / vim 的整屏
/// 重绘至少要一个 RTT 才到。这期间用户看到的是错位 / 空白的中间帧，重绘
/// 到达时再整屏一换 —— 就是那一下「闪」。mosh 是状态同步，只出终态帧，不闪；
/// main buffer 的普通 shell 也不闪。
///
/// 做法：resize 开始时盖一张旧画面快照，真终端在底下照常 resize、收数据，
/// 等以下任一条件满足就撤掉：
///   1. 远端 resize 已发出（[remoteResizeSent]）之后又有远端输出落屏
///      （[outputRendered]，调用方保证是在那一帧画完之后调）；
///   2. 远端 resize 发出后 [remoteTimeout] 内没有任何输出；
///   3. 冻结开始后 [maxHold]（硬上限，不会被推迟）；
///   4. 调用方主动 [cancel]（切 tab、换 transport、用户滚动、销毁）。
class ResizeFreeze {
  ResizeFreeze({
    required this.onChanged,
    this.remoteTimeout = const Duration(milliseconds: 500),
    this.maxHold = const Duration(milliseconds: 1500),
  });

  final void Function(bool frozen) onChanged;
  final Duration remoteTimeout;
  final Duration maxHold;

  bool _frozen = false;
  bool _remoteSent = false;
  bool _disposed = false;
  Timer? _maxHoldTimer;
  Timer? _remoteTimer;

  bool get frozen => _frozen;

  /// 开始冻结。[eligible] 为 false、已在冻结中、或已 dispose 时什么都不做。
  /// 返回本次是否真的开始了一次冻结。
  bool begin({required bool eligible}) {
    if (_disposed || _frozen || !eligible) return false;
    _frozen = true;
    _remoteSent = false;
    _maxHoldTimer = Timer(maxHold, _release);
    onChanged(true);
    return true;
  }

  /// 去抖后的远端 resize 已发出。之后的第一次输出落屏即可解冻；
  /// 一直没输出则 [remoteTimeout] 后解冻。
  void remoteResizeSent() {
    if (!_frozen) return;
    _remoteSent = true;
    _remoteTimer?.cancel();
    _remoteTimer = Timer(remoteTimeout, _release);
  }

  /// 远端输出已经写进终端且那一帧已画完。远端 resize 发出前的输出是旧尺寸
  /// 下的数据，不代表重绘到了，忽略。
  void outputRendered() {
    if (_frozen && _remoteSent) _release();
  }

  void cancel() => _release();

  void dispose() {
    _disposed = true;
    _clearTimers();
    _frozen = false;
  }

  void _release() {
    if (!_frozen) return;
    _frozen = false;
    _remoteSent = false;
    _clearTimers();
    onChanged(false);
  }

  void _clearTimers() {
    _maxHoldTimer?.cancel();
    _maxHoldTimer = null;
    _remoteTimer?.cancel();
    _remoteTimer = null;
  }
}

/// 冻结层所在的 key —— 测试用它判断快照有没有盖上。
const kResizeFreezeOverlayKey = ValueKey('resize-freeze-overlay');

/// 冻结快照的显示层：顶部对齐、裁掉超出部分；图像盖不到的区域（键盘收起后
/// 视口变高）用终端背景色填充，避免露出底下正在 resize 的真终端。
/// 不接收指针事件，手势照常落到下面的终端。
class ResizeFreezeOverlay extends StatelessWidget {
  const ResizeFreezeOverlay({
    super.key = kResizeFreezeOverlayKey,
    required this.image,
    required this.pixelRatio,
    required this.background,
  });

  final ui.Image image;

  /// 截图时用的 pixelRatio，用来把物理像素换回逻辑尺寸。
  final double pixelRatio;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: background,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            minHeight: 0,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: RawImage(
              image: image,
              scale: pixelRatio,
              alignment: Alignment.topLeft,
            ),
          ),
        ),
      ),
    );
  }
}
