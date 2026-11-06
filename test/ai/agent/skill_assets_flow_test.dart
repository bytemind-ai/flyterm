import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// `load_skill` 返回附件清单、`save_skill` 落盘附件。
void main() {
  List<ToolSpec> full() =>
      agentToolSpecsFor(AgentToolTier.full, hasSkills: true);

  ToolCall loadCall(String name) =>
      ToolCall(id: 'c1', name: 'load_skill', args: {'name': name});

  group('load_skill 附件清单', () {
    test('无附件时返回值与改造前逐字节相同', () async {
      final loop = makeLoop(
        toolSpecs: full,
        skillNamesProvider: () => const ['nginx'],
        skillBodyProvider: (n, {alsoAllow = const {}}) async => 'BODY',
        skillAssetProvider: (n, {alsoAllow = const {}}) async => const [],
        provider: FakeProvider([
          AIResponse(toolCalls: [loadCall('nginx')]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      final ev = loop.events.whereType<ToolCallEvent>().first;
      expect(ev.output, equals('[skill: nginx]\nBODY'),
          reason: '没有附件的技能（绝大多数）必须保持原样');
    });

    test('有附件时追加清单段，含路径与可执行标记', () async {
      final loop = makeLoop(
        toolSpecs: full,
        skillNamesProvider: () => const ['nginx'],
        skillBodyProvider: (n, {alsoAllow = const {}}) async => 'BODY',
        skillAssetProvider: (n, {alsoAllow = const {}}) async => const [
          AgentSkillAsset(
              path: 'scripts/check.sh', content: 'X', executable: true),
          AgentSkillAsset(path: 'templates/nginx.conf', content: 'Y'),
        ],
        provider: FakeProvider([
          AIResponse(toolCalls: [loadCall('nginx')]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      final ev = loop.events.whereType<ToolCallEvent>().first;
      expect(ev.output, contains('[skill: nginx]\nBODY'));
      expect(ev.output, contains('scripts/check.sh'));
      expect(ev.output, contains('templates/nginx.conf'));
      expect(ev.output, contains('install_skill_assets'));
      // 可执行标记必须出现，否则模型不知道 chmod 会发生在哪个文件上。
      expect(ev.output, contains('(executable)'));
      // 附件正文**绝不能**进返回值 —— 它每轮都在历史里。
      expect(ev.output, isNot(contains('X')));
    });

    test('加载失败时不尝试读附件', () async {
      var assetCalls = 0;
      final loop = makeLoop(
        toolSpecs: full,
        skillNamesProvider: () => const [],
        skillBodyProvider: (n, {alsoAllow = const {}}) async => null,
        skillAssetProvider: (n, {alsoAllow = const {}}) async {
          assetCalls++;
          return const [];
        },
        provider: FakeProvider([
          AIResponse(toolCalls: [loadCall('nope')]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      expect(assetCalls, equals(0));
    });
  });

  group('save_skill 附件', () {
    test('assets 参数落盘', () async {
      List<AgentSkillAsset>? saved;
      final loop = makeLoop(
        mode: PermissionMode.bypass,
        toolSpecs: full,
        skillNamesProvider: () => const [],
        skillSaver: (n, d, b, a) async => saved = a,
        provider: FakeProvider([
          AIResponse(toolCalls: [
            ToolCall(id: 'c1', name: 'save_skill', args: {
              'name': 'nginx',
              'description': 'd',
              'body': 'b',
              'assets': [
                {'path': 'scripts/x.sh', 'content': 'echo hi',
                 'executable': true},
                {'path': 't.conf', 'content': 'z'},
              ],
            })
          ]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      expect(saved, hasLength(2));
      expect(saved![0].path, equals('scripts/x.sh'));
      expect(saved![0].executable, isTrue);
      expect(saved![1].path, equals('t.conf'));
      expect(saved![1].executable, isFalse);
    });

    test('不传 assets 时回调收到 null（保持原语义）', () async {
      var called = false;
      List<AgentSkillAsset>? saved = const [];
      final loop = makeLoop(
        mode: PermissionMode.bypass,
        toolSpecs: full,
        skillNamesProvider: () => const [],
        skillSaver: (n, d, b, a) async {
          called = true;
          saved = a;
        },
        provider: FakeProvider([
          AIResponse(toolCalls: [
            ToolCall(id: 'c1', name: 'save_skill', args: {
              'name': 'nginx', 'description': 'd', 'body': 'b',
            })
          ]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      expect(called, isTrue);
      expect(saved, isNull);
    });

    test('危险 path 被拒，不落库', () async {
      var called = false;
      final loop = makeLoop(
        toolSpecs: full,
        skillNamesProvider: () => const [],
        skillSaver: (n, d, b, a) async => called = true,
        provider: FakeProvider([
          AIResponse(toolCalls: [
            ToolCall(id: 'c1', name: 'save_skill', args: {
              'name': 'evil',
              'description': 'd',
              'body': 'b',
              'assets': [
                {'path': '../../.ssh/authorized_keys', 'content': 'k'},
              ],
            })
          ]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      final ev = loop.events.whereType<ToolCallEvent>().first;
      expect(ev.status, equals(ToolCallStatus.failed));
      expect(ev.output, contains('path'));
      expect(called, isFalse);
    });

    test('单附件超 4 KiB 被拒', () async {
      final loop = makeLoop(
        toolSpecs: full,
        skillNamesProvider: () => const [],
        skillSaver: (n, d, b, a) async {},
        provider: FakeProvider([
          AIResponse(toolCalls: [
            ToolCall(id: 'c1', name: 'save_skill', args: {
              'name': 'x', 'description': 'd', 'body': 'b',
              'assets': [
                {'path': 'big.sh', 'content': 'a' * 4097},
              ],
            })
          ]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      final ev = loop.events.whereType<ToolCallEvent>().first;
      expect(ev.status, equals(ToolCallStatus.failed));
      expect(ev.output, contains('4096'));
    });

    test('附件数超 8 个被拒', () async {
      final loop = makeLoop(
        toolSpecs: full,
        skillNamesProvider: () => const [],
        skillSaver: (n, d, b, a) async {},
        provider: FakeProvider([
          AIResponse(toolCalls: [
            ToolCall(id: 'c1', name: 'save_skill', args: {
              'name': 'x', 'description': 'd', 'body': 'b',
              'assets': [
                for (var i = 0; i < 9; i++)
                  {'path': 'f$i.sh', 'content': 'z'},
              ],
            })
          ]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      final ev = loop.events.whereType<ToolCallEvent>().first;
      expect(ev.status, equals(ToolCallStatus.failed));
      expect(ev.output, contains('8'));
    });
  });
}
