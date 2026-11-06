import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/app_control/writable_settings.dart';

void main() {
  group('kAgentWritableSettings', () {
    test('提权向量不在白名单里', () {
      // dangerousCommandGuard：AI 关掉它 = 给自己解开 rm -rf 的刹车
      // （原 biometricLock 已于 2026-10-07 随生物识别锁功能整体移除）
      expect(kAgentWritableSettings, isNot(contains('dangerousCommandGuard')));
    });

    test('指向本机文件系统的键不在白名单里', () {
      expect(kAgentWritableSettings, isNot(contains('sftpDownloadDir')));
      expect(kAgentWritableSettings, isNot(contains('sftpCustomDownloadPath')));
    });

    test('观感类设置在白名单里', () {
      expect(kAgentWritableSettings, contains('fontSize'));
      expect(kAgentWritableSettings, contains('fontFamily'));
      expect(kAgentWritableSettings, contains('lineHeight'));
      expect(kAgentWritableSettings, contains('terminalTheme'));
      expect(kAgentWritableSettings, contains('cursorStyle'));
    });

    test('白名单与硬禁区不相交', () {
      for (final k in kAgentWritableSettings) {
        expect(isForbiddenSettingKey(k), isFalse,
            reason: '$k 同时出现在白名单和硬禁区');
      }
    });
  });

  group('isForbiddenSettingKey —— 提权边界', () {
    test('agent 自身配置连读都不给', () {
      expect(isForbiddenSettingKey('agent.defaultMode'), isTrue);
      expect(isForbiddenSettingKey('agent.appDefaultMode'), isTrue);
      expect(isForbiddenSettingKey('agent.permissionRules'), isTrue);
    });

    test('AI 服务商配置连读都不给', () {
      expect(isForbiddenSettingKey('ai.apiKey'), isTrue);
      expect(isForbiddenSettingKey('aiProvider.openai.key'), isTrue);
    });

    test('大小写变形也拦住 —— 防止靠改写绕过', () {
      expect(isForbiddenSettingKey('Agent.defaultMode'), isTrue);
      expect(isForbiddenSettingKey('AI_API_KEY'), isTrue);
    });

    test('普通观感键不被误伤', () {
      expect(isForbiddenSettingKey('fontSize'), isFalse);
      expect(isForbiddenSettingKey('terminalTheme'), isFalse);
    });

    test('含 ai 两字母的普通键不被误伤 —— 短前缀不做子串匹配', () {
      // 'ai' 只有两个字母，拿它 contains 会把这些全判成禁区
      expect(isForbiddenSettingKey('mailAddress'), isFalse);
      expect(isForbiddenSettingKey('detailLevel'), isFalse);
      expect(isForbiddenSettingKey('keychainMode'), isFalse);
      expect(isForbiddenSettingKey('backgroundKeepAlive'), isFalse);
    });
  });
}
