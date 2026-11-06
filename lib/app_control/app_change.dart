// SPDX-License-Identifier: GPL-3.0-or-later
/// 一次可记账的 app 变更。
///
/// **存结构化字段而不是拼好的 summary 字符串**：这一层拿不到
/// `AppLocalizations`（那需要 BuildContext），在这里拼文案要么把 l10n 漏进
/// 数据层，要么硬编码一种语言。更实际的问题是语言切换后历史记录不会跟着变 ——
/// 用户切到英文，面板上还留着「字体 13 → 15」。渲染归 UI。
class AppChange {
  final String toolName;

  /// 变更的字段标识（`'fontSize'`、`'terminalTheme'`）。**不是本地化文本。**
  final String field;

  /// 旧值。撤销时写回的就是它。
  final Object? oldValue;

  /// 新值。**必须是生效后的真实值，不是模型请求的值** —— `TerminalSettings`
  /// 的 setter 普遍带 clamp，记请求值会让撤销卡片显示一个从未生效过的数字。
  final Object? newValue;

  /// null = 不可逆。这类变更必定已走过硬清单前置确认（撤销边界恰好是硬清单
  /// 的补集）。
  final Future<void> Function()? undo;

  const AppChange({
    required this.toolName,
    required this.field,
    required this.oldValue,
    required this.newValue,
    required this.undo,
  });

  bool get reversible => undo != null;
}
