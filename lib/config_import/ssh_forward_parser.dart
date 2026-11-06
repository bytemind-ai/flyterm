// SPDX-License-Identifier: GPL-3.0-or-later
import 'config_draft.dart';

/// 按冒号切分转发 spec，但**保护方括号内的冒号**。
///
/// IPv6 字面量内部含冒号，裸 `split(':')` 会把 `8080:[::1]:80` 切成
/// `['8080','[','','1]','80']` 五段，于是落进「段数不认识」的分支整条失败。
///
/// 做法是先把 `[...]` 整段换成一个不可能出现在命令里的占位符（空格 + 序号 +
/// 空格），切完再还原并**去掉方括号** —— 存进 `TunnelConfig.remoteHost` 的
/// 应该是裸地址，方括号只是 ssh 命令行用来消除歧义的记号。
///
/// 只认方括号形态：裸 IPv6 在 `-L` 的 `host:port` 记号法里本身就是歧义的
/// （ssh 自己也要求加方括号），不是我们少支持了一种写法。
List<String> _splitForwardSpec(String spec) {
  final saved = <String>[];
  final masked = spec.replaceAllMapped(RegExp(r'\[[^\]]*\]'), (m) {
    saved.add(m.group(0)!);
    return ' ${saved.length - 1} ';
  });
  return masked.split(':').map((part) {
    final m = RegExp(r'^ (\d+) $').firstMatch(part);
    if (m == null) return part;
    final raw = saved[int.parse(m.group(1)!)];
    return raw.substring(1, raw.length - 1); // 去掉方括号
  }).toList();
}

/// 从一行 ssh 命令里解析端口转发参数。没有转发参数返回 null。
///
/// ## 为什么和 [parseSshCommand] 分开
///
/// 同一行命令可以同时产出一个 `ServerDraft` 和一个 `TunnelDraft`，两者去向不同
/// （一个填服务器表单，一个填转发表单）。让一个函数返回两种东西会逼调用方处理
/// 一个「可能两个都有、可能只有一个」的元组；分开之后各自的失败判据也清爽：
/// 服务器只要 host，转发必须有完整端口。
///
/// ## 端口非法时整体失败，不做字段级降级
///
/// 与 `ServerDraft` 的处理刻意相反：服务器少一个 `port` 还能用默认 22，而转发
/// 的端口是它存在的全部意义 —— 没有端口的转发规则没有任何可用部分。
TunnelDraft? parseSshForward(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  final tokens = text.split(RegExp(r'\s+'));
  var i0 = 0;
  // 开头的 ssh 可有可无，和 parseSshCommand 保持一致；不跳过的话它会被当成
  // 第一个非选项 token 误吞成 serverHint。
  if (tokens.isNotEmpty && tokens[0] == 'ssh') i0 = 1;

  TunnelDirection? dir;
  String? spec;
  String? serverHint;

  for (var i = i0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.startsWith('-') && t.length >= 2) {
      final flag = t[1];
      final isForward = flag == 'L' || flag == 'R' || flag == 'D';
      if (!isForward) {
        // 其他带值选项要把它的值一起跳过，否则 `-p 2222` 的 2222 会被
        // 当成目标主机。
        if ('piJlobcF'.contains(flag) && t.length == 2) i++;
        continue;
      }
      dir = switch (flag) {
        'L' => TunnelDirection.local,
        'R' => TunnelDirection.remote,
        _ => TunnelDirection.socks5,
      };
      spec = t.length > 2 ? t.substring(2) : (i + 1 < tokens.length ? tokens[++i] : null);
      continue;
    }
    if (serverHint != null) continue;
    final at = t.lastIndexOf('@');
    serverHint = at > 0 ? t.substring(at + 1) : t;
  }

  if (dir == null || spec == null || spec.isEmpty) return null;

  final prov = <String, String>{
    'direction': 'ssh 命令的 -${switch (dir) {
      TunnelDirection.local => 'L',
      TunnelDirection.remote => 'R',
      TunnelDirection.socks5 => 'D',
    }}',
  };

  if (dir == TunnelDirection.socks5) {
    final p = int.tryParse(spec);
    if (p == null) return null;
    prov['localPort'] = 'ssh 命令的 -D';
    return TunnelDraft(
      direction: dir,
      localPort: p,
      serverHostHint: serverHint,
      provenance: Map.unmodifiable(prov),
    );
  }

  // 形态有三种：
  //   host:port                    （2 段，本地端口同远端）
  //   localPort:host:port          （3 段）
  //   bindAddr:localPort:host:port （4 段，绑定地址对移动端无意义，丢弃）
  final parts = _splitForwardSpec(spec);
  final int? localPort;
  final String remoteHost;
  final int? remotePort;
  switch (parts.length) {
    case 2:
      localPort = null;
      remoteHost = parts[0];
      remotePort = int.tryParse(parts[1]);
    case 3:
      localPort = int.tryParse(parts[0]);
      remoteHost = parts[1];
      remotePort = int.tryParse(parts[2]);
      if (localPort == null) return null;
    case 4:
      localPort = int.tryParse(parts[1]);
      remoteHost = parts[2];
      remotePort = int.tryParse(parts[3]);
      if (localPort == null) return null;
    default:
      return null;
  }
  if (remotePort == null || remoteHost.isEmpty) return null;

  prov['remoteHost'] = 'ssh 命令的转发参数';
  prov['remotePort'] = 'ssh 命令的转发参数';
  if (localPort != null) prov['localPort'] = 'ssh 命令的转发参数';

  return TunnelDraft(
    direction: dir,
    localPort: localPort,
    remoteHost: remoteHost,
    remotePort: remotePort,
    serverHostHint: serverHint,
    provenance: Map.unmodifiable(prov),
  );
}
