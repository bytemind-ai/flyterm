// 按工具区分去噪与截断方向的护栏。
//
// `_Resolved.denoise` 决定一次工具调用的输出要不要经过 `denoiseOutput`
// 折叠。这里不测 `denoiseOutput` 本身（见 `output_sanitizer_test.dart`），
// 只测「哪个工具传了什么」这根管线接得对不对——尤其是 `read_file`
// **必须**保持 false：它和 `bash` 共用同一条执行路径（`sed` 也是通过
// `CommandRunner.run` 发出去的），一旦被去噪，行号语义与 `edit_file` 的
// `old_string` 精确匹配都会被破坏。
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/data/models/favorite_command.dart';

import '_fakes.dart';

AIResponse _call(String id, String name, Map<String, dynamic> args) =>
    AIResponse(toolCalls: [ToolCall(id: id, name: name, args: args)]);

void main() {
  test('bash 请求去噪', () async {
    final runner = _RecordingRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        bashCall('c1', 'systemctl status nginx'),
        const AIResponse(text: 'done'),
      ]),
      runner: runner,
      mode: PermissionMode.bypass,
    );

    await loop.send('go');

    expect(runner.lastDenoise, isTrue);
  });

  test('read_file 不去噪 —— 折叠会让 edit_file 的 old_string 匹配失败',
      () async {
    final runner = _RecordingRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        _call('c1', 'read_file', {'path': '/tmp/some.log'}),
        const AIResponse(text: 'done'),
      ]),
      runner: runner,
      mode: PermissionMode.bypass,
    );

    await loop.send('go');

    expect(runner.lastDenoise, isFalse);
  });

  test('check_job 请求去噪 —— 后台任务的输出就是日志', () async {
    final runner = _RecordingRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        _call('c1', 'check_job', {'job_id': 'job-1700000000000-abcd'}),
        const AIResponse(text: 'done'),
      ]),
      runner: runner,
      mode: PermissionMode.bypass,
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full),
    );

    await loop.send('go');

    expect(runner.lastDenoise, isTrue);
  });

  test('grep / glob 不去噪', () async {
    final runner = _RecordingRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        _call('c1', 'grep', {'pattern': 'error'}),
        const AIResponse(text: 'done'),
      ]),
      runner: runner,
      mode: PermissionMode.bypass,
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full),
    );

    await loop.send('go');

    expect(runner.lastDenoise, isFalse);
  });

  test('bash 挖中间 —— journalctl 的错误在尾，systemctl status 的状态在头',
      () async {
    final runner = _RecordingRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        bashCall('c1', 'journalctl -u nginx --no-pager -n 500'),
        const AIResponse(text: 'done'),
      ]),
      runner: runner,
      mode: PermissionMode.bypass,
    );

    await loop.send('go');

    expect(runner.lastTruncate, equals(TruncateMode.middle));
  });

  test('read_file 留头 —— 按 offset 连续读，挖空中间会让内容不连续', () async {
    final runner = _RecordingRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        _call('c1', 'read_file', {'path': '/tmp/some.log'}),
        const AIResponse(text: 'done'),
      ]),
      runner: runner,
      mode: PermissionMode.bypass,
    );

    await loop.send('go');

    expect(runner.lastTruncate, equals(TruncateMode.head));
  });

  test('grep 留头 —— 结果列表，实现里已有 100 条上限', () async {
    final runner = _RecordingRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        _call('c1', 'grep', {'pattern': 'error'}),
        const AIResponse(text: 'done'),
      ]),
      runner: runner,
      mode: PermissionMode.bypass,
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full),
    );

    await loop.send('go');

    expect(runner.lastTruncate, equals(TruncateMode.head));
  });

  test('check_job 挖中间 —— 后台任务的日志尾部才是刚发生的事', () async {
    final runner = _RecordingRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        _call('c1', 'check_job', {'job_id': 'job-1700000000000-abcd'}),
        const AIResponse(text: 'done'),
      ]),
      runner: runner,
      mode: PermissionMode.bypass,
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full),
    );

    await loop.send('go');

    expect(runner.lastTruncate, equals(TruncateMode.middle));
  });

  test('run_saved_command 挖中间 —— 它同样是一条命令', () async {
    // system prompt 对模型说的是「for commands the middle is dropped」。
    // 收藏命令展开之后跑的就是一条普通命令（`journalctl -u myapp -n 2000`
    // 这种很典型），若它仍留头丢尾，模型会以为尾巴还在而不去缩小范围 ——
    // 与 `bash` 漏标 middle 是同一个失败，只是入口不同。
    const saved = FavoriteCommand(
      id: 'd',
      name: '查日志',
      command: 'journalctl -u myapp --no-pager -n 2000',
      aiEnabled: true,
    );
    final runner = _RecordingRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        _call('c1', 'run_saved_command', {'name': '查日志'}),
        const AIResponse(text: 'done'),
      ]),
      runner: runner,
      mode: PermissionMode.bypass,
      toolSpecs: () =>
          agentToolSpecsFor(AgentToolTier.full, hasSavedCommands: true),
      savedCommandProvider: (n) =>
          n.toLowerCase() == saved.name.toLowerCase() ? saved : null,
      savedCommandNamesProvider: () => [saved.name],
    );

    await loop.send('go');

    expect(runner.lastTruncate, equals(TruncateMode.middle));
  });
}

/// 只记录最近一次调用收到的 `denoise` 实参。照
/// `test/ai/agent/command_runner_test.dart` 里 `_RecordingRunner` 的写法
/// （那个是私有类，跨文件用不了，这里单独写一份）。
class _RecordingRunner implements CommandRunner {
  bool? lastDenoise;
  TruncateMode? lastTruncate;

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    lastDenoise = denoise;
    lastTruncate = truncate;
    // job poll 输出至少要有两行才能被 `parseJobPoll` 认成一次正常轮询
    // （见 `background_job.dart`），否则 `check_job` 会提前因为
    // `notFound`/解析失败而短路，压根走不到我们要观察的那次 `.run()`
    // 调用之后的分支——不过 `lastDenoise` 在 `.run()` 被调用的那一刻就已
    // 经记下了，跟后续解析成不成功无关，这里给一个形状正确的输出只是
    // 避免因为异常路径把测试拖得难以排查。
    return const CommandOutput(
      stdout: 'running\n1\n',
      stderr: '',
      exitCode: 0,
    );
  }

  @override
  Future<void> dispose() async {}
}
