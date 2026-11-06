import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// 轮询等到「审批」出现，而不是赌一个固定延迟。
///
/// 抄自 `agent_edit_file_test.dart` 的 `_waitForPendingApproval`：这条链路在
/// 弹审批之前会经过至少一次真实 `FakeRunner` 调用（真实 `Timer` 模拟网络延迟，
/// 见 `_fakes.dart` 的说明），固定的 `Future.delayed` 在机器负载高时不稳定，
/// 轮询直到条件成立（或明确超时报错）不管机器多慢都不会误判。
Future<void> _waitForPendingApproval(AgentLoop loop) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (loop.pendingApprovals.isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for a pending approval');
    }
    await Future.delayed(const Duration(milliseconds: 5));
  }
}

/// 轮询等到**下一张**审批卡出现 —— 用于第一条命令应答之后等第二条命令弹卡。
///
/// 不能只判断 `pendingApprovals.isNotEmpty`：应答刚发出的那一刻，第一张卡
/// 可能还没被状态机翻成非 awaitingApproval，直接判空非空会偶发地在第二张卡
/// 出现前就误判命中（拿到的其实还是第一张旧卡，但此时它已经被 respond 过，
/// 正常不会再出现在 pendingApprovals 里——这里仍然按 seq 排除，与
/// `agent_edit_file_test.dart` 的写法保持一致，防御性地堵住任何时序缝隙）。
Future<void> _waitForNextApproval(AgentLoop loop, int excludeSeq) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (loop.pendingApprovals.isEmpty ||
      loop.pendingApprovals.single.seq == excludeSeq) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the next pending approval');
    }
    await Future.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  // 一条必然命中凭据 deny 的只读命令。
  const denyCmd = 'cat /root/.ssh/id_rsa';

  test('bypass 档：静默之后同一条命令不再弹卡', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        bashCall('c1', denyCmd),
        bashCall('c2', denyCmd),
        const AIResponse(text: 'done'),
      ]),
      mode: PermissionMode.bypass,
      rules: const PermissionRuleSet(defaultAllowRules),
    );

    final future = loop.send('看一下');
    await _waitForPendingApproval(loop);
    final ev = loop.pendingApprovals.single;
    expect(ev.check.denyHit, isTrue);

    loop.respondApproval(ev.seq, ApprovalDecision.allowOnce,
        silenceInSession: true);
    await future;

    // 第二轮同一条命令：不应再产生等待审批的卡。
    expect(loop.pendingApprovals, isEmpty);
    expect(
      loop.events
          .whereType<ToolCallEvent>()
          .where((e) => e.status == ToolCallStatus.awaitingApproval),
      isEmpty,
    );
  });

  test('bypass 档：命令改一个参数就重新问', () async {
    // 用追加一个 flag 而不是追加 `.pub2`——后者会被 `id_(?!\w*\.pub)` 的负向
    // 前瞻当成公钥放行，命中不到凭据 deny，也就弹不出第二张卡，测不出
    // 「key 是整条命令原文」这件事。
    final loop = makeLoop(
      provider: FakeProvider([
        bashCall('c1', denyCmd),
        bashCall('c2', '$denyCmd -v'),
      ]),
      mode: PermissionMode.bypass,
      rules: const PermissionRuleSet(defaultAllowRules),
    );

    final future = loop.send('看一下');
    await _waitForPendingApproval(loop);
    final ev1 = loop.pendingApprovals.single;
    loop.respondApproval(ev1.seq, ApprovalDecision.allowOnce,
        silenceInSession: true);

    // 第二条命令不同 → 仍然弹卡。key 是整条命令原文，不是文件路径。
    await _waitForNextApproval(loop, ev1.seq);
    final ev2 = loop.pendingApprovals.single;
    expect(ev2.seq, isNot(equals(ev1.seq)));
    expect(ev2.check.denyHit, isTrue);

    loop.respondApproval(ev2.seq, ApprovalDecision.reject);
    await future;
  });

  test('ask 档：即使标记过静默也照常弹卡', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        bashCall('c1', denyCmd),
        bashCall('c2', denyCmd),
        const AIResponse(text: 'done'),
      ]),
      mode: PermissionMode.ask,
      rules: const PermissionRuleSet(defaultAllowRules),
    );

    final future = loop.send('看一下');
    await _waitForPendingApproval(loop);
    final ev1 = loop.pendingApprovals.single;
    // ask 档下 UI 本不该渲染「本轮不再问」按钮（那是 UI 的事），但 loop 侧
    // 的判定不能依赖 UI 老实——即便调用方仍然传了 silenceInSession: true，
    // ask 档下 `_isSilenced` 也必须永不为真。
    loop.respondApproval(ev1.seq, ApprovalDecision.allowOnce,
        silenceInSession: true);

    await _waitForNextApproval(loop, ev1.seq);
    expect(loop.pendingApprovals, isNotEmpty,
        reason: 'ask 档下静默集合存在但永不被查');

    loop.respondApproval(
        loop.pendingApprovals.single.seq, ApprovalDecision.allowOnce);
    await future;
  });

  test('静默集合不进归档，也不跨会话生效', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        bashCall('c1', denyCmd),
        const AIResponse(text: 'done'),
      ]),
      mode: PermissionMode.bypass,
      rules: const PermissionRuleSet(defaultAllowRules),
    );

    final future = loop.send('看一下');
    await _waitForPendingApproval(loop);
    loop.respondApproval(loop.pendingApprovals.single.seq,
        ApprovalDecision.allowOnce, silenceInSession: true);
    await future;

    final archive = loop.toArchive();
    // 静默集合不是一个会被落盘的字段——归档的键集合里不该出现它的影子。
    expect(archive.keys, isNot(contains('silencedCommands')));
    expect(archive.keys, isNot(contains('approvalTargets')));

    // 换一个新 loop（哪怕是从同一份归档恢复出来的）再问同一条命令，必须
    // 重新弹卡——静默不允许通过归档这条通道跨会话生效。
    final restored = makeLoop(
      provider: FakeProvider([bashCall('c2', denyCmd)]),
      mode: PermissionMode.bypass,
      rules: const PermissionRuleSet(defaultAllowRules),
      restoreFrom: archive,
    );
    final f2 = restored.send('再看一次');
    await _waitForPendingApproval(restored);
    expect(restored.pendingApprovals, isNotEmpty);

    restored.respondApproval(
        restored.pendingApprovals.single.seq, ApprovalDecision.reject);
    await f2;
  });
}
