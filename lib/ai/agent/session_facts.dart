// SPDX-License-Identifier: GPL-3.0-or-later
import '../ai_message.dart';
import 'tool_executors/job_executors.dart' show kJobStartedPrefix;
import 'tool_models.dart';

/// `commands` 最多保留几条。
///
/// 一个长会话几十条命令，全列进去等于把 compaction 省下的又吐回去。20 条
/// 按每条 40 字符估算约 800 字节 —— 与单条工具输出的截断阈值（8 KiB）比是
/// 小头，而它换来的是「别重跑已经跑过的检查」。
const int kMaxFactCommands = 20;

/// compaction 时从被砍掉的历史里提取的确定性事实。
///
/// ## 为什么不让模型总结这些
///
/// 摘要 prompt 原先要求模型「逐字抄」改过的文件路径和 job id。模型抄标识符
/// 会漏（长列表尤其——它天然倾向概括）、会错（抄错 job id 会让它去
/// `check_job` 一个不存在的东西），还要花 output token 复述本来就躺在
/// `ToolCall.args` 里的字符串。
///
/// 这些事实用代码提取是确定的，交给模型是概率的。
///
/// 全部字段都**已排序、已去重**：它会被直接拼进历史消息，顺序不稳定会让
/// 同一段会话在两次压缩里产出不同的文本，白白击穿 prompt cache。
class SessionFacts {
  /// 被 `write_file` / `edit_file` 动过的路径。
  final List<String> modifiedFiles;

  /// 只被 `read_file` 读过、**没被改过**的路径。改过的一律归 [modifiedFiles]。
  final List<String> readFiles;

  /// 跑过的 `bash` 命令，去重，最多 [kMaxFactCommands] 条。
  final List<String> commands;

  /// 本会话启动过的后台 job id。**不保证仍在运行**，见 `formatSessionFacts`。
  final List<String> backgroundJobs;

  /// 操作过的服务器名（工具的 `server` 参数）。单机会话恒为空。
  final List<String> servers;

  /// [commands] 因上限而省略掉的条数。0 = 没有省略。
  final int omittedCommands;

  const SessionFacts({
    required this.modifiedFiles,
    required this.readFiles,
    required this.commands,
    required this.backgroundJobs,
    required this.servers,
    required this.omittedCommands,
  });

  bool get isEmpty =>
      modifiedFiles.isEmpty &&
      readFiles.isEmpty &&
      commands.isEmpty &&
      backgroundJobs.isEmpty &&
      servers.isEmpty;
}

/// 从被砍掉的那段历史里提取事实。**纯函数、无 IO。**
SessionFacts extractSessionFacts(List<AIMessage> dropped) {
  final read = <String>{};
  final modified = <String>{};
  // LinkedHashSet 的插入顺序 = 首次出现的顺序，去重与顺序一次拿到。
  final commands = <String>{};
  final jobs = <String>{};
  final servers = <String>{};

  for (final m in dropped) {
    for (final t in m.toolCalls ?? const <ToolCall>[]) {
      final server = t.args['server'];
      if (server is String && server.trim().isNotEmpty) servers.add(server);
      if (t.name == 'bash') {
        final cmd = t.args['command'];
        if (cmd is String && cmd.trim().isNotEmpty) commands.add(cmd);
        continue;
      }
      final path = t.args['path'];
      if (path is! String || path.trim().isEmpty) continue;
      switch (t.name) {
        case 'read_file':
          read.add(path);
        case 'write_file':
        case 'edit_file':
          modified.add(path);
      }
    }

    for (final r in m.toolResults ?? const <ToolResult>[]) {
      // job id 是唯一一个不在 args 里的事实 —— 它由客户端生成后回填进
      // 结果文本。逆 `buildJobStartedMessage`：前缀之后到第一个反引号
      // 之间就是 id。
      if (!r.content.startsWith(kJobStartedPrefix)) continue;
      final rest = r.content.substring(kJobStartedPrefix.length);
      final end = rest.indexOf('`');
      // end <= 0：没有闭合反引号，或者 id 是空的。两种都跳过 —— 产出一个
      // 半截 id 比不产出更糟，模型会拿它去 check_job。
      if (end <= 0) continue;
      jobs.add(rest.substring(0, end));
    }
  }

  // 改过的从「只读过」里剔除 —— 一个文件先读后改，只该出现在「改过」里。
  // 两边都列会让模型以为是两个不同的文件。
  final readOnly = read.difference(modified).toList()..sort();
  final modifiedList = modified.toList()..sort();

  // 命令按**时间倒序**取最近的 N 条，与文件路径的字典序不同：排查时
  // 「最近跑过什么」比字母顺序有用。去重在截断之前完成，所以同一条命令
  // 跑十次只占一个名额。
  final allCommands = commands.toList().reversed.toList();
  final keptCommands = allCommands.take(kMaxFactCommands).toList();
  final omitted = allCommands.length - keptCommands.length;

  return SessionFacts(
    modifiedFiles: modifiedList,
    readFiles: readOnly,
    commands: keptCommands,
    backgroundJobs: jobs.toList()..sort(),
    servers: servers.toList()..sort(),
    omittedCommands: omitted,
  );
}

/// 把事实拼成塞进摘要消息的那一段。空事实返回空串。
///
/// **用 XML 标签而不是分隔线**：边界明确，模型不会把清单里的路径读成叙事
/// 的一部分。长清单下 `--- 分隔线 ---` 容易糊。
String formatSessionFacts(SessionFacts f) {
  if (f.isEmpty) return '';
  final buf = StringBuffer();

  void section(String tag, List<String> items) {
    if (items.isEmpty) return;
    buf.writeln('<$tag>');
    for (final i in items) {
      buf.writeln(i);
    }
    buf.writeln('</$tag>');
  }

  section('modified-files', f.modifiedFiles);
  section('read-files', f.readFiles);

  if (f.commands.isNotEmpty) {
    buf.writeln('<commands-run>');
    for (final c in f.commands) {
      buf.writeln(c);
    }
    // 省略数必须写出来 —— 静默截断会让模型以为这就是跑过的全部，
    // 于是重跑那些被省掉的检查。
    if (f.omittedCommands > 0) {
      buf.writeln('(${f.omittedCommands} earlier commands omitted)');
    }
    buf.writeln('</commands-run>');
  }

  if (f.backgroundJobs.isNotEmpty) {
    // 标签刻意叫 background-jobs 而不是 jobs-running：要断言「还在跑」
    // 就得解析 check_job 的输出，那是第二层同样脆弱的文本耦合。说「状态
    // 未知」是诚实的；声称正在运行而它早已结束，模型会去等一个永远不会
    // 再有输出的 job。
    buf.writeln('<background-jobs>');
    for (final j in f.backgroundJobs) {
      buf.writeln(j);
    }
    buf.writeln('(status unknown — call `check_job` to confirm)');
    buf.writeln('</background-jobs>');
  }

  section('servers', f.servers);

  return buf.toString().trimRight();
}
