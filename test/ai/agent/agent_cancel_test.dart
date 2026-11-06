import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// 回归测试：cancel() / dispose() 与「正要挂起一次新审批」之间的竞态，
/// 有两道独立的闸，各堵各的洞：
///
/// **闸一**（`_awaitApproval` 入口）：`_run()` 每轮开头只在调用 provider
/// *之前* 检查一次 `_cancelRequested`；provider 调用本身是一次真实的异步
/// 往返，返回之后直接进第一个工具调用的审批判定，中间没有第二次检查点。
/// 取消落在这段等待期间时，`_pending` 在 cancel() 那一刻是空的，随后
/// `_awaitApproval` 注册的 completer 没人会去 complete —— 这个洞对**任何**
/// 工具都存在，与 edit_file 无关（下面「模型思考期间」那条测试专门测这个，
/// 用的是最简单的 `bash`）。
///
/// **闸二**（`_executeEditFile` 阶段二结束、阶段三开始之前）：edit_file 是
/// 唯一「一次调用两次审批、中间夹一次远端执行」的路径。bypass 模式下
/// `checkFileWrite` 直接返回 `allow`，阶段三根本不会调用 `_awaitApproval`
/// —— 闸一完全不在这条路径上，取消之后文件照样会被写。这个洞只有
/// edit_file 有，闸二专门堵它。
///
/// **两道闸在 edit_file 的「读执行期间取消」这个时机上会重叠**：闸二的
/// 检查和 `_awaitApproval` 调用之间没有 `await`，纯同步执行，二者对
/// `_cancelRequested` 的判断永远一致，谁先检查都一样 —— 所以 ask 模式那条
/// edit_file 测试即使去掉闸一也不会失败（已用 mutation 验证过，见任务
/// 汇报）。真正能把两道闸的贡献区分开的，是 bypass 模式的 edit_file 测试
/// （只有闸二管得到）和「模型思考期间」的 bash 测试（只有闸一管得到，
/// 闸二在这条路径上根本不存在）。
///
/// **闸三**（`_runFileWrite` 入口，write_file / edit_file 共用的唯一出口）：
/// 把「取消之后不写」从「调用点记得检查」变成写入动作本身的结构性拒绝。
/// 它独占的窗口是 `write_file`（不是 edit_file）+ bypass 模式 + 取消落在
/// 模型思考期间 —— `_executeWriteFile` 从参数校验到 `checkFileWrite` 到
/// `_runFileWrite` 全程同步、零 `await`，bypass 模式下 `checkFileWrite`
/// 直接返回 `allow`，压根不会调用 `_awaitApproval`：闸一不在这条路径上
/// （没人调用它），闸二也不在（那是 `_executeEditFile` 专属代码，
/// `_executeWriteFile` 根本不会走到）。这个组合下，闸三是唯一能拦住写入
/// 的地方。

/// 造出远端「读文件」命令应有的 stdout：三行 sha / size / base64，与
/// `buildReadForEditCommand` 的实际输出格式一致。
CommandOutput _readOut(String content) {
  final bytes = utf8.encode(content);
  return CommandOutput(
    stdout: '${sha256.convert(bytes)}\n${bytes.length}\n'
        '${base64.encode(bytes)}',
    stderr: '',
    exitCode: 0,
  );
}

ToolCall _editCall(String old, String neu, {String path = '/etc/x.conf'}) =>
    ToolCall(id: 'c1', name: 'edit_file', args: {
      'path': path,
      'old_string': old,
      'new_string': neu,
      'description': '改端口',
    });

void main() {
  test('ask 模式：cancel() 落在读取执行期间不会挂起第二次审批', () async {
    late AgentLoop loop;
    final runner = FakeRunner(
      results: [
        _readOut('server {\n  listen 80;\n}\n'),
        const CommandOutput(stdout: '', stderr: '', exitCode: 0),
      ],
      // 用回调而不是赌延迟：读命令一发出（还没返回）就取消，精确命中
      // 「读执行期间」这个窗口，不依赖机器快慢。
      onRun: (_) => loop.cancel(),
    );
    loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      mode: PermissionMode.ask,
      provider: FakeProvider([
        AIResponse(toolCalls: [_editCall('listen 80;', 'listen 8080;')]),
        const AIResponse(text: 'done'),
      ]),
    );

    await loop.send('go').timeout(const Duration(seconds: 5),
        onTimeout: () => fail('取消落在读执行期间时 loop 卡死了 —— 第二次 '
            '审批的 completer 永远没人 complete'));

    expect(loop.pendingApprovals, isEmpty,
        reason: '取消之后不该再冒出一张新的审批卡');
    expect(runner.ran, hasLength(1), reason: '只跑了那次读，写没有被执行');
    expect(loop.stopReason, equals(AgentStopReason.userCancelled));
  });

  test('bypass 模式：cancel() 落在读取执行期间时写命令绝不能被执行', () async {
    // 核心用例。bypass 模式下 checkFileWrite 永远返回 allow，阶段三根本
    // 不会调用 _awaitApproval —— 闸一完全不在这条路径上。唯一能拦住写入
    // 的是阶段二结束、阶段三开始之前那道检查。
    late AgentLoop loop;
    final runner = FakeRunner(
      results: [
        _readOut('server {\n  listen 80;\n}\n'),
        const CommandOutput(stdout: '', stderr: '', exitCode: 0),
      ],
      onRun: (_) => loop.cancel(),
    );
    loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      mode: PermissionMode.bypass,
      provider: FakeProvider([
        AIResponse(toolCalls: [_editCall('listen 80;', 'listen 8080;')]),
        const AIResponse(text: 'done'),
      ]),
    );

    await loop.send('go').timeout(const Duration(seconds: 5),
        onTimeout: () => fail('bypass 模式下取消落在读执行期间时 loop 卡死了'));

    // 断言的重点不是「没挂」，是「没写」——bypass 模式下即便闸一形同虚设，
    // 文件也不该被改动。
    expect(runner.ran, hasLength(1),
        reason: 'bypass 模式下只该跑那次读，写命令绝不能被执行');
    expect(runner.ran, isNot(contains(contains('8080'))),
        reason: '新内容不该出现在任何被执行过的命令里');
    expect(loop.pendingApprovals, isEmpty);
    expect(loop.stopReason, equals(AgentStopReason.userCancelled));
  });

  test('dispose() 落在读取执行期间：loop 能返回，不会卡死', () async {
    // 同上，换成 dispose()：这正是 dispose() 那段注释要防的泄漏 —— 会话
    // 已关，loop 却卡在 await completer.future 上，连同它持有的全部历史
    // 都回收不掉。dispose() 幂等、没有「再点一次」的第二次机会，比 cancel()
    // 更没有退路。
    late AgentLoop loop;
    final runner = FakeRunner(
      results: [
        _readOut('server {\n  listen 80;\n}\n'),
        const CommandOutput(stdout: '', stderr: '', exitCode: 0),
      ],
      onRun: (_) => loop.dispose(),
    );
    loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      mode: PermissionMode.ask,
      provider: FakeProvider([
        AIResponse(toolCalls: [_editCall('listen 80;', 'listen 8080;')]),
        const AIResponse(text: 'done'),
      ]),
    );

    await loop.send('go').timeout(const Duration(seconds: 5),
        onTimeout: () => fail('dispose 落在读执行期间时 loop 卡死了'));

    expect(runner.ran, hasLength(1), reason: '只跑了那次读，写没有被执行');
  });

  test('ask 模式：cancel() 落在模型思考期间时，随后需要审批的调用不会挂起', () async {
    // 专门隔离闸一的用例：跟 edit_file 无关，用最简单的 bash 就能复现 ——
    // 证明这个洞是 _run() 结构性的，不是 edit_file 独有。
    //
    // FakeProvider.onCall 在 completeWithTools 内部、返回响应之前触发，
    // 模拟「取消恰好发生在等 provider 网络往返期间」：此时 _pending 还是
    // 空的（还没解析出工具调用），cancel() 什么都叫不醒。随后 _run() 里
    // provider 调用返回，直接进 bash 的审批判定，中间没有第二次检查点 ——
    // 如果 _awaitApproval 不自己查 _cancelRequested，这里注册的 completer
    // 永远没人 complete。
    late AgentLoop loop;
    final provider = FakeProvider(
      [bashCall('c1', 'systemctl restart nginx')],
      onCall: (_) => loop.cancel(),
    );
    final runner = FakeRunner();
    loop = makeLoop(provider: provider, runner: runner, mode: PermissionMode.ask);

    await loop.send('go').timeout(const Duration(seconds: 5),
        onTimeout: () => fail('取消落在模型思考期间时 loop 卡死了 —— 闸一没有拦住'));

    expect(loop.pendingApprovals, isEmpty);
    expect(runner.ran, isEmpty, reason: '需要审批的命令不该被执行');
    expect(loop.stopReason, equals(AgentStopReason.userCancelled));
  });

  test('bypass 模式：cancel() 落在模型思考期间时，write_file 绝不能被执行', () async {
    // 专门隔离闸三的用例。write_file（不是 edit_file）+ bypass 模式 +
    // 取消落在模型思考期间：闸一不在路径上（bypass 下压根不调用
    // `_awaitApproval`），闸二也不在路径上（那是 `_executeEditFile` 专属，
    // `_executeWriteFile` 不会走到）—— 只有 `_runFileWrite` 入口那道闸能
    // 拦住这次写。
    late AgentLoop loop;
    final provider = FakeProvider(
      [
        const AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'write_file', args: {
            'path': '/etc/x.conf',
            'content': 'listen 8080;',
          }),
        ]),
      ],
      onCall: (_) => loop.cancel(),
    );
    final runner = FakeRunner();
    loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      provider: provider,
      runner: runner,
      mode: PermissionMode.bypass,
    );

    await loop.send('go').timeout(const Duration(seconds: 5),
        onTimeout: () =>
            fail('bypass 模式下取消落在模型思考期间时 loop 卡死了'));

    // 断言的重点同样是「没写」，不是「没挂」——bypass 模式没有审批可挂起，
    // 唯一有意义的失败方式是写命令被悄悄发了出去。
    expect(runner.ran, isEmpty, reason: 'write_file 命令根本不该被发出');
    expect(loop.pendingApprovals, isEmpty);
    expect(loop.stopReason, equals(AgentStopReason.userCancelled));
  });
}
