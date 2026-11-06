import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/agent/agent_session_manager.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('知识沉淀开关', () {
    test('默认开启', () async {
      final mgr = AgentSessionManager(await SharedPreferences.getInstance());
      expect(mgr.knowledgeCaptureEnabled, isTrue);
    });

    test('可以关掉并持久化——换一个 manager 实例（模拟重启）仍读到 false',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = AgentSessionManager(prefs);
      mgr.knowledgeCaptureEnabled = false;

      expect(AgentSessionManager(prefs).knowledgeCaptureEnabled, isFalse);
    });

    test('改动会通知监听者', () async {
      final mgr = AgentSessionManager(await SharedPreferences.getInstance());
      var count = 0;
      mgr.addListener(() => count++);

      mgr.knowledgeCaptureEnabled = false;

      expect(count, equals(1));
    });
  });
}
