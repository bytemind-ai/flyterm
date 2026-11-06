import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

void main() {
  group('toolErrorForCard', () {
    test('代码 bug 类带栈 —— 否则 message 零信息量', () {
      // `Null check operator used on a null value` 不说哪个文件哪一行，
      // 栈是唯一能定位它的东西。2026-09-13 真机排查就卡在这里。
      late final StackTrace st;
      Object? caught;
      try {
        // ignore: null_check_always_fails
        (null as Object?)!;
      } catch (e, s) {
        caught = e;
        st = s;
      }
      expect(caught, isA<TypeError>());
      final text = toolErrorForCard(caught!, st);
      expect(text, contains('Null check operator'));
      expect(text.split('\n').length, greaterThan(1),
          reason: '必须带栈帧，不能只有一行 message');
    });

    test('正常的执行失败不带栈 —— 它的 message 本身就说明了问题', () {
      final text = toolErrorForCard(
          StateError('connection closed'), StackTrace.current);
      expect(text, 'Bad state: connection closed');
      expect(text.split('\n'), hasLength(1));
    });

    test('isCodeBugError 只认 TypeError 与 NoSuchMethodError', () {
      expect(isCodeBugError(StateError('x')), isFalse);
      expect(isCodeBugError(Exception('x')), isFalse);
      expect(isCodeBugError(TimeoutException0()), isFalse);
    });
  });
}

/// 一个普通异常，用来确认它不会被误判成代码 bug。
class TimeoutException0 implements Exception {}
