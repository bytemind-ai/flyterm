import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/session_facts.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_executors/job_executors.dart';

/// 造一条带若干 toolCall 的 assistant 消息。
AIMessage calls(List<ToolCall> cs) =>
    AIMessage(role: 'assistant', content: '', toolCalls: cs);

ToolCall call(String name, Map<String, dynamic> args, {String id = 'c1'}) =>
    ToolCall(id: id, name: name, args: args);

void main() {
  group('文件路径', () {
    test('write_file / edit_file 的 path 进 modifiedFiles', () {
      final f = extractSessionFacts([
        calls([call('write_file', {'path': '/etc/a.conf'})]),
        calls([call('edit_file', {'path': '/etc/b.conf'})]),
      ]);
      expect(f.modifiedFiles, ['/etc/a.conf', '/etc/b.conf']);
      expect(f.readFiles, isEmpty);
    });

    test('read_file 的 path 进 readFiles', () {
      final f = extractSessionFacts([
        calls([call('read_file', {'path': '/etc/c.conf'})]),
      ]);
      expect(f.readFiles, ['/etc/c.conf']);
      expect(f.modifiedFiles, isEmpty);
    });

    // 这条是 computeFileLists 的核心：先读后改只算「改过」。
    // 写反了模型会以为那个文件只被读过，于是重复编辑。
    test('先读后改的文件只出现在 modifiedFiles 里', () {
      final f = extractSessionFacts([
        calls([call('read_file', {'path': '/etc/nginx.conf'})]),
        calls([call('edit_file', {'path': '/etc/nginx.conf'})]),
      ]);
      expect(f.modifiedFiles, ['/etc/nginx.conf']);
      expect(f.readFiles, isEmpty, reason: '改过的不该再出现在「只读过」里');
    });

    test('同一个文件被改两次只出现一次', () {
      final f = extractSessionFacts([
        calls([call('edit_file', {'path': '/etc/a.conf'})]),
        calls([call('edit_file', {'path': '/etc/a.conf'})]),
      ]);
      expect(f.modifiedFiles, ['/etc/a.conf']);
    });

    test('结果已排序 —— 同一段历史两次压缩要产出同样的文本', () {
      final f = extractSessionFacts([
        calls([call('edit_file', {'path': '/z.conf'})]),
        calls([call('edit_file', {'path': '/a.conf'})]),
      ]);
      expect(f.modifiedFiles, ['/a.conf', '/z.conf']);
    });

    test('path 不是 String 时跳过，不抛', () {
      final f = extractSessionFacts([
        calls([call('edit_file', {'path': 42})]),
        calls([call('edit_file', {})]),
      ]);
      expect(f.modifiedFiles, isEmpty);
    });

    test('空输入返回空，不抛', () {
      final f = extractSessionFacts([]);
      expect(f.modifiedFiles, isEmpty);
      expect(f.isEmpty, isTrue);
    });
  });

  group('命令', () {
    test('bash 的 command 进 commands', () {
      final f = extractSessionFacts([
        calls([call('bash', {'command': 'systemctl status nginx'})]),
      ]);
      expect(f.commands, ['systemctl status nginx']);
    });

    test('重复的命令只留一条', () {
      final f = extractSessionFacts([
        calls([call('bash', {'command': 'ls /etc'})]),
        calls([call('bash', {'command': 'ls /etc'})]),
      ]);
      expect(f.commands, ['ls /etc']);
    });

    // 命令**按时间倒序**保留最近的，与文件路径的字典序不同：排查场景里
    // 「最近跑过什么」比「字母顺序」有用得多。
    test('超过上限时保留最近的，且顺序是最近在前', () {
      final msgs = [
        for (var i = 0; i < kMaxFactCommands + 5; i++)
          calls([call('bash', {'command': 'cmd$i'}, id: 'c$i')]),
      ];
      final f = extractSessionFacts(msgs);
      expect(f.commands, hasLength(kMaxFactCommands));
      expect(f.commands.first, 'cmd${kMaxFactCommands + 4}',
          reason: '最近的一条排在最前');
      expect(f.commands, isNot(contains('cmd0')), reason: '最早的被省略');
    });

    test('省略条数记在 omittedCommands 上 —— 静默截断会让模型以为这就是全部', () {
      final msgs = [
        for (var i = 0; i < kMaxFactCommands + 5; i++)
          calls([call('bash', {'command': 'cmd$i'}, id: 'c$i')]),
      ];
      expect(extractSessionFacts(msgs).omittedCommands, 5);
    });

    test('没超上限时 omittedCommands 为 0', () {
      final f = extractSessionFacts([
        calls([call('bash', {'command': 'ls'})]),
      ]);
      expect(f.omittedCommands, 0);
    });

    test('去重发生在计数之前 —— 同一条命令跑十次不该算成十条', () {
      final msgs = [
        for (var i = 0; i < kMaxFactCommands + 5; i++)
          calls([call('bash', {'command': 'same'}, id: 'c$i')]),
      ];
      final f = extractSessionFacts(msgs);
      expect(f.commands, ['same']);
      expect(f.omittedCommands, 0);
    });

    test('command 不是 String 时跳过', () {
      final f = extractSessionFacts([
        calls([call('bash', {'command': 42})]),
      ]);
      expect(f.commands, isEmpty);
    });
  });

  group('后台 job', () {
    /// 造一条 run_background 的结果消息。
    ///
    /// **用 `buildJobStartedMessage` 生成，不手写字面量** —— 手写的话，
    /// 生产代码改了文案而测试没改，两边各持一份假设，提取早就断了测试
    /// 却还是绿的。
    AIMessage jobStarted(String id) => AIMessage(
          role: 'tool',
          content: '',
          toolResults: [
            ToolResult(callId: 'c1', content: buildJobStartedMessage(id)),
          ],
        );

    test('round-trip：生成什么就能提取回什么', () {
      final f = extractSessionFacts([jobStarted('job_7f3a')]);
      expect(f.backgroundJobs, ['job_7f3a']);
    });

    test('多个 job 全部提取，去重且排序', () {
      final f = extractSessionFacts([
        jobStarted('job_b'),
        jobStarted('job_a'),
        jobStarted('job_b'),
      ]);
      expect(f.backgroundJobs, ['job_a', 'job_b']);
    });

    test('普通的工具结果不会被误认成 job', () {
      final f = extractSessionFacts([
        const AIMessage(role: 'tool', content: '', toolResults: [
          ToolResult(callId: 'c1', content: 'total 12\ndrwxr-xr-x'),
        ]),
      ]);
      expect(f.backgroundJobs, isEmpty);
    });

    test('前缀对但没有闭合反引号时跳过，不抛也不产出半截 id', () {
      final f = extractSessionFacts([
        const AIMessage(role: 'tool', content: '', toolResults: [
          ToolResult(callId: 'c1', content: '${kJobStartedPrefix}broken'),
        ]),
      ]);
      expect(f.backgroundJobs, isEmpty);
    });
  });

  group('服务器', () {
    test('各工具的 server 参数都收集，去重排序', () {
      final f = extractSessionFacts([
        calls([call('bash', {'command': 'ls', 'server': 'prod-2'})]),
        calls([call('read_file', {'path': '/a', 'server': 'prod-1'})]),
        calls([call('bash', {'command': 'df', 'server': 'prod-2'})]),
      ]);
      expect(f.servers, ['prod-1', 'prod-2']);
    });

    // 单机会话里这个字段恒为空，那一段就整段不出现（见 formatSessionFacts）。
    // 与 hasOtherServers 的既有处理同一个约定：空段是纯浪费。
    test('单机会话里 servers 为空', () {
      final f = extractSessionFacts([
        calls([call('bash', {'command': 'ls'})]),
      ]);
      expect(f.servers, isEmpty);
    });

    test('server 不是 String 时跳过', () {
      final f = extractSessionFacts([
        calls([call('bash', {'command': 'ls', 'server': 7})]),
      ]);
      expect(f.servers, isEmpty);
    });
  });

  group('格式化', () {
    SessionFacts facts({
      List<String> modified = const [],
      List<String> read = const [],
      List<String> commands = const [],
      List<String> jobs = const [],
      List<String> servers = const [],
      int omitted = 0,
    }) =>
        SessionFacts(
          modifiedFiles: modified,
          readFiles: read,
          commands: commands,
          backgroundJobs: jobs,
          servers: servers,
          omittedCommands: omitted,
        );

    test('空事实返回空串 —— 调用方据此整段跳过', () {
      expect(formatSessionFacts(facts()), '');
    });

    test('空的段不输出，不留空标签', () {
      final s = formatSessionFacts(facts(modified: ['/a.conf']));
      expect(s, contains('<modified-files>'));
      expect(s, isNot(contains('<read-files>')));
      expect(s, isNot(contains('<commands-run>')));
      expect(s, isNot(contains('<background-jobs>')));
      expect(s, isNot(contains('<servers>')));
    });

    test('路径逐行列出', () {
      final s = formatSessionFacts(facts(modified: ['/a.conf', '/b.conf']));
      expect(s, contains('<modified-files>\n/a.conf\n/b.conf\n</modified-files>'));
    });

    test('省略了命令时写明还有多少条', () {
      final s = formatSessionFacts(facts(commands: ['ls'], omitted: 7));
      expect(s, contains('7'), reason: '静默截断会让模型以为这就是全部');
    });

    // 标签叫 background-jobs 而不是 jobs-running：我们并不知道它还在不在
    // 跑。声称「正在运行」而它早就结束了，模型会去等一个不会再有输出的 job。
    test('job 段标注状态未知，并指向 check_job', () {
      final s = formatSessionFacts(facts(jobs: ['job_1']));
      expect(s, contains('<background-jobs>'));
      expect(s, contains('job_1'));
      expect(s.toLowerCase(), contains('check_job'));
      expect(s, isNot(contains('jobs-running')));
    });
  });
}
