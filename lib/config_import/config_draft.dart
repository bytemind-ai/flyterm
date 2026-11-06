// SPDX-License-Identifier: GPL-3.0-or-later
import '../tunnel/tunnel_entry.dart' show TunnelDirection;

export '../tunnel/tunnel_entry.dart' show TunnelDirection;

/// 一次解析产出的服务器配置草稿。
///
/// ## 为什么是独立的类而不是直接构造 `Server`
///
/// `Server` 的字段全是非空的（`host` / `username` / `authType` 都 required），
/// 而解析的本质是**部分成功**：粘一行 `ssh user@host` 只能得到两个字段。
/// 用 `Server` 表达就只能拿空字符串填充，那样「没解析到」和「解析出空值」
/// 在类型上无法区分，UI 也就没法决定哪些字段该高亮。
///
/// 另一个理由是 [provenance]：它是这个功能的核心（UI 靠它决定高亮哪些字段），而 `Server`
/// 是持久化模型，不该为一次性的导入流程背上这个字段。
class ServerDraft {
  final String? name;
  final String? host;
  final int? port;
  final String? username;

  /// `ProxyJump` 给出的**别名**，不是 id。
  ///
  /// ssh config 里写的是 `ProxyJump bastion`，而 `bastion` 是另一个 Host 块的
  /// 名字。能不能映射到本机已保存的服务器是 UI 层的事（它才拿得到服务器列表），
  /// 解析层只负责把这个字符串原样带出来。
  final String? jumpHostAlias;

  /// `IdentityFile` 给出的路径。
  ///
  /// **记录它不等于能用它**：这是桌面机上的路径，手机上既没有那个文件、也没有
  /// 访问权限。它的唯一用途是让 UI 告诉用户「这台机器是密钥认证，你得手动选一
  /// 个密钥」—— 不记录的话用户会以为密钥已经配好了，保存后才发现连不上。
  final String? identityFilePath;

  /// 字段名 → 人类可读的来源说明。**只有解析到的字段才在这里**。
  ///
  /// 不在这个 map 里 = 走默认值。UI 据此决定高亮哪些字段、折叠哪些。
  final Map<String, String> provenance;

  const ServerDraft({
    this.name,
    this.host,
    this.port,
    this.username,
    this.jumpHostAlias,
    this.identityFilePath,
    this.provenance = const {},
  });

  /// 这份草稿值不值得填进表单。
  ///
  /// 判据只看 [host]：它是唯一无法推断的字段。`port` 默认 22、`name` 可从
  /// Host 别名或 host 本身推导、`username` 缺了用户补一个就行。host 都没有，
  /// 说明这段文本根本不是服务器配置。
  bool get isUsable => host != null && host!.isNotEmpty;

  /// 解析出了密钥路径 —— 用户需要手动选一个本机密钥。
  bool get needsManualKey =>
      identityFilePath != null && identityFilePath!.isNotEmpty;
}

/// 一次解析产出的端口转发草稿。
class TunnelDraft {
  final TunnelDirection direction;

  /// `socks5` 方向下恒为 null —— 动态转发没有固定的远端目标。
  final String? remoteHost;
  final int? remotePort;

  /// 缺省时回落到 [remotePort]，见 [effectiveLocalPort]。
  final int? localPort;

  /// `ssh -L ... user@host` 里的 host 部分，用来匹配已保存的服务器。
  ///
  /// 与 [ServerDraft.jumpHostAlias] 同理：匹配是 UI 层的事，解析层只带出字符串。
  final String? serverHostHint;

  final Map<String, String> provenance;

  const TunnelDraft({
    required this.direction,
    this.remoteHost,
    this.remotePort,
    this.localPort,
    this.serverHostHint,
    this.provenance = const {},
  });

  /// 本地端口。没给就跟远端用同一个 —— 这是 `ssh -L` 最常见的写法所隐含的
  /// 意图（「把那个端口搬到本地」），让用户少填一个框。
  int? get effectiveLocalPort => localPort ?? remotePort;

  /// 判据按方向分叉：动态转发（socks5）只需要一个本地端口，没有远端目标可言；
  /// local / remote 则必须知道转发到哪。
  bool get isUsable => switch (direction) {
        TunnelDirection.socks5 => localPort != null,
        TunnelDirection.local || TunnelDirection.remote =>
          remoteHost != null && remoteHost!.isNotEmpty && remotePort != null,
      };
}
