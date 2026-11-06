import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_groups.dart';

void main() {
  test('save_note 与 save_skill 同在 skills 组', () {
    // 同组是刻意的：两者是一对二选一（「这是跨机套路」vs「这是这台机器的
    // 事」），只解锁其中一个，模型必然把机器事实硬塞进 skill。
    expect(kToolGroups['skills'], contains('save_note'));
    expect(kToolGroups['skills'], contains('save_skill'));
  });

  test('save_note 的 schema 只有 body 必填', () {
    final props =
        saveNoteToolSpec.parameters['properties'] as Map<String, dynamic>;

    expect(props.keys, containsAll(['body', 'heading', 'server']));
    expect(saveNoteToolSpec.parameters['required'], ['body']);
  });

  test('描述里写明是追加不是替换', () {
    // 模型若以为是整份替换，会在 body 里重写全文，把用户手写的部分抹掉 ——
    // 而它看不到完整原文。
    expect(saveNoteToolSpec.description.toLowerCase(), contains('append'));
  });

  test('描述里把它和 save_skill 的分工讲清楚', () {
    expect(saveNoteToolSpec.description, contains('save_skill'));
  });
}
