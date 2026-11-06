// SPDX-License-Identifier: GPL-3.0-or-later
import 'config_draft.dart';

/// 一次 ssh config 解析的完整结果。
///
/// 比 `List<ServerDraft>` 多带一个 [sawInclude]：`Include` 指令意味着**有配置
/// 没被读到**，而本功能只看粘贴进来的文本、不碰文件系统。静默忽略会让用户以为
/// 导全了，所以要把这个事实带到 UI。
class SshConfigParseResult {
  final List<ServerDraft> drafts;
  final bool sawInclude;

  const SshConfigParseResult({required this.drafts, required this.sawInclude});
}

/// 行首关键字 + 值。分隔符二选一：空白（`Key Value`）或等号（`Key=Value`，
/// 等号两侧允许有可有可无的空白）。注意这两种分隔方式不能合并成
/// `\s*=?\s+`，那样在 `Key=Value`（等号前后都没有空格）时会要求等号后必须
/// 还跟一个空白字符，导致匹配失败。
final RegExp _kv = RegExp(r'^\s*(\w+)(?:\s+|\s*=\s*)(.+?)\s*$');

/// 只取关键字的那一版，用于 `Include`（它的值我们不解析，只要知道出现过）。
final RegExp _includeLine = RegExp(r'^\s*include\b', caseSensitive: false);

/// 解析 ssh config 片段。只要 drafts，不关心 Include。
List<ServerDraft> parseSshConfig(String input) =>
    parseSshConfigDetailed(input).drafts;

/// 解析 ssh config 片段，带完整结果。
///
/// ## 为什么按 Host 块切分而不是逐行塞进一个 map
///
/// ssh config 的语义是「一个 Host 块一台机器」，字段归属由块边界决定。逐行累积
/// 会让后一个块的 `Port` 覆盖前一个块的，粘贴多台机器时静默串味。
///
/// ## 通配 Host 必须跳过
///
/// 几乎每份 ssh config 都以 `Host *` 开头放全局默认值。它不是一台机器 —— 不跳
/// 过的话用户会看到一台叫 `*` 的服务器。判据是「含 `*` 或 `?`」，
/// 覆盖 `Host *`、`Host *.internal`、`Host web-?` 全部形态。
///
/// ## 已知限制（刻意不支持，不是遗漏）
///
/// - **不支持行内注释**（`Port 2222 # 说明`）。OpenSSH 的 `ssh_config(5)` 本身
///   只认整行注释，行内写法在真实 ssh 里就是非法配置的一部分——这里把它解析
///   成端口不合法从而字段级丢弃，是跟随标准的正确行为，不是 bug。强行剥离
///   `#` 之后的内容还会误伤 `ProxyCommand` 等值里本来就含 `#` 的合法配置。
/// - **`Match` 块不单独处理**，块内字段会被并入当前 Host 块。真实配置里
///   `Match` 多半跟在 `Host *` 之后做条件化配置，而那种块本来就会被通配规则
///   跳过，实践中影响有限。
/// - **同一 Host 块里多次出现 `IdentityFile` 时后者覆盖前者**，不保留全部候选
///   路径。这个字段唯一的用途是提示用户「这台机器要手动选密钥」，取哪一条
///   不改变这个提示，因此不做多值收集。
SshConfigParseResult parseSshConfigDetailed(String input) {
  final drafts = <ServerDraft>[];
  var sawInclude = false;

  // 当前 Host 块的累积状态。alias 为 null 表示还没进入任何块。
  String? alias;
  String? hostName;
  int? port;
  String? user;
  String? jump;
  String? identity;
  final prov = <String, String>{};

  void flush() {
    if (alias == null) return;
    // HostName 缺省时用别名 —— 这是 ssh 自己的行为。
    final effectiveHost = hostName ?? alias;
    if (effectiveHost == null || effectiveHost.isEmpty) {
      alias = null;
      return;
    }
    if (hostName == null) {
      prov['host'] = 'ssh config 的 Host 别名';
    }
    drafts.add(ServerDraft(
      name: alias,
      host: effectiveHost,
      port: port,
      username: user,
      jumpHostAlias: jump,
      identityFilePath: identity,
      provenance: Map.unmodifiable(prov),
    ));
    alias = null;
    hostName = null;
    port = null;
    user = null;
    jump = null;
    identity = null;
    prov.clear();
  }

  for (final rawLine in input.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (_includeLine.hasMatch(line)) {
      sawInclude = true;
      continue;
    }
    final m = _kv.firstMatch(line);
    if (m == null) continue;
    final key = m.group(1)!.toLowerCase();
    final value = m.group(2)!;

    if (key == 'host') {
      flush();
      // 一个 Host 块可以给同一台机器起多个别名（`Host web-1 web-1.internal`），
      // 这是合法语法。取第一个当名字就够了 —— 其余别名对「导入一台服务器」
      // 这件事没有信息量，而把它们连空格一起塞进 name 会产生一个带空格的
      // 奇怪名字。
      //
      // 通配判断要在**切分之后**对每一段做：`Host web-1 *.internal` 这种混写
      // 里，第一段是具体名字、后面才是通配，只看整串会误判。
      final aliases = value.split(RegExp(r'\s+')).where((a) => a.isNotEmpty);
      final first = aliases.isEmpty ? null : aliases.first;
      // 通配块跳过：不进入任何块，后续字段因此被 `alias == null` 丢弃。
      if (first == null || first.contains('*') || first.contains('?')) {
        continue;
      }
      alias = first;
      continue;
    }
    if (alias == null) continue;

    switch (key) {
      case 'hostname':
        hostName = value;
        prov['host'] = 'ssh config 的 HostName';
      case 'port':
        // 字段级降级：解析不出数字就丢掉这个字段，不毁掉整个块。
        final p = int.tryParse(value);
        if (p != null) {
          port = p;
          prov['port'] = 'ssh config 的 Port';
        }
      case 'user':
        user = value;
        prov['username'] = 'ssh config 的 User';
      case 'proxyjump':
        jump = value;
        prov['jumpHostAlias'] = 'ssh config 的 ProxyJump';
      case 'identityfile':
        identity = value;
        prov['identityFilePath'] = 'ssh config 的 IdentityFile';
    }
  }
  flush();

  return SshConfigParseResult(drafts: drafts, sawInclude: sawInclude);
}
