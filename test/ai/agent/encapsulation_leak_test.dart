import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import '_fakes.dart';

/// 只读 getter 不能把内部可变集合漏出去。
///
/// `unlockedToolGroups` 与 `searchedSkillNames` 都曾直接返回内部 Set 本身。
/// 调用方拿到之后一句 `.add()` 就能改掉 loop 的门控状态 —— 绕过
/// `unlockToolGroup()`（那里有缓存失效这一行），并且不会有任何编译错误。
///
/// 同文件其余 getter 一律用 `List.unmodifiable`（`events` / `plan` /
/// `debugHistory` …），这两个是漏网的。
///
/// 用「加进去然后断言没生效」来测，而不是断言抛异常：抛不抛是实现细节，
/// **真正要守的是「外部改不动内部」**。
void main() {
  test('unlockedToolGroups 返回的集合改不动内部状态', () {
    final loop = makeLoop(provider: FakeProvider([]));

    final leaked = loop.unlockedToolGroups;
    // 若返回的是内部集合本身，这一句就悄悄改掉了门控状态。
    try {
      leaked.add('some_group');
    } catch (_) {
      // 不可变集合会抛 —— 两种拒绝方式都算通过，见上方说明。
    }

    expect(loop.unlockedToolGroups.contains('some_group'), isFalse,
        reason: '外部拿到的 Set 居然能改内部门控状态');
  });

  test('searchedSkillNames 返回的集合改不动内部状态', () {
    final loop = makeLoop(provider: FakeProvider([]));

    final leaked = loop.searchedSkillNames;
    try {
      leaked.add('some_skill');
    } catch (_) {}

    expect(loop.searchedSkillNames.contains('some_skill'), isFalse,
        reason: '外部拿到的 Set 居然能改内部「已搜过」状态');
  });

  test('清空外部引用同样不影响内部', () {
    final loop = makeLoop(provider: FakeProvider([]));
    loop.unlockToolGroup('g1');
    expect(loop.unlockedToolGroups, contains('g1'));

    try {
      loop.unlockedToolGroups.clear();
    } catch (_) {}

    expect(loop.unlockedToolGroups, contains('g1'),
        reason: '外部 clear() 把内部状态清掉了');
  });
}
