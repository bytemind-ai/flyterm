import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_partition.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/agent/web_fetch.dart';

void main() {
  const noRules = PermissionRuleSet([]);

  CheckResult check(
    String url, {
    PermissionRuleSet rules = noRules,
    PermissionMode mode = PermissionMode.ask,
    WebTarget via = WebTarget.phone,
  }) =>
      checkWebFetch(url, rules: rules, mode: mode, via: via);

  group('checkWebFetch', () {
    test('远端路径免审批 —— agent 本来就能 bash curl，不重复收费', () {
      final r = check('https://docs.nginx.org/', via: WebTarget.server);
      expect(r.decision, ToolDecision.allow);
    });

    test('bypass 档手机路径也放行', () {
      final r = check('https://docs.nginx.org/',
          mode: PermissionMode.bypass, via: WebTarget.phone);
      expect(r.decision, ToolDecision.allow);
    });

    test('手机路径首次弹卡，且可以「允许并记住」', () {
      final r = check('https://docs.nginx.org/en/docs/');
      expect(r.decision, ToolDecision.needApproval);
      expect(r.reason, ApprovalReason.noMatchingRule);
      // canRemember 从 reason 派生，所以这一条同时锁死「不是随便挑了个
      // reason」—— 换成别的值，记住按钮就消失了。
      expect(r.canRemember, isTrue);
      expect(r.suggestedRule, 'web_fetch docs.nginx.org');
    });

    test('已有域名规则的第二次访问免审批', () {
      const rules = PermissionRuleSet([
        PermissionRule(pattern: 'web_fetch docs.nginx.org'),
      ]);
      final r = check('https://docs.nginx.org/other/page', rules: rules);
      expect(r.decision, ToolDecision.allow);
    });

    test('域名规则不通配子域名 —— 逐词相等，不是前缀', () {
      // 这条锁死域名放行规则依赖的性质：pattern 不以 ` *` 结尾时
      // PermissionRule.matches 要求逐词相等。写成 'web_fetch docs.nginx.org *'
      // 就会放行下面这个骗子域名。
      const rules = PermissionRuleSet([
        PermissionRule(pattern: 'web_fetch docs.nginx.org'),
      ]);
      final r = check('https://docs.nginx.org.attacker.com/x', rules: rules);
      expect(r.decision, ToolDecision.needApproval);
    });

    test('readOnly 档与 ask 档的判定一致，只在能否记住上不同', () {
      // 两档的 decision / reason 完全相同（判定路径一致）；差别只有
      // `suggestedRule`：readOnly 不生成规则建议（D10），所以 canRemember
      // 为 false。
      final a = check('https://x.com/', mode: PermissionMode.ask);
      final p = check('https://x.com/', mode: PermissionMode.readOnly);
      expect(p.decision, a.decision);
      expect(p.reason, a.reason);
      expect(a.canRemember, isTrue);
      expect(p.canRemember, isFalse,
          reason: 'readOnly 档不该长出 allow 规则');
      expect(p.suggestedRule, isEmpty);
    });

    test('凭据 deny 不适用 —— URL 里没有本机路径', () {
      // 这个 URL 的 path 长得像私钥路径，但它不是本机文件。误判成
      // credentialDeny 会让 canRemember 变 false，用户永远记不住这个域名。
      final r = check('https://example.com/docs/.ssh/id_rsa.html');
      expect(r.reason, ApprovalReason.noMatchingRule);
      expect(r.denyHit, isFalse);
    });

    test('URL 里的 token 在建议规则里不出现 —— 规则只到 host', () {
      final r = check('https://api.example.com/v1?token=SECRET123');
      expect(r.suggestedRule, 'web_fetch api.example.com');
      expect(r.suggestedRule, isNot(contains('SECRET123')));
    });
  });

  group('webFetchTarget', () {
    test('两个词，host 原样', () {
      expect(webFetchTarget('docs.nginx.org'), 'web_fetch docs.nginx.org');
      expect(webFetchTarget('docs.nginx.org').split(' ').length, 2);
    });
  });

  group('web_fetch 分桶', () {
    ToolCall wf(String url, {String? via}) => ToolCall(
          id: 'c1',
          name: 'web_fetch',
          args: {'url': url, if (via != null) 'via': via},
        );

    test('远端路径进并行桶 —— 免审批的只读调用', () {
      final p = partitionToolCalls(
        [wf('http://10.0.0.5/metrics')],
        rules: noRules,
        mode: PermissionMode.ask,
      );
      expect(p.parallel, [0]);
      expect(p.serial, isEmpty);
    });

    test('未授权域名的手机路径进串行桶 —— 它要弹卡', () {
      final p = partitionToolCalls(
        [wf('https://docs.nginx.org/')],
        rules: noRules,
        mode: PermissionMode.ask,
      );
      expect(p.serial, [0]);
      expect(p.parallel, isEmpty);
    });

    test('已授权域名进并行桶', () {
      const rules = PermissionRuleSet([
        PermissionRule(pattern: 'web_fetch docs.nginx.org'),
      ]);
      final p = partitionToolCalls(
        [wf('https://docs.nginx.org/')],
        rules: rules,
        mode: PermissionMode.ask,
      );
      expect(p.parallel, [0]);
    });

    test('via 参数被分桶判定看在眼里', () {
      // 分桶与执行必须用同一套 via 解析，否则会出现「分桶时判成需审批、
      // 执行时判成放行」。项目历史上有一组测试专门守这个性质。
      final p = partitionToolCalls(
        [wf('https://docs.nginx.org/', via: 'server')],
        rules: noRules,
        mode: PermissionMode.ask,
      );
      expect(p.parallel, [0]);
    });

    test('参数非法进串行桶，不进并行', () {
      final p = partitionToolCalls(
        [const ToolCall(id: 'c', name: 'web_fetch', args: {})],
        rules: noRules,
        mode: PermissionMode.ask,
      );
      expect(p.serial, [0]);
    });

    test('非 http scheme 进串行桶 —— 它会在执行时返错，不该抢跑', () {
      final p = partitionToolCalls(
        [wf('file:///root/.ssh/id_rsa')],
        rules: noRules,
        mode: PermissionMode.bypass,
      );
      expect(p.serial, [0]);
    });

    test('不在 local 桶 —— 它有网络往返', () {
      final p = partitionToolCalls(
        [wf('http://10.0.0.5/m')],
        rules: noRules,
        mode: PermissionMode.ask,
      );
      expect(p.local, isEmpty);
    });
  });
}
