import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/config_import/llm_draft_parser.dart';

void main() {
  test('解析规整 JSON', () async {
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async =>
          '{"name":"web","host":"1.2.3.4","port":2222,"username":"root"}',
    );
    expect(d!.host, '1.2.3.4');
    expect(d.port, 2222);
    expect(d.username, 'root');
    expect(d.name, 'web');
  });

  test('容忍 ```json 代码围栏', () async {
    // 模型很爱加围栏，不容忍它等于平白浪费一次重试。
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => '```json\n{"host":"1.2.3.4"}\n```',
    );
    expect(d!.host, '1.2.3.4');
  });

  test('容忍 JSON 前后的解释性文字', () async {
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => '好的，解析结果如下：\n{"host":"1.2.3.4"}\n希望有帮助',
    );
    expect(d!.host, '1.2.3.4');
  });

  test('port 是字符串时也接受', () async {
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => '{"host":"1.2.3.4","port":"2222"}',
    );
    expect(d!.port, 2222);
  });

  test('port 非法时丢字段但保留 draft', () async {
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => '{"host":"1.2.3.4","port":"不知道"}',
    );
    expect(d!.host, '1.2.3.4');
    expect(d.port, isNull);
  });

  test('没有 host 时返回 null', () async {
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => '{"username":"root"}',
    );
    expect(d, isNull);
  });

  test('重试一次后放弃', () async {
    var calls = 0;
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async {
        calls++;
        return '彻底不是 JSON';
      },
    );
    expect(calls, 2);
    expect(d, isNull);
  });

  test('complete 抛异常时不冒泡，当失败处理', () async {
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => throw Exception('网络断了'),
    );
    expect(d, isNull);
  });

  test('provenance 标明来自 AI', () async {
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => '{"host":"1.2.3.4","port":2222}',
    );
    expect(d!.provenance['host'], contains('AI'));
    expect(d.provenance['port'], contains('AI'));
  });

  test('prompt 里包含待解析文本', () async {
    String? seen;
    await llmParseServerDraft(
      '服务器在 1.2.3.4',
      complete: (p) async {
        seen = p;
        return '{"host":"1.2.3.4"}';
      },
    );
    expect(seen, contains('服务器在 1.2.3.4'));
  });

  test('JSON 后面跟着含花括号的解释', () async {
    // 贪婪正则会把两个对象之间的说明文字一起吞进来，导致 jsonDecode 失败。
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => '{"host":"1.2.3.4"} 比如 {"example":"x"} 这样',
    );
    expect(d!.host, '1.2.3.4');
  });

  test('JSON 数组包裹', () async {
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => '[{"host":"1.2.3.4"}]',
    );
    expect(d!.host, '1.2.3.4');
  });

  test('值里含花括号', () async {
    // 守的是「字符串内部的 } 不能被当成对象结尾」。
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => '{"host":"1.2.3.4","name":"a}b"}',
    );
    expect(d!.host, '1.2.3.4');
    expect(d.name, 'a}b');
  });

  test('值里含转义引号', () async {
    final d = await llmParseServerDraft(
      '随便',
      complete: (_) async => '{"host":"1.2.3.4","name":"a\\"b"}',
    );
    expect(d!.host, '1.2.3.4');
  });
}
