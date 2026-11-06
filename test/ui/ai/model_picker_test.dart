import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/models/ai_provider_config.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/model_picker_sheet.dart';

AIProviderConfig cfg(String type, {String id = 'p1'}) => AIProviderConfig(
      id: id, name: type, type: type, model: 'm',
    );

void main() {
  group('modelDisabledReason', () {
    test('anthropic / openai 有 key 时可选', () {
      expect(modelDisabledReason(cfg('anthropic'), hasKey: true, currentToolsSupported: null), isNull);
      expect(modelDisabledReason(cfg('openai'), hasKey: true, currentToolsSupported: null), isNull);
    });

    test('缺 key 的非 ollama 置灰', () {
      expect(modelDisabledReason(cfg('anthropic'), hasKey: false, currentToolsSupported: null),
          ModelDisabledReason.noApiKey);
    });

    test('ollama 不需要 key，默认可选（乐观假设）', () {
      expect(modelDisabledReason(cfg('ollama'), hasKey: false, currentToolsSupported: null), isNull);
    });

    test('当前这条 ollama 已被翻转成不支持时才置灰', () {
      expect(modelDisabledReason(cfg('ollama'), hasKey: false, currentToolsSupported: false),
          ModelDisabledReason.noToolSupport);
    });

    test('未知 type 置灰', () {
      expect(modelDisabledReason(cfg('unknown-provider'), hasKey: true, currentToolsSupported: null),
          ModelDisabledReason.noToolSupport);
    });

    test('gemini 有 key 时可选（它继承 OpenAIProvider，工具全支持）', () {
      expect(modelDisabledReason(cfg('gemini'), hasKey: true, currentToolsSupported: null),
          isNull);
    });

    test('gemini 没填 key 时提示缺 key，而不是「不支持工具」', () {
      expect(modelDisabledReason(cfg('gemini'), hasKey: false, currentToolsSupported: null),
          ModelDisabledReason.noApiKey);
    });
  });

  // 切到 ollama 会静默降到 lean 档 —— 只剩 bash / read_file / read_terminal，
  // 上传下载写文件全没了。用户不会知道，直到他让 agent 传个文件、agent 用
  // 自然语言接话（「好的，请选择要上传的文件」），看上去像选择器坏了。
  // 档位差异必须在切之前就摆出来。
  testWidgets('lean 档的条目标出「不能传文件」', (tester) async {
    final l = lookupAppLocalizations(const Locale('zh'));
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ModelPickerSheet(
          choices: [
            ModelChoice(
              config: cfg('ollama', id: 'o'),
              isCurrent: false,
              disabled: null,
              leanTools: true,
            ),
            ModelChoice(
              config: cfg('anthropic', id: 'a'),
              isCurrent: true,
              disabled: null,
              leanTools: false,
            ),
          ],
          onPick: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining(l.aiModelLeanTools), findsOneWidget,
        reason: 'lean 档要标出来，且只标那一条');
  });

  testWidgets('置灰项不可点，当前项打勾', (tester) async {
    AIProviderConfig? picked;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ModelPickerSheet(
          choices: [
            ModelChoice(config: cfg('anthropic', id: 'a'), isCurrent: true, disabled: null),
            ModelChoice(config: cfg('openai', id: 'b'), isCurrent: false,
                disabled: ModelDisabledReason.noApiKey),
          ],
          onPick: (c) => picked = c,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('openai'));
    await tester.pumpAndSettle();
    expect(picked, isNull, reason: '置灰项点了不该有反应');
  });
}
