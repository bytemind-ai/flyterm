import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/ai_engine.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('global engine writes history under the reserved key', () async {
    final prefs = await SharedPreferences.getInstance();
    // 预置一段历史，验证它能被按保留 key 读回来。
    await prefs.setString(
      'ai_chat_history_${AIEngine.kGlobalServerId}',
      '[{"role":"user","content":"hi"}]',
    );

    final engine = AIEngine(prefs, serverId: AIEngine.kGlobalServerId);

    expect(engine.history.length, 1);
    expect(engine.history.first.content, 'hi');
  });

  test('reserved id cannot collide with a real server UUID', () {
    // 真实 serverId 是 uuid v4，只含 hex 与连字符；保留 id 带下划线。
    expect(AIEngine.kGlobalServerId.contains('_'), isTrue);
    expect(
      RegExp(r'^[0-9a-f-]+$').hasMatch(AIEngine.kGlobalServerId),
      isFalse,
    );
  });
}
