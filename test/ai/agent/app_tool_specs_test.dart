import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_groups.dart';

void main() {
  group('app 工具声明', () {
    test('hasAppControl=false 时不声明任何 app 工具', () {
      final specs =
          agentToolSpecsFor(AgentToolTier.full, hasAppControl: false);
      final names = specs.map((s) => s.name).toSet();
      expect(names, isNot(contains('app_state_read')));
      expect(names, isNot(contains('app_settings_set')));
    });

    test('hasAppControl=true 时 app_state_read 常驻', () {
      final specs = agentToolSpecsFor(AgentToolTier.full, hasAppControl: true);
      final names = specs.map((s) => s.name).toSet();
      expect(names, contains('app_state_read'));
    });

    test('app_settings_set 属于 app_config 组，默认不常驻', () {
      expect(groupOf('app_settings_set'), equals('app_config'));
      final specs = agentToolSpecsFor(AgentToolTier.full, hasAppControl: true);
      final unlocked = filterByUnlockedGroups(specs, {});
      expect(unlocked.map((s) => s.name), isNot(contains('app_settings_set')));
    });

    test('解锁 app_config 后 app_settings_set 可见', () {
      final specs = agentToolSpecsFor(AgentToolTier.full, hasAppControl: true);
      final unlocked = filterByUnlockedGroups(specs, {'app_config'});
      expect(unlocked.map((s) => s.name), contains('app_settings_set'));
    });

    test('app_state_read 的 section 参数枚举了全部分区', () {
      final spec = agentToolSpecsFor(AgentToolTier.full, hasAppControl: true)
          .firstWhere((s) => s.name == 'app_state_read');
      final section =
          (spec.parameters['properties'] as Map)['section'] as Map;
      expect(section['enum'], containsAll(['settings', 'servers', 'sessions']));
    });

    // 全局 AI（requireExplicitServer=true）会把所有 spec 过一遍
    // _withRequiredServer。app 工具不绑服务器，不该被塞进一个必填 server。
    test('全局 AI 下 app 工具不被加上必填 server 参数', () {
      final specs = agentToolSpecsFor(
        AgentToolTier.full,
        hasAppControl: true,
        requireExplicitServer: true,
      );
      final names = specs.map((s) => s.name).toSet();
      expect(names, contains('app_state_read'),
          reason: 'app 工具在全局 AI 里被整个滤掉了');

      final spec = specs.firstWhere((s) => s.name == 'app_state_read');
      final props = spec.parameters['properties'] as Map;
      expect(props.containsKey('server'), isFalse,
          reason: 'app 工具被塞了一个它不认识的 server 参数');
    });
  });
}
