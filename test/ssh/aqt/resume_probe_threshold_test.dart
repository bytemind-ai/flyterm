import 'package:flyterm/ssh/reconnect_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldProbeBeforeResume', () {
    test('不是从后台回来 → 探测', () {
      expect(ReconnectService.shouldProbeBeforeResume(null), isTrue);
    });

    test('后台不足 idle timeout → 探测（连接可能还活着）', () {
      expect(
          ReconnectService.shouldProbeBeforeResume(
              const Duration(seconds: 10)),
          isTrue);
      expect(
          ReconnectService.shouldProbeBeforeResume(
              const Duration(seconds: 89)),
          isTrue);
    });

    test('后台达到 idle timeout → 不探测（服务端必已关闭）', () {
      expect(
          ReconnectService.shouldProbeBeforeResume(
              const Duration(seconds: 90)),
          isFalse);
      expect(
          ReconnectService.shouldProbeBeforeResume(
              const Duration(minutes: 10)),
          isFalse);
    });

    test('30~90s 这一档要探测 —— 旧的 30s 硬编码阈值正是在这里误伤', () {
      expect(
          ReconnectService.shouldProbeBeforeResume(
              const Duration(seconds: 45)),
          isTrue);
    });
  });
}
