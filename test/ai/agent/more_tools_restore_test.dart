import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';
import 'more_tools_test.dart' show makeLoopForMoreTools;

/// 与 `more_tools_test.dart` 里的 `_fullTools`（私有、不可跨文件复用）
/// 同形状——恢复出的新 loop 必须拿到同一份 conditional-筛选过的清单，
/// `upload_file` 才有机会被 `filterByUnlockedGroups` 放行。
List<ToolSpec> _fullTools() => agentToolSpecsFor(AgentToolTier.full,
    hasSkills: true, hasOtherServers: true);

void main() {
  test('从含成功 more_tools 的历史恢复后，那一组仍然可用', () async {
    // 先跑一轮真实的解锁，拿到它产出的历史
    final first = makeLoopForMoreTools(group: 'transfer');
    await first.send('传文件');
    final archive = first.toArchive();

    // 用那段历史恢复一个新 loop
    final restored = makeLoop(
      provider: FakeProvider([]),
      toolSpecs: _fullTools,
      restoreFrom: archive,
      // 必须从零起步：默认全解锁会让「历史重建」这件事无从验证 ——
      // 第二条用例（失败的 more_tools 不算数）会变成永远绿的假测试。
      unlockedGroups: const {},
    );
    expect(restored.activeToolNames, contains('upload_file'),
        reason: '不重建的话模型要再解锁一次，白付一轮 cache 重建');
  });

  test('历史里失败的 more_tools 不算数', () async {
    final first = makeLoopForMoreTools(group: 'nope');
    await first.send('x');
    final archive = first.toArchive();

    final restored = makeLoop(
      provider: FakeProvider([]),
      toolSpecs: _fullTools,
      restoreFrom: archive,
      // 必须从零起步：默认全解锁会让「历史重建」这件事无从验证 ——
      // 第二条用例（失败的 more_tools 不算数）会变成永远绿的假测试。
      unlockedGroups: const {},
    );
    expect(restored.activeToolNames, isNot(contains('upload_file')));
  });
}
