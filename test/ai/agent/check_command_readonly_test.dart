import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/agent/web_fetch.dart' show WebTarget;

void main() {
  const rules = PermissionRuleSet(defaultAllowRules);

  group('readOnly 档', () {
    test('allow 规则命中的只读命令放行', () {
      final r =
          checkCommand('ls -la', rules: rules, mode: PermissionMode.readOnly);
      expect(r.decision, ToolDecision.allow);
    });

    test('无匹配规则 → needApproval，且不可记住', () {
      final r = checkCommand('rm -rf /tmp/x',
          rules: rules, mode: PermissionMode.readOnly);
      expect(r.decision, ToolDecision.needApproval);
      expect(r.reason, ApprovalReason.noMatchingRule);
      // 只读档不该长出 allow 规则
      expect(r.canRemember, isFalse);
      expect(r.suggestedRule, isEmpty);
    });

    test('写文件 → needApproval，不是 deferToPlan', () {
      final r = checkFileWrite('/tmp/a.txt',
          rules: rules, mode: PermissionMode.readOnly);
      expect(r.decision, ToolDecision.needApproval);
      expect(r.reason, ApprovalReason.fileWrite);
      expect(r.canRemember, isFalse);
    });

    test('凭据 deny 仍拦，且不可记住', () {
      final r = checkCommand('cat ~/.ssh/id_rsa',
          rules: rules, mode: PermissionMode.readOnly);
      expect(r.decision, ToolDecision.needApproval);
      expect(r.denyHit, isTrue);
      expect(r.canRemember, isFalse);
    });

    test('只读管道窄门不受影响', () {
      final r = checkCommand('ls -la | grep foo',
          rules: rules, mode: PermissionMode.readOnly);
      expect(r.decision, ToolDecision.allow);
    });

    test('手机侧 web_fetch 不可记住 —— 防 checkWebFetch 路径漏改', () {
      final r = checkWebFetch('https://example.com/x',
          rules: rules, mode: PermissionMode.readOnly, via: WebTarget.phone);
      expect(r.decision, ToolDecision.needApproval);
      expect(r.canRemember, isFalse);
      expect(r.suggestedRule, isEmpty);
    });
  });

  group('ask 档（回归保护 —— 防止改名改坏）', () {
    test('写文件 → deferToPlan', () {
      final r =
          checkFileWrite('/tmp/a.txt', rules: rules, mode: PermissionMode.ask);
      expect(r.decision, ToolDecision.deferToPlan);
    });

    test('无匹配规则 → needApproval 且**可以**记住', () {
      final r = checkCommand('rm -rf /tmp/x',
          rules: rules, mode: PermissionMode.ask);
      expect(r.decision, ToolDecision.needApproval);
      expect(r.canRemember, isTrue);
      expect(r.suggestedRule, isNotEmpty);
    });

    test('手机侧 web_fetch 可以记住域名规则', () {
      final r = checkWebFetch('https://example.com/x',
          rules: rules, mode: PermissionMode.ask, via: WebTarget.phone);
      expect(r.canRemember, isTrue);
      expect(r.suggestedRule, 'web_fetch example.com');
    });

    test('只读管道窄门不受影响', () {
      final r = checkCommand('ls -la | grep foo',
          rules: rules, mode: PermissionMode.ask);
      expect(r.decision, ToolDecision.allow);
    });

    test('凭据 deny 仍拦', () {
      final r = checkCommand('cat ~/.ssh/id_rsa',
          rules: rules, mode: PermissionMode.ask);
      expect(r.denyHit, isTrue);
      expect(r.canRemember, isFalse);
    });
  });

  group('bypass 档不受影响', () {
    test('写文件直接放行', () {
      final r = checkFileWrite('/tmp/a.txt',
          rules: rules, mode: PermissionMode.bypass);
      expect(r.decision, ToolDecision.allow);
    });

    test('凭据 deny 在 bypass 下仍然拦 —— 唯一盖不住的东西', () {
      final r = checkCommand('cat ~/.ssh/id_rsa',
          rules: rules, mode: PermissionMode.bypass);
      expect(r.decision, ToolDecision.needApproval);
      expect(r.denyHit, isTrue);
    });
  });
}
