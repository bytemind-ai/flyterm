import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

void main() {
  test('相加逐字段累计', () {
    const a = TokenUsage(inputTokens: 10, cachedTokens: 5, outputTokens: 2);
    const b = TokenUsage(inputTokens: 1, cachedTokens: 2, outputTokens: 3);
    final s = a + b;
    expect(s.inputTokens, equals(11));
    expect(s.cachedTokens, equals(7));
    expect(s.outputTokens, equals(5));
  });

  test('全零视为 isEmpty', () {
    expect(const TokenUsage().isEmpty, isTrue);
    expect(const TokenUsage(cachedTokens: 1).isEmpty, isFalse);
    expect(const TokenUsage(inputTokens: 1).isEmpty, isFalse);
    expect(const TokenUsage(outputTokens: 1).isEmpty, isFalse);
  });

  test('totalInput 是全价加缓存命中', () {
    const u = TokenUsage(inputTokens: 100, cachedTokens: 900);
    expect(u.totalInput, equals(1000));
  });

  group('asTokenCount：容错转换，任何取不到的情形都返回 0，绝不抛', () {
    test('int 原样转换', () {
      expect(asTokenCount(42), equals(42));
    });

    test('double 截断，不四舍五入', () {
      expect(asTokenCount(44.9), equals(44));
    });

    test('数字字符串解析成 int（第三方代理常把数字序列化成字符串）', () {
      expect(asTokenCount('812'), equals(812));
    });

    test('浮点字符串先按浮点解析再截断', () {
      expect(asTokenCount('812.0'), equals(812));
    });

    test('非数字字符串按 0 处理，不抛', () {
      expect(asTokenCount('abc'), equals(0));
    });

    test('null 按 0 处理', () {
      expect(asTokenCount(null), equals(0));
    });

    test('bool 按 0 处理，不抛', () {
      expect(asTokenCount(true), equals(0));
    });

    test('Map 按 0 处理，不抛', () {
      expect(asTokenCount(<String, dynamic>{'a': 1}), equals(0));
    });

    test('List 按 0 处理，不抛', () {
      expect(asTokenCount(<int>[1, 2, 3]), equals(0));
    });

    test('空字符串按 0 处理', () {
      expect(asTokenCount(''), equals(0));
    });
  });
}
