// 全局会话（`requireExplicitServer: true`，即不挂任何机器的 AI tab）下的
// job 三件套。
//
// 历史：job 三件套（`run_background` / `check_job` / `list_jobs`）一度整个
// 挂在 `kSessionBoundToolNames` 里 —— 那时它们的执行器硬编码 `runnerProvider
// (null)`，在全局会话里必然失败，所以整条不声明是对的。阶段 1 给三个工具都
// 加了 `server` 参数并接了 `resolveServerTarget`，于是正确的收尾是让它们跟
// `bash` 一样走 `_withRequiredServer`（`server` 从可选变必填），而不是继续
// 整条移除。
//
// 本文件就是那次收缩的守卫：把三个工具名放回 `kSessionBoundToolNames` 会
// 立刻让第一组变红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

ToolSpec? _find(List<ToolSpec> specs, String name) {
  for (final s in specs) {
    if (s.name == name) return s;
  }
  return null;
}

List<String> _required(ToolSpec s) =>
    (s.parameters['required'] as List).cast<String>();

/// 全局会话的最小配置：full 档、有别的机器（`hasOtherServers` 只是让
/// `list_servers` 也在，不影响 job 三件套的取舍）。
List<ToolSpec> _globalSession({
  bool hasSavedCommands = false,
  bool hasAppControl = false,
}) =>
    agentToolSpecsFor(
      AgentToolTier.full,
      hasOtherServers: true,
      hasSavedCommands: hasSavedCommands,
      hasAppControl: hasAppControl,
      requireExplicitServer: true,
    );

void main() {
  group('全局会话下 job 三件套可用', () {
    final specs = _globalSession();

    test('三个 spec 都在，且 server 是必填', () {
      for (final name in const [
        'run_background',
        'check_job',
        'list_jobs',
      ]) {
        final spec = _find(specs, name);
        expect(spec, isNotNull,
            reason: '$name 已经支持 server，不该在全局会话里整条消失');
        expect(_required(spec!), contains('server'),
            reason: '$name 的 server 必须变必填 —— 全局会话没有默认机器');
      }
    });

    test('list_jobs 原先连 required 都没有，加完必填后 required == [server]', () {
      // `list_jobs` 是三个里唯一本无必填参数的：它的 `parameters.properties`
      // 加完 server 后仍只有一个键，`required` 从缺省（null → []）变成
      // ['server']。这条专门盯住「required 列表整个没建出来」的错法 ——
      // 只测 `contains('server')` 时，一个 `required: []` 也能蒙混过去。
      final spec = _find(specs, 'list_jobs')!;
      expect(_required(spec), ['server']);
    });

    test('server 的描述换成「必填 + 本会话不挂任何机器」那版', () {
      // `_withRequiredServer` 会整段替换描述。断言描述确实换了，而不是
      // 只把名字塞进 required —— 后者模型看到的仍是「省略则用当前会话」，
      // 它会照做，然后撞上 MissingServerRunner。
      for (final name in const ['run_background', 'check_job', 'list_jobs']) {
        final desc = ((_find(specs, name)!.parameters['properties']
            as Map)['server'] as Map)['description'] as String;
        expect(desc.toLowerCase(), contains('required'),
            reason: '$name 的 server 描述应当标 required');
        expect(desc.toLowerCase(), isNot(contains('omit')),
            reason: '$name 的 server 描述不该再说「省略则用当前会话」');
      }
    });

    test('bash 的必填行为不受影响（对照组）', () {
      // 证明上面几条不是「整个列表都坏了」式的假通过。
      expect(_required(_find(specs, 'bash')!), contains('server'));
    });
  });

  group('check_job 的设计判断：跟随机制走必填（方案 A）', () {
    // 归属解析顺序是「显式 server > 事件记录的 serverId > 当前会话」。全局
    // 会话里第三档不存在，于是理论上「模型给了 job_id、事件里也记了归属」
    // 时可以不填 server。
    //
    // 仍然选 A（必填），理由写在实现注释里；这里钉住行为本身，免得以后有人
    // 按「能回退就放宽」的直觉把它从必填里摘出去。
    test('server 必填，不保留「靠事件归属兜底」的例外', () {
      final spec = _find(_globalSession(), 'check_job')!;
      expect(_required(spec), contains('server'));
    });

    test('但执行器的归属回退仍然保留 —— 必填只约束模型，不删兜底', () {
      // spec 层的必填是 prompt 侧的强约束；`checkJob` 里的
      // `job?.serverId` 回退仍然有用（终端页会话里模型硬是漏传时，它省掉
      // 一次「job 不存在」的误导）。这条用源码守卫：改工具清单时
      // 顺手把兜底删掉就会红。
      final src = File('lib/ai/agent/tool_executors/job_executors.dart')
          .readAsStringSync();
      expect(src, contains('job?.serverId'),
          reason: 'check_job 的归属回退不该在改工具清单时被顺手删掉');
    });
  });

  group('全局会话仍藏掉真正不支持的工具', () {
    final specs = _globalSession(hasSavedCommands: true, hasAppControl: true);

    test('read_terminal 不在 —— 没有终端屏幕', () {
      expect(_find(specs, 'read_terminal'), isNull);
    });

    test('run_saved_command 不在 —— schema 里压根没有 server 字段', () {
      // 它的执行器不解析 target，且 `runSavedCommandToolSpec` 的 properties
      // 只有 name / params，`_withRequiredServer` 无从下手（它只加必填，
      // 不凭空新增属性）。放进清单 = 模型调用后一路撞 MissingServerRunner，
      // 而那句「请带上 server 重试」在这个工具上没有参数可填。
      expect(_find(specs, 'run_saved_command'), isNull);
    });

    test('download_file / upload_file 不在 —— 执行器仍硬编码 opsProvider(null)', () {
      // 这两个**没有** `resolveServerTarget`，传给它们的 server 会被静默
      // 忽略。它们必须留在集合里，也必须留在 prompt 的负面名单里。
      expect(_find(specs, 'download_file'), isNull);
      expect(_find(specs, 'upload_file'), isNull);
    });

    test('集合本身已经收缩到这四个', () {
      // 直接对真值集合断言，而不是在测试里维护影子拷贝。
      expect(kSessionBoundToolNames, {
        'read_terminal',
        'run_saved_command',
        'download_file',
        'upload_file',
      });
    });
  });

  group('全局会话 prompt 跟上工具集变化', () {
    test('job 三件套被点名进「MUST pass server」那句', () {
      // 工具集变了 prompt 却没跟上，是这一批改动最容易漏的一环：模型看到
      // 必填参数却没有任何「哪台机器」的引导，而在无归属会话里它连默认值
      // 都猜不出来。
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        tier: AgentToolTier.full,
        activeToolNames: const {'bash', 'list_servers'},
        requireExplicitServer: true,
        serverNames: const ['web-1'],
      );
      final line = p
          .split('\n')
          .firstWhere((l) => l.contains('MUST pass `server`'));
      for (final name in const [
        'run_background',
        'check_job',
        'list_jobs',
      ]) {
        expect(line, contains('`$name`'),
            reason: '$name 现在要求必填 server，prompt 必须点名：$line');
      }
    });

    test('绑定式会话不做这个要求（那句整段不出现）', () {
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        tier: AgentToolTier.full,
        hasOtherServers: true,
      );
      expect(p, isNot(contains('MUST pass `server`')));
    });
  });
}
