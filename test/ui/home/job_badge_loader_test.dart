import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ui/home/job_badge_loader.dart';

Server _srv(String id, {String type = 'ssh'}) => Server(
      id: id,
      name: id,
      host: '$id.example.com',
      port: 22,
      username: 'root',
      authType: 'password',
      serverType: type,
    );

/// 造一份 `buildJobListCommand` 的合法输出：一行一个 job，
/// `id|状态|日志行数|mtime`。状态为 `running` 或退出码数字。
CommandOutput _out(List<String> lines) => CommandOutput(
      stdout: lines.join('\n'),
      stderr: '',
      exitCode: 0,
    );

/// [suffix] 必须是合法的 4 位十六进制（`isValidJobId` 的 `[0-9a-f]{4}`
/// 锚定正则所要求的），否则这一行会被 `parseJobList` 当成不可识别条目跳过，
/// 不计入 running 数。
String _job(String suffix, {required bool running}) =>
    'job-1700000000000-$suffix|${running ? 'running' : '0'}|10|1700000000';

void main() {
  test('只扫 shouldScan 为真的机器', () async {
    final scanned = <String>[];
    final counts = await loadRunningJobCounts(
      servers: [_srv('a'), _srv('b'), _srv('c')],
      shouldScan: (s) => s.id == 'b',
      run: (s, cmd) async {
        scanned.add(s.id);
        return _out([_job('a001', running: true)]);
      },
    );

    expect(scanned, ['b']);
    expect(counts, {'b': 1});
  });

  test('只数 running 的那些', () async {
    final counts = await loadRunningJobCounts(
      servers: [_srv('a')],
      shouldScan: (_) => true,
      run: (_, __) async => _out([
        _job('a001', running: true),
        _job('a002', running: false),
        _job('a003', running: true),
      ]),
    );

    expect(counts, {'a': 2});
  });

  test('扫到 0 个也进 Map（与"没扫"区分开）', () async {
    final counts = await loadRunningJobCounts(
      servers: [_srv('a')],
      shouldScan: (_) => true,
      run: (_, __) async => _out([]),
    );

    expect(counts.containsKey('a'), isTrue);
    expect(counts['a'], 0);
  });

  test('单台失败不影响其余，失败的不进 Map', () async {
    final counts = await loadRunningJobCounts(
      servers: [_srv('a'), _srv('b')],
      shouldScan: (_) => true,
      run: (s, __) async {
        if (s.id == 'a') throw Exception('connection refused');
        return _out([_job('a001', running: true)]);
      },
    );

    expect(counts.containsKey('a'), isFalse);
    expect(counts['b'], 1);
  });

  test('local 机器跳过（跑不了 run_background）', () async {
    final scanned = <String>[];
    await loadRunningJobCounts(
      servers: [_srv('a', type: 'local'), _srv('b')],
      shouldScan: (_) => true,
      run: (s, __) async {
        scanned.add(s.id);
        return _out([]);
      },
    );

    expect(scanned, ['b']);
  });

  test('并发不超过 maxConcurrent', () async {
    var inFlight = 0;
    var peak = 0;
    await loadRunningJobCounts(
      servers: [for (var i = 0; i < 10; i++) _srv('s$i')],
      shouldScan: (_) => true,
      maxConcurrent: 3,
      run: (_, __) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return _out([]);
      },
    );

    expect(peak, lessThanOrEqualTo(3));
    expect(peak, 3, reason: '10 台机器、上限 3，应该跑满');
  });

  test('没有可扫的机器时返回空 Map 且一次都不跑', () async {
    var calls = 0;
    final counts = await loadRunningJobCounts(
      servers: [_srv('a')],
      shouldScan: (_) => false,
      run: (_, __) async {
        calls++;
        return _out([]);
      },
    );

    expect(counts, isEmpty);
    expect(calls, 0);
  });
}
