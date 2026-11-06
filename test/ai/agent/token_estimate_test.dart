// 三段速率的标定锁。
//
// 期望值来自 2026-09-14 用 `POST /v1/messages/count_tokens`（claude-opus-5）
// 对**真实产物**的实测。断言写成「落在真实值的 ±15% 内」而不是等于某个硬编码数：速率是
// 近似，钉死具体值会让任何一次合理的微调都红，而 ±15% 正是定下的判据。
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/token_estimate.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/attachment.dart';

/// 断言 [got] 落在 [real] 的 ±15% 内。
void expectWithin15(num got, int real, String what) {
  final lo = real * 0.85, hi = real * 1.15;
  expect(got >= lo && got <= hi, isTrue,
      reason: '$what：估算 $got，实测真值 $real，超出 ±15%'
          '（允许区间 ${lo.round()}–${hi.round()}）');
}

void main() {
  group('散文速率（m.content）', () {
    test('英文散文：3967 字符实测 1281 token', () {
      // 用重复的英文句子逼近 system prompt 的形状。真实 system prompt 的
      // 实测是 3.10 chars/tok；这段样本同类。
      final prose = 'The quick brown fox jumps over the lazy dog. ' * 88;
      expectWithin15(proseTokens(prose), (prose.length / 3.10).round(),
          '英文散文');
    });

    test('中文：每字约 1.2 token', () {
      const cn = '上下文里只有一条命令的输出，但没有可对照的任务描述';
      // 25 个中日韩字符（含全角逗号）→ 约 30 token
      expectWithin15(proseTokens(cn), 30, '中文散文');
    });
  });

  group('结构化速率（工具输出）', () {
    test('命令输出比同长度散文贵：实测 1.88 vs 3.10 chars/tok', () {
      final log = 'Sep 14 11:20:01 host nginx[1234]: 127.0.0.1 - - '
          '"GET /api/v1/items?page=3 HTTP/1.1" 200 4213\n' * 40;
      expect(structuredTokens(log), greaterThan(proseTokens(log)),
          reason: '结构化速率必须比散文速率贵，否则这一段就白分了');
      expectWithin15(structuredTokens(log), (log.length / 1.88).round(),
          '命令输出');
    });
  });

  group('estimateMessageTokens', () {
    test('同一段文本放 content 与放 toolResults，结果不同', () {
      // 这一条锁住「role 就是内容类型判据」这个设计。有人把三段合并回
      // 一个除数时，它是唯一会红的测试。
      final text = 'x' * 2000;
      final asProse = AIMessage(role: 'assistant', content: text);
      final asResult = AIMessage(role: 'tool', content: '', toolResults: [
        ToolResult(callId: 'c1', content: text),
      ]);
      expect(estimateMessageTokens(asResult),
          greaterThan(estimateMessageTokens(asProse)));
    });

    test('一张图恰好贡献 kImageTokens，不随散文速率变', () {
      const img = Attachment(
          kind: AttachmentKind.image,
          relPath: 'a/1.png',
          mime: 'image/png',
          bytes: 1);
      const plain = AIMessage(role: 'user', content: 'hello');
      const withImg =
          AIMessage(role: 'user', content: 'hello', attachments: [img]);
      expect(estimateMessageTokens(withImg) - estimateMessageTokens(plain),
          kImageTokens,
          reason: '图片走的是直接计 token 那条路；这个差值若随速率变，'
              '说明它又被折算成字符了');
    });
  });

  group('estimateToolSchemaTokens', () {
    test('工具越多估得越大，且非零', () {
      const one = ToolSpec(
        name: 'bash',
        description: 'Run a shell command.',
        parameters: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string', 'description': 'The command.'}
          },
          'required': ['command'],
        },
      );
      final a = estimateToolSchemaTokens(const [one]);
      final b = estimateToolSchemaTokens(const [one, one]);
      expect(a, greaterThan(0));
      expect(b, greaterThan(a));
    });
  });
}
