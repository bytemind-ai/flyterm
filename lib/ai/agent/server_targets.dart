// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';

/// 一台服务器在多机语境下的可见信息。
///
/// 与 `Server` 分开而不是直接用那个：`Server` 有二十多个字段（transport、
/// mosh 端口段、tmux 开关、SFTP 上次路径…），其中绝大多数对 agent 毫无意义，
/// 而每一个都会占 token。这个类是那道「哪些信息值得给模型看」的闸。
@immutable
class ServerListEntry {
  /// 内部 id。**不进 [toJson]** —— 模型不需要 UUID，给了只会浪费 token 并
  /// 诱使它把 id 当成名字回传。
  final String id;

  final String name;
  final String? groupName;
  final String host;

  /// agent 能不能连上这台（有可复用的 client，或有保存的凭据）。
  ///
  /// 必须给模型看：没凭据的机器连不上，不预告的话模型会选中它、失败一轮、
  /// 再重试，白烧一轮预算。
  final bool credsOk;

  const ServerListEntry({
    required this.id,
    required this.name,
    this.groupName,
    required this.host,
    required this.credsOk,
    this.sameHostAs,
  });

  ServerListEntry _withAliases(List<String> others) => ServerListEntry(
        id: id,
        name: name,
        groupName: groupName,
        host: host,
        credsOk: credsOk,
        sameHostAs: others,
      );

  /// 同一台机器上的其它条目名。null = 这个 host 只有这一条。
  ///
  /// 实测现场：用户有 `dk` 和 `gcproot` 两个条目指向同一个 IP，模型看到两
  /// 个不同的名字就分别跑了一遍 `df -h`，拿回两份**逐字相同**的输出，第二
  /// 轮才反应过来「是同一台机器」。一轮往返 + 一整份输出白费。
  ///
  /// 判定在 [withAliases] 里统一做，不在构造处 —— 它需要看整个列表。
  final List<String>? sameHostAs;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (groupName != null && groupName!.isNotEmpty) 'group': groupName,
        'host': host,
        'creds_ok': credsOk,
        if (sameHostAs != null && sameHostAs!.isNotEmpty)
          'same_host_as': sameHostAs,
      };
}

/// 一次目标解析的结果。
@immutable
class ServerTarget {
  /// null = 当前会话那台（模型没给 `server` 参数）。
  final String? serverId;
  final String? serverName;

  /// 非 null = 解析失败，这段文本回给模型。
  final String? error;

  const ServerTarget({this.serverId, this.serverName, this.error});

  bool get ok => error == null;

  /// true = 打别的机器；false = 打当前会话那台。
  bool get isRemote => serverId != null;
}

/// 把模型给的 `server` 参数解析成目标。
///
/// ## 为什么是精确匹配，不做模糊/前缀匹配
///
/// 「web-1」在前缀匹配下会命中「web-10」「web-11」。选错机器的后果与选错命令
/// 同级——一条 `systemctl restart` 打到了不该打的机器上，而审批卡上显示的
/// 命令文本完全正确，用户没有任何线索能察觉。
///
/// 宁可报错让模型重来一次。报错时**必须附上可用名字列表**：不给列表，模型会
/// 开始编造名字，然后连续几轮都失败在同一个地方。
ServerTarget resolveServerTarget(dynamic raw, List<ServerListEntry> servers) {
  if (raw == null) return const ServerTarget();

  if (raw is! String) {
    return const ServerTarget(
      error: 'Invalid arguments: `server` must be a string (the exact name of '
          'a saved server), or omitted to use the current session.',
    );
  }
  final name = raw.trim();
  if (name.isEmpty) {
    return const ServerTarget(
      error: 'Invalid arguments: `server` must not be empty. Omit it entirely '
          'to use the current session.',
    );
  }

  for (final s in servers) {
    if (s.name == name) {
      return ServerTarget(serverId: s.id, serverName: s.name);
    }
  }

  final available = servers.map((s) => s.name).join(', ');
  return ServerTarget(
    error: 'No saved server named `$name`. '
        '${available.isEmpty ? 'There are no saved servers.' : 'Available: $available'}',
  );
}


/// 给每条目标回一份「同主机的其它名字」。
///
/// 让模型在**第一次**看到清单时就知道哪些名字指向同一台机器，而不是跑完
/// 两遍命令、对比输出之后才发现。
List<ServerListEntry> withAliases(List<ServerListEntry> all) {
  final byHost = <String, List<String>>{};
  for (final e in all) {
    byHost.putIfAbsent(e.host, () => []).add(e.name);
  }
  return [
    for (final e in all)
      if ((byHost[e.host]?.length ?? 0) > 1)
        e._withAliases(
            byHost[e.host]!.where((n) => n != e.name).toList(growable: false))
      else
        e,
  ];
}
