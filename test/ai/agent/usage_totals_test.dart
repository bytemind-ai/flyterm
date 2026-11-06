import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/agent/tool_models.dart' show AIResponse;
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ui/ai/agent_view.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/usage_totals.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import '_fakes.dart';

/// 跨会话 token 累计。
///
/// `AgentLoop.totalUsage` 是**单条会话**的累计，关掉面板就归零。用户真正
/// 想知道的是「我这个月在模型上用了多少」—— 那需要一份落到 prefs 的累计。
///
/// 按 **provider（含模型名）** 分桶，而不是全局一个数：三个模型各用掉多少
/// 是唯一能改变用户行为的维度（贵模型用得多还是便宜模型用得多）。全局总数
/// 看完只能「哦」一声。
void main() {
  const kA = 'OpenAI (gpt-4o)';
  const kB = 'Ollama (llama3)';

  Future<SharedPreferences> freshPrefs() async {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  test('初始为空 —— 没记录过任何用量', () async {
    final t = UsageTotals(await freshPrefs());
    expect(t.forProvider(kA), isNull);
    expect(t.providers, isEmpty);
  });

  test('累加一条用量', () async {
    final t = UsageTotals(await freshPrefs());

    await t.add(kA, const TokenUsage(
      inputTokens: 100,
      cachedTokens: 900,
      outputTokens: 30,
    ));

    final u = t.forProvider(kA)!;
    expect(u.inputTokens, equals(100));
    expect(u.cachedTokens, equals(900));
    expect(u.outputTokens, equals(30));
  });

  test('同一 provider 多次累加是相加，不是覆盖', () async {
    final t = UsageTotals(await freshPrefs());

    await t.add(kA, const TokenUsage(inputTokens: 100, outputTokens: 10));
    await t.add(kA, const TokenUsage(inputTokens: 50, outputTokens: 5));

    final u = t.forProvider(kA)!;
    expect(u.inputTokens, equals(150));
    expect(u.outputTokens, equals(15));
  });

  test('不同 provider 各记各的', () async {
    final t = UsageTotals(await freshPrefs());

    await t.add(kA, const TokenUsage(inputTokens: 100));
    await t.add(kB, const TokenUsage(inputTokens: 7));

    expect(t.forProvider(kA)!.inputTokens, equals(100));
    expect(t.forProvider(kB)!.inputTokens, equals(7));
    expect(t.providers, hasLength(2));
  });

  test('落盘 —— 换一个实例仍然读得到（这就是「跨会话」）', () async {
    final prefs = await freshPrefs();
    final t1 = UsageTotals(prefs);
    await t1.add(kA, const TokenUsage(inputTokens: 100, outputTokens: 10));

    // 模拟重启：同一份 prefs 上再造一个实例。
    final t2 = UsageTotals(prefs);
    expect(t2.forProvider(kA)!.inputTokens, equals(100),
        reason: '没落盘的话这里会是 0 —— 跨会话累计就无从谈起');
    expect(t2.forProvider(kA)!.outputTokens, equals(10));
  });

  test('空用量不入账 —— 不制造一个全 0 的桶', () async {
    final t = UsageTotals(await freshPrefs());

    await t.add(kA, const TokenUsage());

    expect(t.forProvider(kA), isNull,
        reason: '服务端不给 usage 时不该凭空多出一个 provider 条目');
    expect(t.providers, isEmpty);
  });

  test('prefs 里的值损坏时不崩，按空处理', () async {
    SharedPreferences.setMockInitialValues({
      'ai_usage_totals_v1': 'this is not json',
    });
    final prefs = await SharedPreferences.getInstance();

    final t = UsageTotals(prefs);
    expect(t.providers, isEmpty);

    // 而且仍然可写 —— 损坏不该把功能整个锁死。
    await t.add(kA, const TokenUsage(inputTokens: 5));
    expect(t.forProvider(kA)!.inputTokens, equals(5));
  });

  test('总累计是所有 provider 相加', () async {
    final t = UsageTotals(await freshPrefs());

    await t.add(kA, const TokenUsage(
        inputTokens: 100, cachedTokens: 200, outputTokens: 10));
    await t.add(kB, const TokenUsage(
        inputTokens: 7, cachedTokens: 3, outputTokens: 1));

    final total = t.total;
    expect(total.inputTokens, equals(107));
    expect(total.cachedTokens, equals(203));
    expect(total.outputTokens, equals(11));
  });

  group('与 AgentLoop 接线', () {
    test('一轮响应之后累计被记账，且按 provider 名分桶', () async {
      final prefs = await freshPrefs();
      final totals = UsageTotals(prefs);
      final loop = makeLoop(
        provider: FakeProvider([
          const AIResponse(
            text: 'done',
            usage: TokenUsage(inputTokens: 100, cachedTokens: 20, outputTokens: 5),
          ),
        ]),
        usageTotals: totals,
      );

      await loop.send('hi');
      // add 是 fire-and-forget，放掉它。
      await pumpEventQueue();

      final u = totals.forProvider(loop.providerProvider().displayName);
      expect(u, isNotNull, reason: '没记账 —— 跨会话累计无从谈起');
      expect(u!.inputTokens, equals(100));
      expect(u.outputTokens, equals(5));
    });

    test('loop 上的 cumulativeUsage 快照带上历史累计（不是从 0 开始）',
        () async {
      final prefs = await freshPrefs();
      final totals = UsageTotals(prefs);
      // 先假装「上一个会话」用过一些。
      await totals.add('Fake (m)', const TokenUsage(inputTokens: 900));

      final loop = makeLoop(
        provider: FakeProvider([const AIResponse(text: 'x')]),
        usageTotals: totals,
      );

      expect(loop.cumulativeUsage.inputTokens, equals(900),
          reason: '一开面板显示「累计 0」而实际用过几十万，比不显示更误导');
    });

    test('没注入 usageTotals 时一切照旧 —— 不崩、快照为空', () async {
      final loop = makeLoop(
        provider: FakeProvider([const AIResponse(text: 'x')]),
      );

      await loop.send('hi');

      expect(loop.cumulativeUsage.isEmpty, isTrue);
    });
  });

  group('页脚显示', () {
    // 走真实的 `AgentView`，不暴露 `_UsageFooter`（私有）。这也是它实际的
    // 渲染路径 —— 顺带锁住「快照真的传到了 footer」这一段接线。
    Widget wrap(AgentLoop loop) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChangeNotifierProvider<VoiceInputService>(
            create: (_) => _FakeVoiceInputService(),
            child: Scaffold(body: AgentView(loop: loop, providerName: 'fake')),
          ),
        );

    testWidgets('累计非空时页脚追加「累计 X」', (tester) async {
      final prefs = await freshPrefs();
      final totals = UsageTotals(prefs);
      await totals.add('Fake (m)',
          const TokenUsage(inputTokens: 50000, outputTokens: 3000));

      final loop = makeLoop(
        provider: FakeProvider([
          const AIResponse(
            text: 'done',
            usage: TokenUsage(inputTokens: 1000, outputTokens: 200),
          ),
        ]),
        usageTotals: totals,
      );

      await tester.pumpWidget(wrap(loop));
      await tester.runAsync(() => loop.send('hi'));
      await tester.pumpAndSettle();

      // 断言英文串而不是中文：测试环境的默认 locale 是 en，
      // `agentUsageCumulative` 的英文是「{session} · total {total}」。
      // 写「累计」会永远找不到 —— 那不是 bug，是把断言绑到了错误的语言上
      // （这条是靠打印渲染结果才发现的）。
      expect(find.textContaining('total 54.2k'), findsOneWidget,
          reason: '累计有值却不显示 = 做了没人看得见');
    });

    testWidgets('没注入累计时页脚不出现那一截', (tester) async {
      final loop = makeLoop(
        provider: FakeProvider([
          const AIResponse(
            text: 'done',
            usage: TokenUsage(inputTokens: 1000, outputTokens: 200),
          ),
        ]),
      );

      await tester.pumpWidget(wrap(loop));
      await tester.runAsync(() => loop.send('hi'));
      await tester.pumpAndSettle();

      expect(find.textContaining('total '), findsNothing);
    });
  });
}

class _FakeVoiceInputService extends VoiceInputService {
  @override
  bool get isAvailable => false;
  @override
  bool get isListening => false;
  @override
  Future<bool> prepare() async => false;
  @override
  Future<void> startListening({
    required void Function(String) onResult,
    void Function(VoiceInputIssue issue)? onFailure,
  }) async {}
  @override
  Future<void> cancelListening() async {}
}
