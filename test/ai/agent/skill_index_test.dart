import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/skill_index.dart';

void main() {
  SkillIndexEntry e(String n, String d) =>
      SkillIndexEntry(name: n, description: d);

  group('composeSkillIndex', () {
    test('空清单返回 null —— 调用方据此整段跳过', () {
      expect(composeSkillIndex(const []), isNull);
    });

    test('每条一行，name 与 description 用冒号分隔', () {
      final out = composeSkillIndex([
        e('nginx-troubleshooting', '502/504 排查'),
        e('deploy-cli', '内部部署工具'),
      ])!;
      expect(out, contains('nginx-troubleshooting: 502/504 排查'));
      expect(out, contains('deploy-cli: 内部部署工具'));
    });

    test('带标题且标题里点名 load_skill', () {
      final out = composeSkillIndex([e('a', 'b')])!;
      expect(out, contains('load_skill'));
    });

    test('保持传入顺序', () {
      final out = composeSkillIndex([e('first', 'x'), e('second', 'y')])!;
      expect(out.indexOf('first'), lessThan(out.indexOf('second')));
    });
  });
}
