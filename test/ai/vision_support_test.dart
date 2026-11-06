import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_provider.dart';

/// 只为验证翻转规则的最小实现。
class _P extends AIProvider {
  @override
  String get displayName => 'p';
  @override
  String get providerType => 'p';
  @override
  Future<String> complete(List messages) async => '';
}

void main() {
  group('翻转是可逆的 —— 判定会误判，必须有逃生口', () {
    test('resetVisionSupport 把 false 翻回 true', () {
      final p = _P();
      p.noteVisionFailure(DioException(
        requestOptions: RequestOptions(),
        response: Response(requestOptions: RequestOptions(), statusCode: 400),
      ));
      expect(p.supportsVision, isFalse);

      p.resetVisionSupport();
      expect(p.supportsVision, isTrue,
          reason: '一张损坏的图或一次超大请求体也会返回 400，误判之后'
              '用户会在这个 provider 实例上永久失去附件能力');
    });

    test('重置之后仍然会被下一次真实失败翻回去', () {
      // 逃生口不能变成「永久开着」：真不支持视觉的模型，下一次带图请求
      // 照样把它翻回 false，代价只是多一次失败的流量。
      final p = _P()..resetVisionSupport();
      p.noteVisionFailure(DioException(
        requestOptions: RequestOptions(),
        response: Response(requestOptions: RequestOptions(), statusCode: 415),
      ));
      expect(p.supportsVision, isFalse);
    });
  });

  group('supportsVision 的翻转规则', () {
    test('初值乐观为 true', () {
      expect(_P().supportsVision, isTrue);
    });

    test('400 → 翻转成 false', () {
      final p = _P();
      p.noteVisionFailure(DioException(
        requestOptions: RequestOptions(),
        response: Response(requestOptions: RequestOptions(), statusCode: 400),
      ));
      expect(p.supportsVision, isFalse);
    });

    test('415 / 422 同样翻转', () {
      for (final code in [415, 422]) {
        final p = _P();
        p.noteVisionFailure(DioException(
          requestOptions: RequestOptions(),
          response:
              Response(requestOptions: RequestOptions(), statusCode: code),
        ));
        expect(p.supportsVision, isFalse, reason: '$code 应翻转');
      }
    });

    test('超时不翻转 —— 图片请求大，移动网络下超时是常态', () {
      final p = _P();
      p.noteVisionFailure(DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.connectionTimeout,
      ));
      expect(p.supportsVision, isTrue,
          reason: '把超时当成「不支持」会让附件按钮莫名变灰');
    });

    test('5xx 不翻转 —— 那是服务端的问题，不是能力问题', () {
      final p = _P();
      p.noteVisionFailure(DioException(
        requestOptions: RequestOptions(),
        response: Response(requestOptions: RequestOptions(), statusCode: 503),
      ));
      expect(p.supportsVision, isTrue);
    });

    test('context 超限也是 400，但不能翻转 —— 那是历史太长不是不支持', () {
      // 不排除的话：用户用着支持视觉的模型，一次上下文超限就让附件按钮
      // 永久变灰，而真实原因只是这段会话太长了。
      for (final body in [
        {'error': {'message': 'This model\'s maximum context length is 8192 tokens'}},
        {'error': {'message': 'prompt is too long: 250000 tokens > 200000'}},
        {'error': {'type': 'invalid_request_error', 'message': 'input length exceeds context window'}},
      ]) {
        final p = _P();
        p.noteVisionFailure(DioException(
          requestOptions: RequestOptions(),
          response: Response(
              requestOptions: RequestOptions(), statusCode: 400, data: body),
        ));
        expect(p.supportsVision, isTrue, reason: 'body=$body');
      }
    });

    test('isContextOverflow 能认出这三种措辞', () {
      expect(
          isContextOverflow({
            'error': {'message': 'maximum context length is 8192'}
          }),
          isTrue);
      expect(
          isContextOverflow({
            'error': {'message': 'prompt is too long'}
          }),
          isTrue);
      expect(
          isContextOverflow({
            'error': {'message': 'we do not support image input'}
          }),
          isFalse,
          reason: '这条是真的不支持图片，必须翻转');
    });
  });
}
