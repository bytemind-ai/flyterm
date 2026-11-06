import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ui/jobs/job_board_controller.dart';

// `Server` 是 const 构造，`serverType` 有默认值。照
// `test/ai/agent/agent_exec_channel_test.dart` 里 `const _server` 的写法,
// 只给必填字段；serverType 这里要显式传，因为有一条测试要区分 local。
Server srv(String id, {String type = 'ssh'}) => Server(
      id: id,
      name: id,
      host: '$id.example.com',
      port: 22,
      username: 'ops',
      authType: 'password',
      serverType: type,
    );

CommandOutput out(String s) =>
    CommandOutput(stdout: s, stderr: '', exitCode: 0);

void main() {
  test('local 类型的服务器不进列表——它跑不了 run_background', () {
    final c = JobBoardController(
      servers: [srv('a'), srv('local1', type: 'local')],
      probe: (_) => true,
      run: (_, __) async => out(''),
    );
    expect(c.groups.map((g) => g.server.id), ['a']);
  });

  test('分组顺序按传入顺序固定，不按完成顺序', () async {
    // 渐进式加载最容易犯的错：先返回的先排。那样每次打开排列都不一样,
    // 加载过程中列表还会跳动。
    final c = JobBoardController(
      servers: [srv('slow'), srv('fast')],
      probe: (_) => true,
      run: (s, __) async {
        if (s.id == 'slow') {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        return out('job-1757000000000-aaaa|running|1|0\n');
      },
    );
    await c.refreshAll();
    expect(c.groups.map((g) => g.server.id), ['slow', 'fast']);
  });

  test('有活连接的先扫', () async {
    final order = <String>[];
    final c = JobBoardController(
      servers: [srv('cold'), srv('warm')],
      probe: (s) => s.id == 'warm',
      run: (s, __) async {
        order.add(s.id);
        return out('');
      },
    );
    await c.refreshAll();
    expect(order.first, 'warm');
  });

  test('组内：运行中的排前面，各自按 startedAt 倒序', () async {
    final c = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, __) async => out('job-1757000000001-aaaa|0|1|0\n'
          'job-1757000000002-bbbb|running|1|0\n'
          'job-1757000000003-cccc|running|1|0\n'),
    );
    await c.refreshAll();
    expect(c.groups.single.jobs.map((j) => j.id), [
      'job-1757000000003-cccc',
      'job-1757000000002-bbbb',
      'job-1757000000001-aaaa',
    ]);
  });

  test('单台失败不影响其他台', () async {
    final c = JobBoardController(
      servers: [srv('bad'), srv('good')],
      probe: (_) => true,
      run: (s, __) async {
        if (s.id == 'bad') throw Exception('connect failed');
        return out('job-1757000000000-aaaa|running|1|0\n');
      },
    );
    await c.refreshAll();
    final bad = c.groups.firstWhere((g) => g.server.id == 'bad');
    final good = c.groups.firstWhere((g) => g.server.id == 'good');
    expect(bad.state, JobLoadState.failed);
    expect(bad.error, contains('connect failed'));
    expect(good.state, JobLoadState.done);
    expect(good.jobs, hasLength(1));
  });

  test('dispose 之后到达的结果不再 notify —— 打开看板马上退回去是最常见的序列',
      () async {
    // 冷机器建连可能要十几秒（命令超时上限 20 秒），用户返回后 dispose,
    // 那时这一批 _load 还在飞。debug 构建下 notifyListeners 会撞
    // assert(debugAssertNotDisposed)。
    final gate = Completer<CommandOutput>();
    final c = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, __) => gate.future,
    );
    final pending = c.refreshAll();
    c.dispose();
    gate.complete(out(''));
    await pending; // 不该抛
  });

  test('全部误判为 warm 时并发仍然受限 —— probe 是 TOCTOU 的，不能豁免配额', () async {
    // hasLiveConnection 的注释写明「判错的代价必须只是那台机器慢一点」。
    // 若 warm 组直接全部起飞，Wi-Fi 切蜂窝后一批 channel 同时误判就会让
    // N 条握手绕过上限 —— 正是这个常量要防的失效。
    var inFlight = 0;
    var peak = 0;
    final c = JobBoardController(
      servers: [for (var i = 0; i < 10; i++) srv('s$i')],
      probe: (_) => true, // 全都自称有活连接
      run: (_, __) async {
        inFlight++;
        peak = peak > inFlight ? peak : inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return out('');
      },
    );
    await c.refreshAll();
    expect(peak, lessThanOrEqualTo(JobBoardController.kMaxConcurrentConnects));
  });

  test('建连并发不超过 4', () async {
    var inFlight = 0;
    var peak = 0;
    final c = JobBoardController(
      servers: [for (var i = 0; i < 10; i++) srv('s$i')],
      probe: (_) => false, // 全都要新建连接
      run: (_, __) async {
        inFlight++;
        peak = peak > inFlight ? peak : inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return out('');
      },
    );
    await c.refreshAll();
    expect(peak, lessThanOrEqualTo(4));
  });

  test('空态三分：没服务器 / 没任务 / 全失败', () async {
    final none = JobBoardController(
        servers: [], probe: (_) => true, run: (_, __) async => out(''));
    await none.refreshAll();
    expect(none.emptyKind, JobBoardEmpty.noServers);

    final empty = JobBoardController(
        servers: [srv('a')], probe: (_) => true, run: (_, __) async => out(''));
    await empty.refreshAll();
    expect(empty.emptyKind, JobBoardEmpty.noJobs);

    final broken = JobBoardController(
      servers: [srv('a')],
      probe: (_) => true,
      run: (_, __) async => throw Exception('nope'),
    );
    await broken.refreshAll();
    // 「查不到」和「没有任务」不是一回事，不能显示同一个空态。
    expect(broken.emptyKind, JobBoardEmpty.none);
  });
}
