import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppControlService svc;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    svc = AppControlService(settings: TerminalSettings(SecureStorageService()));
  });

  group('navigateTo', () {
    test('合法目标转发给 onNavigate', () {
      String? got;
      svc.onNavigate = (t) => got = t;
      final r = svc.navigateTo('ssh_keys');
      expect(r.ok, isTrue);
      expect(got, 'ssh_keys');
    });

    test('未知目标被拒并列出可选项', () {
      svc.onNavigate = (_) {};
      final r = svc.navigateTo('nowhere');
      expect(r.ok, isFalse);
      expect(r.error, contains('ssh_keys'));
    });

    test('宿主没注入回调时明确回不可用', () {
      final r = svc.navigateTo('ai');
      expect(r.ok, isFalse);
      expect(r.error, contains('not available'));
    });

    // 导航不是状态变更，撤销它没有意义（用户按返回键就回来了）。
    test('不进撤销栈', () {
      svc.onNavigate = (_) {};
      svc.navigateTo('settings');
      expect(svc.changeLog.pending, isEmpty);
    });
  });

  group('readUiState', () {
    test('没注入位置提供者时回 unknown 而不是崩', () {
      expect(svc.readUiState()['current'], 'unknown');
    });

    test('回当前位置与可去的地方', () {
      svc.currentLocationProvider = () => 'servers';
      final s = svc.readUiState();
      expect(s['current'], 'servers');
      expect(s['can_navigate_to'], contains('ssh_keys'));
    });
  });

  // 这组守的是 service / spec / shell 三边的契约。漏一处的后果是
  // 「AI 说带你过去，然后什么都没发生」—— 比报错更难查。
  group('导航目标三边一致', () {
    test('navigate_to 的 enum 与 navigationTargets 完全相同', () {
      final enumVals =
          ((navigateToToolSpec.parameters['properties'] as Map)['target']
              as Map)['enum'] as List;
      expect(enumVals.toSet(),
          equals(AppControlService.navigationTargets.keys.toSet()));
    });

    test('每个目标都有人类可读的说明', () {
      for (final e in AppControlService.navigationTargets.entries) {
        expect(e.value.trim(), isNotEmpty, reason: '${e.key} 没有说明');
      }
    });
  });
}
