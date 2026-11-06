import 'package:flyterm/ssh/reconnect_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldSkipPeriodicSweep', () {
    test('三个集合都不含 → 不跳过', () {
      expect(
          ReconnectService.shouldSkipPeriodicSweep(
              reconnecting: false, retrying: false, proactiveResuming: false),
          isFalse);
    });

    test('廉价 RESUME 在飞 → 跳过（这正是修复的那一条）', () {
      expect(
          ReconnectService.shouldSkipPeriodicSweep(
              reconnecting: false, retrying: false, proactiveResuming: true),
          isTrue,
          reason: '否则 periodic sweep 会用 15~25s 的全量重连链抢跑廉价 RESUME');
    });

    test('重连中 / 重试中 各自都跳过', () {
      expect(
          ReconnectService.shouldSkipPeriodicSweep(
              reconnecting: true, retrying: false, proactiveResuming: false),
          isTrue);
      expect(
          ReconnectService.shouldSkipPeriodicSweep(
              reconnecting: false, retrying: true, proactiveResuming: false),
          isTrue);
    });
  });
}
