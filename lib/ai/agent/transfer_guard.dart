// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';

import 'permission_rules.dart' show isCredentialDeny;

/// 一次传输的前置判定结果。
///
/// 与 `CheckResult` 分开而不是复用：那个的形状是「放行 / 弹卡 / 进方案」，
/// 由 `PermissionRuleSet` 与 `PermissionMode` 决定。传输**永远弹卡**，
/// 所以这里没有 decision 字段 —— 只有「能不能开始」和「要不要
/// 在卡上示警」。硬塞进 CheckResult 会让人以为传输也受 allowlist 影响。
@immutable
class TransferCheck {
  /// 非 null = 直接拒绝，这段文本回给模型。
  final String? error;

  /// 命中凭据清单。不阻止传输（落盘是用户自己的设备），但：
  /// 1. 审批卡显示警示
  /// 2. 结果卡上「让 AI 读完」按钮禁用 —— 那才是内容进模型请求体的口子
  final bool credentialDeny;

  const TransferCheck({this.error, this.credentialDeny = false});

  bool get ok => error == null;
}

/// 判定一个远端路径能否用于传输。
///
/// **要求绝对路径。** SFTP 不做 shell 展开：`~/.bashrc` 传上去会在当前
/// 目录下真的建一个名为 `~` 的目录，而不是落到 home。同理相对路径的基准
/// 目录取决于 SFTP 子系统的启动位置，与用户在终端里的 cwd 无关 —— 那种
/// 不一致比直接拒绝糟得多。
TransferCheck checkTransferPath(String path) {
  final p = path.trim();
  if (p.isEmpty) {
    return const TransferCheck(error: 'Path is required.');
  }
  if (!p.startsWith('/')) {
    return const TransferCheck(
      error: 'Path must be absolute (start with `/`). SFTP does not expand '
          '`~` or resolve relative paths against the shell cwd.',
    );
  }
  return TransferCheck(credentialDeny: isCredentialDeny(p));
}

/// 覆盖远端已有文件前的备份路径。
///
/// 后缀形状与 `file_edit.dart` 的 `dotBackupPathForSeq` 保持同一套编号
/// （`ToolCallEvent.seq`），所以传输的覆盖能纳入现有 checkpoint 回滚，
/// 不需要另建一套撤销机制。
///
/// 与那个函数的区别是**不加前导点**：那边把备份藏成隐藏文件是为了不污染
/// 用户 `ls` 的结果，而上传覆盖通常发生在 web 根目录一类地方，用户接下来
/// 就要找这个备份 —— 藏起来反而帮倒忙。
String transferBackupPath(String remotePath, int seq) =>
    '$remotePath.flyterm.bak.$seq';

/// 拼远端路径，避免双斜杠。
String joinRemote(String dir, String filename) {
  final d = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  return '$d/$filename';
}
