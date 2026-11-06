import 'package:flyterm/ssh/session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => SessionTab.onTransportChanged = null);

  test('onTransportChanged 可注册、可清理', () {
    expect(SessionTab.onTransportChanged, isNull);
    SessionTab.onTransportChanged = (_, __) {};
    expect(SessionTab.onTransportChanged, isNotNull);
    SessionTab.onTransportChanged = null;
    expect(SessionTab.onTransportChanged, isNull);
  });
}
