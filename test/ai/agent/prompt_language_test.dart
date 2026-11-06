import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/l10n/app_localizations.dart';

void main() {
  String p({String? tag, String? name}) => buildAgentSystemPrompt(
        activeToolNames: const {'bash'},
        tier: AgentToolTier.full,
        languageTag: tag,
        languageName: name,
        cwd: null,
        terminalContext: null,
      );

  group('语言指令 —— 名字来自 l10n，不在 prompt 层硬编码', () {
    test('给了 languageName 就直接用它', () {
      expect(p(tag: 'zh-CN', name: '简体中文'), contains('简体中文'));
    });

    // 这条是本次改动的要点：prompt 层不认识任何具体语言。
    test('prompt 层不含任何语言映射表 —— 加新语言不用改这里', () {
      // 传一个 l10n 里根本没有的语言，照样原样用
      final out = p(tag: 'ja-JP', name: '日本語');
      expect(out, contains('日本語'));
    });

    test('languageName 优先于 languageTag', () {
      final out = p(tag: 'en-US', name: '简体中文');
      expect(out, contains('简体中文'));
      expect(out, isNot(contains('IETF tag')));
    });

    test('只有 tag 时回落到 IETF 写法', () {
      expect(p(tag: 'fi-FI'), contains('IETF tag "fi-FI"'));
    });

    test('都没有时让模型跟随用户', () {
      expect(p(), contains('the same language the user writes in'));
    });

    test('空字符串当作没给', () {
      expect(p(tag: 'zh-CN', name: ''), contains('IETF tag "zh-CN"'));
    });

    // 真机回归：摇摆发生在工具调用之间那句话上，旧措辞只列举了
    // final answer 与 description field 两类。
    test('约束明确覆盖「工具调用之间说的话」', () {
      final out = p(name: '简体中文');
      expect(out, contains('between'));
      expect(out, contains('tool calls'));
    });
  });

  group('每份 l10n 都要自带语言自称', () {
    // 新增一份 arb 却忘了填 promptLanguageName，后果是 AI 的语言锚点
    // 静默退回 IETF tag —— 不会报错，只会表现成「有时说英文」。
    test('zh / en 都有非空的 promptLanguageName 且互不相同', () async {
      final zh = await AppLocalizations.delegate.load(const Locale('zh'));
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      expect(zh.promptLanguageName.trim(), isNotEmpty);
      expect(en.promptLanguageName.trim(), isNotEmpty);
      expect(zh.promptLanguageName, isNot(en.promptLanguageName),
          reason: '两份 arb 填了同一个名字，等于其中一份忘了改');
    });

    test('supportedLocales 里每一个都能取到语言自称', () async {
      for (final loc in AppLocalizations.supportedLocales) {
        final l = await AppLocalizations.delegate.load(loc);
        expect(l.promptLanguageName.trim(), isNotEmpty,
            reason: '$loc 的 arb 缺 promptLanguageName');
      }
    });
  });
}
