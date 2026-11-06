import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/ai_provider.dart';

class _StubProvider extends AIProvider {
  @override
  String get displayName => 'stub';
  @override
  String get providerType => 'stub';
  @override
  Future<String> complete(List<AIMessage> messages) async => '';
}

Future<AIProviderService> _makeSvc() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AIProviderService(prefs);
}

void main() {
  test('hasProvider is false initially', () async {
    expect((await _makeSvc()).hasProvider, isFalse);
  });

  test('setProvider makes hasProvider true', () async {
    final svc = await _makeSvc();
    svc.setProvider(_StubProvider());
    expect(svc.hasProvider, isTrue);
    expect(svc.provider, isNotNull);
  });

  test('clearProvider resets to null', () async {
    final svc = await _makeSvc()..setProvider(_StubProvider());
    svc.clearProvider();
    expect(svc.hasProvider, isFalse);
    expect(svc.provider, isNull);
  });

  test('setProvider notifies listeners', () async {
    final svc = await _makeSvc();
    int calls = 0;
    svc.addListener(() => calls++);
    svc.setProvider(_StubProvider());
    expect(calls, 1);
  });
}
