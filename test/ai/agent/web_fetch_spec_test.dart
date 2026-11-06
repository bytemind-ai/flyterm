import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_tools.dart';

void main() {
  group('web_fetch 的工具声明', () {
    test('只进 full 档，lean 档没有它', () {
      // via 的语义（内网走远端、公网走手机）对本地小模型太抽象，而 lean
      // 档的准入标准是「最不容易写坏的形状」。
      expect(fullToolSpecs.map((s) => s.name), contains('web_fetch'));
      expect(leanToolSpecs.map((s) => s.name), isNot(contains('web_fetch')));
    });

    test('url 必填，via 可选且限定两个值', () {
      final spec = fullToolSpecs.firstWhere((s) => s.name == 'web_fetch');
      final props = spec.parameters['properties'] as Map<String, dynamic>;
      expect(spec.parameters['required'], ['url']);
      expect(props.keys, containsAll(['url', 'via']));
      expect((props['via'] as Map)['enum'], ['phone', 'server']);
    });

    test('不给 headers / method / body —— 那会把它变成任意 HTTP 客户端', () {
      final spec = fullToolSpecs.firstWhere((s) => s.name == 'web_fetch');
      final props = spec.parameters['properties'] as Map<String, dynamic>;
      expect(props.keys, isNot(contains('headers')));
      expect(props.keys, isNot(contains('method')));
      expect(props.keys, isNot(contains('body')));
    });

    test('描述里说明只读与上限', () {
      final spec = fullToolSpecs.firstWhere((s) => s.name == 'web_fetch');
      expect(spec.description.toLowerCase(), contains('get only'));
      expect(spec.description, contains('8 KiB'));
    });
  });
}
