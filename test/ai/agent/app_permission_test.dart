import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/app_permission.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

void main() {
  group('checkAppControl —— 硬清单优先于一切档位', () {
    for (final mode in PermissionMode.values) {
      test('$mode 档下 session_close 仍要审批', () {
        final r = checkAppControl('session_close', mode: mode);
        expect(r.decision, ToolDecision.needApproval);
      });
    }

    test('bypass 档下 server_entry_delete 仍要审批', () {
      final r =
          checkAppControl('server_entry_delete', mode: PermissionMode.bypass);
      expect(r.decision, ToolDecision.needApproval);
    });

    test('hardApproval:false 覆盖静态名单（session_close 无活跃连接时可放行）', () {
      final r = checkAppControl('session_close',
          mode: PermissionMode.bypass, hardApproval: false);
      expect(r.decision, ToolDecision.allow);
    });
  });

  group('checkAppControl —— 三档行为', () {
    test('readOnly 档：只读工具放行', () {
      for (final tool in kAppReadOnlyTools) {
        final r = checkAppControl(tool, mode: PermissionMode.readOnly);
        expect(r.decision, ToolDecision.allow, reason: '$tool 应放行');
      }
    });

    test('readOnly 档：写操作审批', () {
      final r =
          checkAppControl('app_settings_set', mode: PermissionMode.readOnly);
      expect(r.decision, ToolDecision.needApproval);
    });

    test('ask 档：写操作审批', () {
      final r = checkAppControl('app_settings_set', mode: PermissionMode.ask);
      expect(r.decision, ToolDecision.needApproval);
    });

    test('bypass 档：写操作放行', () {
      final r =
          checkAppControl('app_settings_set', mode: PermissionMode.bypass);
      expect(r.decision, ToolDecision.allow);
    });
  });

  group('reason 恒为 null —— canRemember 自动为 false', () {
    test('app 工具没有「允许并记住」语义', () {
      final r = checkAppControl('app_settings_set', mode: PermissionMode.ask);
      expect(r.reason, isNull);
      expect(r.canRemember, isFalse);
    });
  });
}
