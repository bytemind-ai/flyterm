// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../tunnel/tunnel_entry.dart';
import '../design/fly_tokens.dart';

/// 隧道状态色 —— 本列表**唯一**的彩色来源（fly_tokens 的「颜色只编码状态」）。
Color tunnelStatusColor(TunnelStatus status) => switch (status) {
      TunnelStatus.active => FlyColors.active,
      TunnelStatus.connecting => FlyColors.pending,
      TunnelStatus.error => FlyColors.danger,
      TunnelStatus.stopped => FlyColors.textTertiary,
    };

/// 状态微标签文案（等宽大写，与 `SSH`/`QUIC` 同类）。
///
/// 重试中额外带上计数：`RETRY 2/5`。
String tunnelStatusLabel(TunnelEntry t) {
  if (t.status == TunnelStatus.connecting && t.retryCount > 0) {
    return 'RETRY ${t.retryCount}/${TunnelEntry.maxRetries}';
  }
  return switch (t.status) {
    TunnelStatus.active => 'ACTIVE',
    TunnelStatus.connecting => 'CONNECTING',
    TunnelStatus.error =>
      t.retryCount >= TunnelEntry.maxRetries ? 'FAILED' : 'ERROR',
    TunnelStatus.stopped => 'STOPPED',
  };
}

/// 行尾状态标签：6px 圆点 + 等宽微标签。
///
/// [breathing] 为真（connecting）时圆点呼吸闪烁 —— 动只用来表达「进行中」，
/// 稳定态静止。
class TunnelStatusLabel extends StatelessWidget {
  const TunnelStatusLabel({
    super.key,
    required this.color,
    required this.label,
    required this.breathing,
  });

  final Color color;
  final String label;
  final bool breathing;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BreathingDot(color: color, breathing: breathing),
        const SizedBox(width: 5),
        Text(
          label,
          style: FlyText.micro.copyWith(color: color, fontSize: 9.5),
        ),
      ],
    );
  }
}

/// 状态圆点。connecting 时透明度 0.3↔1.0 呼吸（借终端 `_StatusDot` 的手法）；
/// 其余状态静止且全亮。
class _BreathingDot extends StatefulWidget {
  const _BreathingDot({required this.color, required this.breathing});

  final Color color;
  final bool breathing;

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _opacity = Tween<double>(begin: 0.3, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    if (widget.breathing) {
      _ctrl.repeat(reverse: true);
    } else {
      _ctrl.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(_BreathingDot old) {
    super.didUpdateWidget(old);
    if (widget.breathing && !old.breathing) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.breathing && old.breathing) {
      _ctrl.stop();
      _ctrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
