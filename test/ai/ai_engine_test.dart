import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ai/ai_provider.dart';

class _StubProvider extends AIProvider {
  final String reply;
  _StubProvider(this.reply);
  @override String get displayName => 'stub';
  @override String get providerType => 'stub';
  @override Future<String> complete(List<AIMessage> messages) async => reply;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AIEngine> makeEngine({String serverId = 'srv1'}) async {
    final prefs = await SharedPreferences.getInstance();
    return AIEngine(prefs, serverId: serverId);
  }

  test('query appends reply to history', () async {
    final engine = await makeEngine();
    final provider = _StubProvider('Use ls');
    await engine.query('how to list files?', provider: provider);
    expect(engine.history.length, 3); // system + user + assistant
    expect(engine.history.last.role, 'assistant');
    expect(engine.history.last.content, 'Use ls');
  });

  test('query with context injects context into system message', () async {
    final engine = await makeEngine();
    await engine.query('explain this',
        provider: _StubProvider('ok'),
        context: 'Error: permission denied');
    final system = engine.history.first;
    expect(system.role, 'system');
    expect(system.content, contains('Error: permission denied'));
  });

  group('popLastTurn', () {
    test('弹掉最后一轮的提问与回答，早先的轮次留着', () async {
      final engine = await makeEngine();
      await engine.query('第一问', provider: _StubProvider('第一答'));
      await engine.query('第二问', provider: _StubProvider('第二答'));

      final popped = engine.popLastTurn();

      expect(popped?.prompt, '第二问');
      // system + 第一轮的 user/assistant，第二轮整个没了
      expect(engine.history.length, 3);
      expect(engine.history.last.content, '第一答');
    });

    test('连 user 消息一起删 —— 留着会让重发得到两条一样的提问', () async {
      // query() 自己会往尾部追加一条 user。这里如果只删 assistant，重试
      // 之后历史里就是「第一问 / 第一问 / 新回答」。
      final engine = await makeEngine();
      await engine.query('唯一一问', provider: _StubProvider('答'));

      engine.popLastTurn();

      expect(engine.history.where((m) => m.role == 'user'), isEmpty);
    });

    test('不碰 system 消息 —— 删了它重试出来的回答会更差', () async {
      // system 里带着终端快照。删掉之后下一次 query 走的是「没有 context」
      // 那条分支，补一条不带快照的 system，模型看不到用户在看什么。
      final engine = await makeEngine();
      await engine.query('这是什么错',
          provider: _StubProvider('答'), context: 'Error: permission denied');

      engine.popLastTurn();

      expect(engine.history.length, 1);
      expect(engine.history.first.role, 'system');
      expect(engine.history.first.content, contains('permission denied'));
    });

    test('带回 displayText —— 只带 prompt 会把整个终端输出摊到屏幕上', () async {
      // 「会话摘要」那类提问：prompt 里是几百行终端内容，displayText 才是
      // 那句短标签。
      final engine = await makeEngine();
      await engine.query('总结一下\n\n<几百行终端输出>',
          provider: _StubProvider('摘要'), displayText: '总结这次会话');

      final popped = engine.popLastTurn();

      expect(popped?.prompt, contains('几百行终端输出'));
      expect(popped?.displayText, '总结这次会话');
    });

    test('没有可弹的轮次时返回 null', () async {
      final engine = await makeEngine();
      expect(engine.popLastTurn(), isNull);
    });

    test('只有 system 时也返回 null，不误删 system', () async {
      final engine = await makeEngine();
      await engine.query('问', provider: _StubProvider('答'));
      engine.popLastTurn();

      expect(engine.popLastTurn(), isNull);
      expect(engine.history.single.role, 'system');
    });

    test('弹出后重发，历史里只留新的一轮', () async {
      final engine = await makeEngine();
      await engine.query('原问题', provider: _StubProvider('不满意的回答'));

      final popped = engine.popLastTurn()!;
      await engine.query(popped.prompt, provider: _StubProvider('新回答'));

      expect(engine.history.length, 3);
      expect(engine.history.last.content, '新回答');
      expect(engine.history.where((m) => m.content == '不满意的回答'), isEmpty);
    });
  });

  test('clearHistory resets conversation', () async {
    final engine = await makeEngine();
    await engine.query('first', provider: _StubProvider('ok'));
    engine.clearHistory();
    expect(engine.history, isEmpty);
  });

  test('histories are isolated by serverId', () async {
    final prefs = await SharedPreferences.getInstance();
    final e1 = AIEngine(prefs, serverId: 'a');
    final e2 = AIEngine(prefs, serverId: 'b');
    await e1.query('hello', provider: _StubProvider('world'));
    expect(e1.history.length, 3);
    expect(e2.history.isEmpty, isTrue);
  });

  test('looksLikeError detects command not found', () {
    expect(AIEngine.looksLikeError('bash: git: command not found'), isTrue);
  });

  test('looksLikeError ignores normal output', () {
    expect(AIEngine.looksLikeError('Hello, World!'), isFalse);
    expect(AIEngine.looksLikeError('total 48'), isFalse);
  });

  test('looksLikeError detects permission denied', () {
    expect(
        AIEngine.looksLikeError('Permission denied (publickey)'), isTrue);
  });

}
