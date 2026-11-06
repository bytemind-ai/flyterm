// SPDX-License-Identifier: GPL-3.0-or-later
import 'permission_rules.dart';

/// 管道窄门的段数上限。
///
/// 不是语义需要，是防御：允许任意段数会让单条命令的判定成本随模型输出线性
/// 增长。真实排查里三段以上极少。超限的行为是**落回审批**，不是拒绝执行。
const int kMaxPipelineSegments = 4;

/// 除 `|` 之外的 shell 元字符。
///
/// 与 `shell_guard.dart` 的 `_metacharRe` 同源，仅去掉 `|` —— 那一个正是本
/// 窄门要放行的。两处必须同步修改：那边新增一个元字符而这边漏掉，等于给
/// 窄门开一个后门。
final RegExp _nonPipeMetacharRe = RegExp(r'[;`><&\n\r]|\$\(');

/// 这条命令是否是「纯只读管道」——每一段都已被用户授权放行。
///
/// ## 为什么这不需要一个 shell 解析器
///
/// `shell_guard.dart` 拒绝写解析器的理由是引号嵌套。本函数不解析引号，而是
/// **遇到引号就直接退出**——代价是 `grep 'error 500' x.log | head` 仍要审批，
/// 换来的是完全不必论证引号的安全性。
///
/// ## 安全论证（两步，都不依赖命令自身的语法）
///
/// 1. **切分正确性**：命令不含任何引号 ⟹ bash 对 `|` 的切分与朴素
///    `split('|')` 至多在一个方向上分歧：反斜杠转义 `\|` 会让 bash **不**切
///    而我们切了。分歧只可能是「我们切得比 bash 多」，永远不会反过来。
///
///    切得多是安全的：设切出 N 段且每段都命中清单，bash 实际执行的是**一整
///    条**命令，其词序列的前缀恰好等于第 1 段。第 1 段命中了某条前缀规则 ⟹
///    整条命令的前 K 个词与第 1 段相同 ⟹ 整条命令命中**同一条**规则 ⟹ 它本
///    来就该被放行。
///
///    例：`ls \| ls` 切成 `ls \` 与 ` ls`，两段都命中 `ls *`；bash 实际执行
///    `ls` 带两个字面参数，而 `ls *` 本就允许 ls 带任意参数。
///
///    **不要把这条改成「以 `\` 结尾的段一律拒绝」**——那个理由是错的（前缀
///    匹配只看前 K 个词，`[ls, \]` 照样命中 `ls *`），而且会挡掉一个安全的情形。
///
/// 2. **能力不放大**：`defaultAllowRules` 的准入标准是「不得具备执行其他程序
///    或写文件的能力」（见 `permission_rules.dart` 那份清单上的说明，`find *`
///    当初正因此出局）。N 段全部命中清单 ⟹ 每段都不具备这两种能力 ⟹ 管道把
///    它们串起来后整体同样不具备。管道只传递 stdout，不新增能力。
///
/// ## 调用位置不可挪动
///
/// 必须在 `checkCommand` 里「凭据 deny 之后、元字符之前」调用。放到凭据 deny
/// 之前会让 `cat ~/.ssh/id_rsa | head` 因为两段都在清单里而绕过数据边界。
bool isReadOnlyPipeline(String command, PermissionRuleSet rules) {
  // 引号：不解析，直接退出。这是本窄门与 shell 解析器的分界线。
  if (command.contains("'") || command.contains('"')) return false;
  if (_nonPipeMetacharRe.hasMatch(command)) return false;

  final segments = command.split('|');
  // 单段意味着命令里根本没有 `|`，不归本窄门管。
  if (segments.length < 2 || segments.length > kMaxPipelineSegments) {
    return false;
  }

  for (final raw in segments) {
    final seg = raw.trim();
    // 空段同时排掉 `||`、`a| |b`、`ls|` 三种写法。
    if (seg.isEmpty) return false;
    if (!rules.allows(seg)) return false;
  }
  return true;
}
