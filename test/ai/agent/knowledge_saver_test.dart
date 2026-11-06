import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/knowledge.dart';
import 'package:flyterm/ai/agent/knowledge_saver.dart';

KnowledgeCandidate skill({String name = 'nginx-502', String body = 'B'}) =>
    KnowledgeCandidate(
      target: KnowledgeTarget.skill,
      name: name,
      description: 'd',
      body: body,
    );

void main() {
  // I3：`composeServerNoteAppend` 已经随「signature 改成 (heading, body)
  // 直接转调 `appendNote`」一起删掉了——拼接规则和字节上限现在唯一收口在
  // `ServerNotesManager`（见 `server_notes_manager_test.dart` 里对
  // `composeAppendedNote` / `appendNote` 的覆盖），这个文件不用再测一份
  // 适配层的拼接逻辑。

  group('skill 存入', () {
    test('存入调用 saver 并带上全部字段', () async {
      final calls = <String>[];
      await saveKnowledgeSkill(
        skill(),
        saver: (n, d, b) async => calls.add('$n|$d|$b'),
      );
      expect(calls, equals(['nginx-502|d|B']));
    });

    test('saver 抛异常时原样抛出 —— 调用方要给用户看错误', () async {
      expect(
        () => saveKnowledgeSkill(
          skill(),
          saver: (n, d, b) async => throw StateError('db down'),
        ),
        throwsStateError,
      );
    });
  });
}
