// SPDX-License-Identifier: GPL-3.0-or-later
import 'tool_registry.dart';

/// app 侧权限判定 —— **与远端命令共用同一个档位**（[PermissionMode]）。
///
/// ## 曾经是一套独立的两档，2026-10-13 合并
///
/// 早先这里有一个 `AppPermissionMode`（off / ask / bypass），与远端档完全
/// 独立，并有一段长得多的论证反对合并：
///
/// > 用户为了让 AI 在 prod 上自由跑命令而把远端档开到 bypass，这档若传染到
/// > app 侧，AI 就能不吭声删掉服务器条目。那是心智上的背叛 —— 用户授权的
/// > 是「在那台机器上别烦我」，不是「随便动我的 app」。
///
/// 那条论证在**独立**的前提下是对的。合并的理由是交互一致性优先：两套三档、
/// 六个不同的词（`先出方案/每次询问/全部放行` vs `关闭/询问/不询问`），用户
/// 要记两遍，而两个档在真实使用中几乎总是一起改（愿意让 AI 自由跑命令的人，
/// 通常也愿意让它改主题字体）。
///
/// **这是一次有意接受的取舍，不是疏漏。** 代价被两条底线约束住：硬清单
/// [kAppHardApproval] 在任何档位都审批；凭据边界在任何档位都审批。也就是说
/// 「全放行」最坏能做的是改设置和删掉一个可重建的服务器条目 —— 不是不可逆的。
///
/// ## 曾经的 `off` 档去哪了
///
/// 它唯一的 semantics 是「不声明 App 工具」（见 `shouldDeclareAppTools`）。
/// 并入之后没有 off 语义，`shouldDeclareAppTools` 简化为只看 `hasService`。
/// 后果是 [PermissionMode.readOnly] 档下 App **只读**工具（[kAppReadOnlyTools]）
/// 会被声明并放行 —— 这是合并的直接后果，是刻意接受的。
///
/// ## 为什么不复用 `checkCommand` / `checkFileWrite`
///
/// 那两个判的是命令文本和路径，这里判的是**工具名**，没有共享的判定逻辑。
/// 但**档位**（[PermissionMode]）是共用的 —— 这正是本次合并的全部内容。
///
/// ## reason 恒为 null 是刻意的
///
/// `CheckResult.canRemember` 从 reason 派生（`== noMatchingRule`），而 app
/// 工具没有「允许并记住」语义 —— 它不像 `systemctl status *` 那样有可泛化的
/// 命令前缀，审批就是一次性的。给 null 让 canRemember 自动为 false，同时
/// `denyHit` 也为 false（这不是凭据外泄，不该弹警示条）。
///
/// `approval_card.dart` 的 `_reasonText` 已显式处理 `null => null`，所以
/// 审批卡只是不显示理由文案，不会崩。

/// 无论档位是什么都要审批的工具。
///
/// 判据是**不可逆**：撤销栈覆盖不到的，必须事前拦。
///
/// - `session_close` —— 关掉的 SSH 连接恢复不了（远端进程已没）
/// - `tunnel_create` —— 端口一旦暴露过就收不回
/// - `server_entry_delete` —— 其实可逆（私钥在 SecureStorage 里不随条目删除），
///   但误删心理成本高，同时进硬清单和撤销栈，双保险
/// - `known_host_forget` —— 忘记主机密钥不可逆：撤销意味着把一个指纹重新标成
///   「可信」，而那条信任本该由用户在看到指纹后亲自给出
///
/// **[hardApproval] 参数**覆盖这份静态名单，给**条件性不可逆**的工具用。
/// 目前只有 `session_close`：关掉一个有活跃连接的会话不可逆（远端进程已没），
/// 但关掉一个没连上的 tab 是可逆的（重开即可）——为后者弹确认是无谓的摩擦，
/// 而把前者放进 bypass 是真的会丢东西。
///
/// null = 按静态名单判定（绝大多数工具走这条）。
///
/// **这份名单在任何档位都生效，包括 [PermissionMode.bypass]。** 判定顺序里
/// 它优先于档位分支，写反了 bypass 会先命中 allow 返回，清单就成了摆设。
const Set<String> kAppHardApproval = {
  'server_entry_delete',
  'session_close',
  'tunnel_create',
  'known_host_forget',
};

/// 只读的 app 工具 —— [PermissionMode.readOnly] 及以上的档位直接放行。
const Set<String> kAppReadOnlyTools = {
  'app_state_read',
  'ssh_key_list',
  'saved_command_list',
  'skill_list',
  'known_host_list',
};

/// app 工具的权限判定。
///
/// 硬清单优先于一切档位判断 —— 顺序写反的话 `bypass` 会先命中 allow 返回，
/// 硬清单就成了摆设。
CheckResult checkAppControl(
  String toolName, {
  required PermissionMode mode,
  bool? hardApproval,
}) {
  final hard = hardApproval ?? kAppHardApproval.contains(toolName);
  if (hard) {
    return const CheckResult(decision: ToolDecision.needApproval);
  }

  switch (mode) {
    case PermissionMode.readOnly:
      // 只读档：App 的只读工具放行，写操作审批。
      if (kAppReadOnlyTools.contains(toolName)) {
        return const CheckResult(decision: ToolDecision.allow);
      }
      return const CheckResult(decision: ToolDecision.needApproval);
    case PermissionMode.ask:
      return const CheckResult(decision: ToolDecision.needApproval);
    case PermissionMode.bypass:
      return const CheckResult(decision: ToolDecision.allow);
  }
}
