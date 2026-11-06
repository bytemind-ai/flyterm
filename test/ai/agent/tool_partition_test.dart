import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_partition.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

const _rules = PermissionRuleSet(defaultAllowRules);

ToolCall bash(String cmd) =>
    ToolCall(id: 'x', name: 'bash', args: {'command': cmd});

ToolPartition run(List<ToolCall> calls,
        {PermissionMode mode = PermissionMode.ask}) =>
    partitionToolCalls(calls, rules: _rules, mode: mode, cwd: '/tmp');

void main() {
  test('命中默认放行清单的只读命令进并行桶', () {
    final p = run([
      bash('systemctl status nginx --no-pager'),
      bash('ss -ltnp'),
    ]);
    expect(p.parallel, equals([0, 1]));
    expect(p.serial, isEmpty);
  });

  test('未命中规则的命令进串行桶——它要弹审批，并行没有收益', () {
    final p = run([bash('systemctl restart nginx')]);
    expect(p.parallel, isEmpty);
    expect(p.serial, equals([0]));
  });

  test('带元字符的复合命令进串行桶', () {
    // 样例换过：原本用的是 `ls | grep foo`，两段都在放行清单里，管道窄门
    // 上线后它合法进并行桶，不再是「需审批的复合命令」这个概念的有效样例。
    // 换成第二段含 `tee`（能写文件、不在清单）的写法。
    //
    // 守的性质没变：需审批的命令不进并行桶。窄门放行的那一类由本文件
    // 「管道窄门与分桶判定一致」那组守护。
    final p = run([bash('ls | tee /etc/x')]);
    expect(p.serial, equals([0]));
  });

  test('read_file 视同 cat，命中规则时进并行桶', () {
    final p = run([
      const ToolCall(id: 'r', name: 'read_file', args: {'path': '/etc/hosts'}),
    ]);
    expect(p.parallel, equals([0]));
  });

  test('写文件工具永远进串行桶，即使 bypass 会放行它', () {
    final p = run([
      const ToolCall(id: 'w', name: 'write_file', args: {
        'path': '/tmp/a',
        'content': 'x',
        'description': 'd',
      }),
      const ToolCall(id: 'e', name: 'edit_file', args: {
        'path': '/tmp/b',
        'old_string': 'a',
        'new_string': 'b',
        'description': 'd',
      }),
    ], mode: PermissionMode.bypass);
    expect(p.parallel, isEmpty);
    expect(p.serial, equals([0, 1]));
  });

  test('set_plan 进 local 桶——它完全在本地完成，不该排在审批后面', () {
    // 行为变化：分桶新增 local 桶（见 tool_partition.dart 的
    // kLocalToolNames），set_plan 不再落串行桶。
    final p = run([
      const ToolCall(id: 's', name: 'set_plan', args: {'steps': ['a', 'b']}),
    ]);
    expect(p.local, equals([0]));
    expect(p.serial, isEmpty);
  });

  test('未知工具名进串行桶——由 _executeOne 的闸门去回错', () {
    final p = run([const ToolCall(id: 'u', name: 'k8s_get', args: {})]);
    expect(p.serial, equals([0]));
  });

  test('参数非法的 bash 进串行桶，不因判定不了而崩', () {
    final p = run([
      const ToolCall(id: 'b', name: 'bash', args: {'command': 42}),
      const ToolCall(id: 'c', name: 'bash', args: {}),
      const ToolCall(id: 'd', name: 'read_file', args: {'path': '  '}),
    ]);
    expect(p.parallel, isEmpty);
    expect(p.serial, equals([0, 1, 2]));
  });

  test('bypass 模式下只读命令仍然进并行桶', () {
    final p = run([bash('cat /etc/hosts')], mode: PermissionMode.bypass);
    expect(p.parallel, equals([0]));
  });

  test('bypass 下的非只读命令也进并行桶——bypass 判定就是 allow', () {
    // bypass 让 checkCommand 直接返回 allow，不弹卡，所以并行是安全的：
    // 没有审批要等，也没有写文件工具（那两个已被工具名规则挡在串行桶）。
    final p = run([bash('systemctl restart nginx')],
        mode: PermissionMode.bypass);
    expect(p.parallel, equals([0]));
  });

  test('混合一轮：保持原 index，两桶合起来覆盖全部调用', () {
    final calls = [
      bash('ss -ltnp'),                    // 0 allow
      bash('systemctl restart nginx'),      // 1 需审批
      const ToolCall(id: 'r', name: 'read_file', args: {'path': '/etc/hosts'}), // 2 allow
      const ToolCall(id: 'w', name: 'write_file', args: {                       // 3 写
        'path': '/tmp/a',
        'content': 'x',
        'description': 'd',
      }),
    ];
    final p = run(calls);
    expect(p.parallel, equals([0, 2]));
    expect(p.serial, equals([1, 3]));
    // 比下标集合而不是比长度：长度相等挡不住「0 进了两次、3 被丢了」
    // 这种既重又漏的实现。
    expect({...p.parallel, ...p.serial}, equals({0, 1, 2, 3}));
  });

  test('凭据边界命中时进串行桶', () {
    final p = run([bash('cat /root/.aws/credentials')]);
    expect(p.serial, equals([0]));
  });

  test('传输工具永远落串行桶 —— 两个传输不该同时抢带宽或同时弹两张卡', () {
    final p = run([
      const ToolCall(id: '1', name: 'download_file', args: {
        'remote_path': '/a.log',
        'description': 'x',
      }),
      const ToolCall(id: '2', name: 'upload_file', args: {
        'remote_dir': '/www',
        'description': 'y',
      }),
    ], mode: PermissionMode.bypass);

    expect(p.parallel, isEmpty);
    expect(p.serial, equals([0, 1]));
  });

  test('带 server 的只读命令进并行桶，且判定时不带 cwd', () {
    final p = partitionToolCalls(
      [
        ToolCall(id: '1', name: 'bash', args: {
          'command': 'uptime',
          'description': 'x',
          'server': 'web-1',
        }),
        ToolCall(id: '2', name: 'bash', args: {
          'command': 'uptime',
          'description': 'x',
          'server': 'web-2',
        }),
      ],
      rules: const PermissionRuleSet(defaultAllowRules),
      mode: PermissionMode.ask,
      // 当前 tab 恰好在一个敏感目录里。跨机调用与它无关，不该被它拖进串行桶。
      cwd: '/home/u/.aws',
    );

    expect(p.parallel, equals([0, 1]));
    expect(p.serial, isEmpty);
  });

  test('不带 server 的命令仍然受 cwd 锚定判定约束', () {
    final p = partitionToolCalls(
      [
        ToolCall(id: '1', name: 'bash',
            args: {'command': 'uptime', 'description': 'x'}),
      ],
      rules: const PermissionRuleSet(defaultAllowRules),
      mode: PermissionMode.ask,
      cwd: '/home/u/.aws',
    );

    expect(p.parallel, isEmpty, reason: '敏感 cwd 必须让它落串行桶等审批');
    expect(p.serial, equals([0]));
  });

  group('管道窄门与分桶判定一致', () {
    // 这条测试守的是一个设计决定：窄门放在 checkCommand 内部而非调用点，才能让
    // 分桶预判与执行判定自动一致。缺了它，「分桶判需审批、执行判放行」会把
    // 本可并行的一批跑成串行 —— 不报错，只是变慢，没有任何东西能发现。
    test('纯只读管道进并行桶', () {
      final p = run([
        bash('journalctl -u nginx | grep error'),
        bash('ps aux | grep java'),
      ]);
      expect(p.parallel, equals([0, 1]));
      expect(p.serial, isEmpty);
    });

    test('某段不在清单的管道进串行桶', () {
      final p = run([bash('ps aux | tee /etc/x')]);
      expect(p.parallel, isEmpty);
      expect(p.serial, equals([0]));
    });
  });
}
