// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';

/// 消息正文的一键复制。
///
/// ## 为什么是按钮，不是长按
///
/// assistant 正文是 `MarkdownBody(selectable: true)`，长按在那上面已经有
/// 含义（选词）。再挂一个长按复制就是两个手势抢同一个输入，而用户没有
/// 任何线索判断自己触发了哪一个。
///
/// ## 为什么不复用代码块那排 [PanelActionChip]
///
/// 层级不同，是刻意的。代码块下面的执行/收藏/解释是这个面板的主线动作；
/// 正文复制是次要动作。做成同尺寸的 chip 会让每条消息底下都顶着一排按钮，
/// 而消息的数量远多于代码块。
///
/// ## 为什么反馈是图标变化，不是 SnackBar
///
/// 这个面板整个活在 `showModalBottomSheet` 里。SnackBar 交给外层
/// ScaffoldMessenger 显示，会落在 sheet 底下被挡住 —— 用户点了复制却什么
/// 都看不见，只能再点一次。图标自己变成对勾则一定在视野内，因为手指刚
/// 离开那个位置。
class MessageCopyButton extends StatefulWidget {
  final String text;

  const MessageCopyButton({super.key, required this.text});

  @override
  State<MessageCopyButton> createState() => _MessageCopyButtonState();
}

class _MessageCopyButtonState extends State<MessageCopyButton> {
  bool _justCopied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    // 复制完 1.5 秒内退出面板是完全正常的操作。不取消这个 timer，回调会
    // 在已经 unmount 的 State 上 setState。
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _justCopied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _justCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) => MessageActionIcon(
        icon: _justCopied ? Icons.check : Icons.copy,
        onTap: _copy,
        emphasized: _justCopied,
        semanticLabel: _justCopied
            ? context.l10n.aiMessageCopied
            : context.l10n.aiCopyAction,
      );
}

/// 消息底下那排次要动作的统一外观（复制 / 重试 / 编辑）。
///
/// 单独抽出来只为一件事：尺寸和透明度这三个数字只存在一处。它们分散在
/// 三个调用点各写一遍时，改一次视觉就必然漏掉一个，而漏掉的那个不会报错
/// —— 只是那一个图标比邻居大一点、深一点。
class MessageActionIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String semanticLabel;

  /// 动作刚刚生效的瞬时态（复制完的对勾）。只影响透明度。
  final bool emphasized;

  const MessageActionIcon({
    super.key,
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          icon,
          size: 14,
          color: cs.onSurfaceVariant.withValues(alpha: emphasized ? 0.9 : 0.45),
          semanticLabel: semanticLabel,
        ),
      ),
    );
  }
}
