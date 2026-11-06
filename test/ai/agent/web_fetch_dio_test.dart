import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/web_fetch.dart';

/// 一个受控的 adapter：按请求 URL 返回预先排好的响应，不碰真网络。
class _FakeAdapter implements HttpClientAdapter {
  final List<ResponseBody> _queue;
  final List<String> requested = [];
  _FakeAdapter(this._queue);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requested.add(options.uri.toString());
    if (_queue.isEmpty) throw StateError('fake adapter ran out of responses');
    return _queue.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _body(String text,
        {int code = 200,
        String contentType = 'text/plain',
        Map<String, List<String>>? extra}) =>
    ResponseBody.fromBytes(
      utf8.encode(text),
      code,
      headers: {
        Headers.contentTypeHeader: [contentType],
        ...?extra,
      },
    );

ResponseBody _redirect(String location) => ResponseBody.fromBytes(
      const [],
      302,
      headers: {
        'location': [location],
      },
    );

Dio _dioWith(_FakeAdapter a) {
  final d = Dio(BaseOptions(
    followRedirects: false,
    validateStatus: (_) => true,
    responseType: ResponseType.stream,
  ));
  d.httpClientAdapter = a;
  return d;
}

void main() {
  test('正常取回，带 content-type', () async {
    final a = _FakeAdapter([_body('hello', contentType: 'text/plain')]);
    final f = DioWebFetcher(dio: _dioWith(a));
    final r = await f.get('https://example.com/a');
    expect(utf8.decode(r.bytes), 'hello');
    expect(r.contentType, contains('text/plain'));
    expect(r.statusCode, 200);
  });

  test('跟随重定向到公网地址', () async {
    final a = _FakeAdapter([
      _redirect('https://example.com/final'),
      _body('landed'),
    ]);
    final f = DioWebFetcher(dio: _dioWith(a));
    final r = await f.get('https://example.com/start');
    expect(utf8.decode(r.bytes), 'landed');
    expect(a.requested.last, 'https://example.com/final');
  });

  test('重定向到私有地址被拦 —— 借手机打内网设备', () async {
    // 公网页面 302 到 192.168.1.1/admin 就能借用户的手机去打
    // 家里的路由器。这是本设计新引入的 SSRF 面，必须逐跳校验。
    final a = _FakeAdapter([_redirect('http://192.168.1.1/admin')]);
    final f = DioWebFetcher(dio: _dioWith(a));
    await expectLater(
      f.get('https://evil.example.com/'),
      throwsA(isA<PhoneFetchException>()
          .having((e) => e.kind, 'kind', PhoneFetchFailure.redirectBlocked)
          .having((e) => e.message, 'message', contains('192.168.1.1'))),
    );
    // 被拦的那一跳**没有**发出去
    expect(a.requested, ['https://evil.example.com/']);
  });

  test('初始 URL 是私有地址时不拦 —— 那是显式意图', () async {
    // 同一条决策的另一半：`via: 'phone'` + 内网地址是用户/模型的显式选择
    // （也让「手机取家里 NAS」能用），重定向才是被第三方诱导。
    final a = _FakeAdapter([_body('{"status":"ok"}')]);
    final f = DioWebFetcher(dio: _dioWith(a));
    final r = await f.get('http://192.168.1.10:8080/health');
    expect(utf8.decode(r.bytes), contains('ok'));
  });

  test('重定向超过上限报错', () async {
    final a = _FakeAdapter([
      _redirect('https://example.com/1'),
      _redirect('https://example.com/2'),
      _redirect('https://example.com/3'),
      _redirect('https://example.com/4'),
      _redirect('https://example.com/5'),
    ]);
    final f = DioWebFetcher(dio: _dioWith(a));
    await expectLater(
      f.get('https://example.com/0'),
      throwsA(isA<PhoneFetchException>()),
    );
  });

  test('重定向没有 location 头', () async {
    final a = _FakeAdapter([ResponseBody.fromBytes(const [], 302)]);
    final f = DioWebFetcher(dio: _dioWith(a));
    await expectLater(
        f.get('https://example.com/'), throwsA(isA<PhoneFetchException>()));
  });

  test('content-length 超上限直接放弃，不读 body', () async {
    final a = _FakeAdapter([
      _body('x', extra: {
        Headers.contentLengthHeader: ['99999999'],
      }),
    ]);
    final f = DioWebFetcher(dio: _dioWith(a));
    await expectLater(
      f.get('https://example.com/big'),
      throwsA(isA<PhoneFetchException>()
          .having((e) => e.kind, 'kind', PhoneFetchFailure.tooLarge)),
    );
  });

  test('不声明 content-length 但流超上限，读到一半中断', () async {
    // 分块传输（chunked）没有 content-length，只能边读边数。
    final big = 'y' * (3 * 1024 * 1024);
    final a = _FakeAdapter([_body(big)]);
    final f = DioWebFetcher(dio: _dioWith(a));
    await expectLater(
      f.get('https://example.com/chunked'),
      throwsA(isA<PhoneFetchException>()
          .having((e) => e.kind, 'kind', PhoneFetchFailure.tooLarge)),
    );
  });

  test('连接层失败归成 connection 一档 —— 只有它触发回退', () async {
    final d = Dio(BaseOptions(followRedirects: false));
    d.httpClientAdapter = _ThrowingAdapter();
    final f = DioWebFetcher(dio: d);
    await expectLater(
      f.get('https://unreachable.example.com/'),
      throwsA(isA<PhoneFetchException>()
          .having((e) => e.kind, 'kind', PhoneFetchFailure.connection)),
    );
  });
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'no route to host',
      );

  @override
  void close({bool force = false}) {}
}
