import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_completion_service.dart';
import 'package:flyterm/ai/ai_provider.dart';

class _StubProvider extends AIProvider {
  final String reply;
  int callCount = 0;
  _StubProvider(this.reply);

  @override String get displayName => 'stub';

  @override String get providerType => 'stub';

  @override Future<String> complete(List<AIMessage> messages) async {
    callCount++;
    return reply;
  }
}

void main() {
  test('suggest parses multi-line reply into list', () async {
    final svc = AICompletionService();
    final provider = _StubProvider('git commit -m ""\ngit commit --amend\n');
    final results = await svc.suggest(
      currentLine: 'git comm',
      provider: provider,
    );
    expect(results, ['git commit -m ""', 'git commit --amend']);
  });

  test('suggest returns empty on empty reply', () async {
    final svc = AICompletionService();
    final results = await svc.suggest(
      currentLine: 'x',
      provider: _StubProvider(''),
    );
    expect(results, isEmpty);
  });

  test('suggest caches same input to avoid duplicate requests', () async {
    final svc = AICompletionService();
    final provider = _StubProvider('ls -la');
    await svc.suggest(currentLine: 'ls', provider: provider);
    await svc.suggest(currentLine: 'ls', provider: provider);
    expect(provider.callCount, 1);
  });

  test('suggest invalidates cache when input changes', () async {
    final svc = AICompletionService();
    final provider = _StubProvider('ls -la');
    await svc.suggest(currentLine: 'ls', provider: provider);
    await svc.suggest(currentLine: 'ls -', provider: provider);
    expect(provider.callCount, 2);
  });
}
