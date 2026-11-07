// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'aqt_port_spec.dart';

/// 问用户要不要重启 daemon 换到新端口段。
///
/// 重启会结束这台机器上所有 AQT 会话 —— 包括其他设备上的 —— 所以必须先问。
/// 关掉对话框（返回键）按「不重启」处理：继续用旧端口是安全的默认值。
Future<bool> showAqtPortRestartDialog(
  BuildContext context, {
  required int currentPort,
  required AqtPortSpec ports,
  required int? sessions,
}) async {
  final l = context.l10n;
  final body = sessions == null
      ? l.aqtPortRestartBodyUnknown('$currentPort', ports.arg)
      : l.aqtPortRestartBody('$currentPort', ports.arg, sessions);
  final restart = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.aqtPortRestartTitle),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l.aqtPortRestartKeep),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l.aqtPortRestartConfirm),
        ),
      ],
    ),
  );
  return restart ?? false;
}
