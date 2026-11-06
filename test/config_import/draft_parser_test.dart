import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/config_import/draft_parser.dart';

void main() {
  test('第 1 层命中 ssh config，不调用 LLM', () async {
    var llmCalled = false;
    final r = await parseConfigText(
      'Host web\n  HostName 10.0.0.5',
      llmComplete: (_) async {
        llmCalled = true;
        return '{}';
      },
    );
    expect(r.outcome, ParseOutcome.parsed);
    expect(r.servers.single.host, '10.0.0.5');
    expect(llmCalled, isFalse, reason: '第 1 层成功时绝不该烧钱调模型');
  });

  test('第 1 层命中 ssh 命令', () async {
    final r = await parseConfigText('ssh -p 2222 root@example.com');
    expect(r.outcome, ParseOutcome.parsed);
    expect(r.servers.single.host, 'example.com');
    expect(r.servers.single.port, 2222);
  });

  test('同一行命令同时产出服务器与转发草稿', () async {
    final r = await parseConfigText('ssh -L 13306:127.0.0.1:3306 root@db');
    expect(r.servers.single.host, 'db');
    expect(r.tunnel, isNotNull);
    expect(r.tunnel!.remotePort, 3306);
  });

  test('认不出且没有 LLM 时 outcome 为 needsLlm', () async {
    final r = await parseConfigText('服务器在 1.2.3.4 端口 2222');
    expect(r.outcome, ParseOutcome.needsLlm);
    expect(r.servers, isEmpty);
  });

  test('认不出但传了 LLM 时仍是 needsLlm —— 第 2 层不自动触发', () async {
    var llmCalled = false;
    final r = await parseConfigText(
      '服务器在 1.2.3.4 端口 2222',
      llmComplete: (_) async {
        llmCalled = true;
        return '{"host":"1.2.3.4"}';
      },
    );
    expect(r.outcome, ParseOutcome.needsLlm);
    expect(llmCalled, isFalse, reason: 'D3：必须等用户点按钮才调模型');
  });

  test('显式调用第 2 层才会用 LLM', () async {
    final r = await parseWithLlm(
      '服务器在 1.2.3.4 端口 2222',
      llmComplete: (_) async => '{"host":"1.2.3.4","port":2222,"username":"root"}',
    );
    expect(r.outcome, ParseOutcome.parsed);
    expect(r.servers.single.host, '1.2.3.4');
    expect(r.servers.single.port, 2222);
    expect(r.servers.single.provenance['host'], contains('AI'));
  });

  test('LLM 返回垃圾时重试一次，再失败则 failed', () async {
    var calls = 0;
    final r = await parseWithLlm(
      '随便什么',
      llmComplete: (_) async {
        calls++;
        return '不是 JSON';
      },
    );
    expect(calls, 2, reason: '应当重试一次');
    expect(r.outcome, ParseOutcome.failed);
  });

  test('LLM 第一次失败第二次成功', () async {
    var calls = 0;
    final r = await parseWithLlm(
      '随便什么',
      llmComplete: (_) async {
        calls++;
        return calls == 1 ? '坏的' : '{"host":"5.6.7.8"}';
      },
    );
    expect(r.outcome, ParseOutcome.parsed);
    expect(r.servers.single.host, '5.6.7.8');
  });

  test('LLM 返回合法 JSON 但没有 host —— 当失败处理', () async {
    final r = await parseWithLlm(
      '随便什么',
      llmComplete: (_) async => '{"username":"root","port":22}',
    );
    expect(r.outcome, ParseOutcome.failed);
  });

  test('私钥在进入任何解析之前被剥掉', () async {
    const input = '''
Host web
  HostName 10.0.0.5
-----BEGIN OPENSSH PRIVATE KEY-----
SECRETKEYMATERIAL
-----END OPENSSH PRIVATE KEY-----
''';
    String? sawPrompt;
    final r = await parseConfigText(input);
    expect(r.servers.single.host, '10.0.0.5');
    expect(r.strippedPrivateKey, isTrue);

    // 第 2 层也绝不能看到密钥内容。
    await parseWithLlm(input, llmComplete: (p) async {
      sawPrompt = p;
      return '{"host":"10.0.0.5"}';
    });
    expect(sawPrompt, isNot(contains('SECRETKEYMATERIAL')));
  });

  test('Include 指令被带到结果里', () async {
    final r = await parseConfigText('Include ~/.ssh/conf.d/*\nHost w\n  HostName 1.1.1.1');
    expect(r.sawInclude, isTrue);
  });
}
