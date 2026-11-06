import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AgentSessionManager> mgrWith(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    return AgentSessionManager(await SharedPreferences.getInstance());
  }

  group('档位迁移 —— 老的 plan/ask 两个字符串', () {
    test('无 key 时默认 ask', () async {
      final mgr = await mgrWith({});
      expect(mgr.defaultMode, PermissionMode.ask);
    });

    test('老 plan 读成 ask —— 二者命令判定完全一致，不因改名被收紧', () async {
      final mgr = await mgrWith({'agent_mode_default': 'plan'});
      expect(mgr.defaultMode, PermissionMode.ask);
    });

    test('老 ask 读成 ask', () async {
      final mgr = await mgrWith({'agent_mode_default': 'ask'});
      expect(mgr.defaultMode, PermissionMode.ask);
    });

    test('bypass 原样保留', () async {
      final mgr = await mgrWith({'agent_mode_default': 'bypass'});
      expect(mgr.defaultMode, PermissionMode.bypass);
    });

    test('坏值兜 ask（会问，而不是不问）', () async {
      final mgr = await mgrWith({'agent_mode_default': 'garbage'});
      expect(mgr.defaultMode, PermissionMode.ask);
    });
  });

  group('per-server 覆盖迁移', () {
    test('无 key 时为 null（跟随全局）', () async {
      final mgr = await mgrWith({});
      expect(mgr.modeOverrideFor('srv1'), isNull);
    });

    test('老 plan 覆盖读成 ask —— 不能返回 null', () async {
      // 返回 null 会让这台服务器的覆盖静默消失（modeOverrideFor 对未知值
      // 返回 null），那是升级即丢失用户设置。
      final mgr = await mgrWith({'agent_mode_srv1': 'plan'});
      expect(mgr.modeOverrideFor('srv1'), PermissionMode.ask);
    });

    test('坏值返回 null（视为无覆盖）', () async {
      final mgr = await mgrWith({'agent_mode_srv1': 'garbage'});
      expect(mgr.modeOverrideFor('srv1'), isNull);
    });

    test('setModeOverride(null) 清除覆盖', () async {
      final mgr = await mgrWith({'agent_mode_srv1': 'bypass'});
      mgr.setModeOverride('srv1', null);
      expect(mgr.modeOverrideFor('srv1'), isNull);
    });
  });
}
