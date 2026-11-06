import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

void main() {
  const ruleSet = PermissionRuleSet(defaultAllowRules);

  group('check —— ask 模式', () {
    test('匹配默认规则的命令直接放行', () {
      final r = checkCommand('systemctl status nginx',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.allow));
      expect(r.denyHit, isFalse);
    });

    test('未匹配规则的命令需要审批', () {
      final r = checkCommand('systemctl restart nginx',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.reason, equals(ApprovalReason.noMatchingRule));
    });

    test('含元字符的命令一律审批，无视 allow 规则', () {
      // 原本用的是 `ls -la | grep foo`，两段都在放行清单里，管道窄门上线后
      // 它变成合法放行。改用第二段不在清单的写法，这条用例守的仍是
      // 「元字符本身不能让命令绕过规则」。
      final r = checkCommand('ls -la | tee /etc/x',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.reason, equals(ApprovalReason.shellMetachar));
    });

    test('命中 deny 时审批且不可记住规则', () {
      final r = checkCommand('cat ~/.ssh/id_rsa',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.denyHit, isTrue);
      expect(r.canRemember, isFalse);
      expect(r.reason, equals(ApprovalReason.credentialDeny));
    });

    test('deny 优先于元字符（reason 取 deny）', () {
      final r = checkCommand('cat ~/.ssh/id_rsa | head',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.denyHit, isTrue);
      expect(r.reason, equals(ApprovalReason.credentialDeny));
    });

    test('可记住时给出建议规则', () {
      final r = checkCommand('systemctl restart nginx',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.canRemember, isTrue);
      expect(r.suggestedRule, equals('systemctl restart *'));
    });

    test('含元字符时不建议规则 —— 前缀规则对复合命令没有意义', () {
      final r = checkCommand('ls | grep x',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.canRemember, isFalse);
    });
  });

  group('check —— cwd 落在凭据目录', () {
    test('cwd 敏感时命令再普通也要审批', () {
      // 命令本身完全看不出问题，危险的是它跑在哪儿
      final r = checkCommand('cat credentials',
          rules: ruleSet, mode: PermissionMode.ask, cwd: '/home/u/.aws');
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.denyHit, isTrue);
      expect(r.canRemember, isFalse);
    });

    test('bypass 也覆盖不了敏感 cwd', () {
      final r = checkCommand('cat config',
          rules: ruleSet, mode: PermissionMode.bypass, cwd: '/root/.kube');
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.denyHit, isTrue);
    });

    test('普通 cwd 不受影响', () {
      final r = checkCommand('ls -la',
          rules: ruleSet, mode: PermissionMode.ask, cwd: '/var/log');
      expect(r.decision, equals(ToolDecision.allow));
    });

    test('不传 cwd 时行为不变', () {
      final r = checkCommand('ls -la', rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.allow));
    });
  });

  group('CheckResult 的 flag 由 reason 派生', () {
    test('每种 reason 对应唯一一组 flag', () {
      // 派生而非独立存字段：改了分支的 flag 却忘了改 reason 这类不一致
      // 在类型层面就写不出来。
      const deny = CheckResult(
          decision: ToolDecision.needApproval,
          reason: ApprovalReason.credentialDeny);
      expect(deny.denyHit, isTrue);
      expect(deny.canRemember, isFalse);

      const meta = CheckResult(
          decision: ToolDecision.needApproval,
          reason: ApprovalReason.shellMetachar);
      expect(meta.denyHit, isFalse, reason: '普通复合命令不该弹凭据警示');
      expect(meta.canRemember, isFalse);

      const noRule = CheckResult(
          decision: ToolDecision.needApproval,
          reason: ApprovalReason.noMatchingRule,
          suggestedRule: 'systemctl status *');
      expect(noRule.denyHit, isFalse);
      expect(noRule.canRemember, isTrue);

      // 2026-10-13 收紧：noMatchingRule **且** suggestedRule 非空才能记住。
      // readOnly 档刻意不生成建议规则（空串），此时不应显示「总是允许」
      // ——否则审批卡上会出现一个带空规则的按钮。
      const noRuleNoSuggestion = CheckResult(
          decision: ToolDecision.needApproval,
          reason: ApprovalReason.noMatchingRule);
      expect(noRuleNoSuggestion.canRemember, isFalse,
          reason: '空建议规则不能再「允许并记住」');

      const ok = CheckResult(decision: ToolDecision.allow);
      expect(ok.denyHit, isFalse);
      expect(ok.canRemember, isFalse);
    });
  });

  group('check —— bypass 模式', () {
    test('未匹配规则的命令也放行', () {
      final r = checkCommand('rm -rf /tmp/build',
          rules: ruleSet, mode: PermissionMode.bypass);
      expect(r.decision, equals(ToolDecision.allow));
    });

    test('含元字符的命令也放行', () {
      final r = checkCommand('ls | grep x',
          rules: ruleSet, mode: PermissionMode.bypass);
      expect(r.decision, equals(ToolDecision.allow));
    });

    test('deny 仍然生效 —— bypass 不能覆盖', () {
      final r = checkCommand('cat ~/.ssh/id_rsa',
          rules: ruleSet, mode: PermissionMode.bypass);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.denyHit, isTrue);
    });
  });

  group('read_file 走同一套判定', () {
    test('视同 cat <path> —— 默认放行', () {
      final r = checkReadFile('/etc/nginx/nginx.conf',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.allow));
    });

    test('关掉 cat * 规则后开始弹审批', () {
      const noCat = PermissionRuleSet([PermissionRule(pattern: 'ls *')]);
      final r = checkReadFile('/etc/nginx/nginx.conf',
          rules: noCat, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.needApproval));
    });

    test('deny 路径照常拦截', () {
      final r = checkReadFile('/home/u/.ssh/id_rsa',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.denyHit, isTrue);
      expect(r.decision, equals(ToolDecision.needApproval));
    });

    test('敏感 cwd 下读裸文件名也拦', () {
      final r = checkReadFile('credentials',
          rules: ruleSet, mode: PermissionMode.ask, cwd: '/home/u/.aws');
      expect(r.denyHit, isTrue);
    });
  });

  group('checkFileWrite', () {
    const rules = PermissionRuleSet(defaultAllowRules);

    test('普通路径：要审批，但不可记住', () {
      final r = checkFileWrite('/etc/nginx/nginx.conf',
          rules: rules, mode: PermissionMode.readOnly);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.reason, equals(ApprovalReason.fileWrite));
      expect(r.canRemember, isFalse,
          reason: '默认放行清单的准入标准就是「不得具备写文件能力」，'
              '写文件工具天生违反，没有任何参数组合能让它变安全');
      expect(r.denyHit, isFalse);
      expect(r.suggestedRule, isEmpty);
    });

    test('凭据路径：命中 deny，带警示', () {
      final r = checkFileWrite('/home/u/.ssh/id_rsa',
          rules: rules, mode: PermissionMode.ask);
      expect(r.reason, equals(ApprovalReason.credentialDeny));
      expect(r.denyHit, isTrue);
      expect(r.canRemember, isFalse);
    });

    test('敏感 cwd 下的裸文件名也命中 deny', () {
      final r = checkFileWrite('credentials',
          rules: rules, mode: PermissionMode.ask, cwd: '/home/u/.aws');
      expect(r.denyHit, isTrue);
    });

    test('bypass 模式放行（与 bash 一致）', () {
      final r = checkFileWrite('/etc/nginx/nginx.conf',
          rules: rules, mode: PermissionMode.bypass);
      expect(r.decision, equals(ToolDecision.allow),
          reason: 'bypass 下 bash 已经可以无审批跑 rm -rf /；让 write_file '
              '在同一模式下反而弹审批，是把更弱的操作管得更严');
    });

    test('bypass 也覆盖不了凭据边界', () {
      final r = checkFileWrite('/home/u/.ssh/id_rsa',
          rules: rules, mode: PermissionMode.bypass);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.denyHit, isTrue);
    });

    test('allow 规则不参与判定——cat * 不能让写文件免审批', () {
      const permissive = PermissionRuleSet([PermissionRule(pattern: '*')]);
      final r = checkFileWrite('/etc/passwd',
          rules: permissive, mode: PermissionMode.readOnly);
      expect(r.decision, equals(ToolDecision.needApproval));
    });
  });

  group('check —— plan 模式', () {
    test('命中 allowlist 的命令照常放行', () {
      final r = checkCommand('systemctl status nginx',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.allow));
    });

    test('未命中的命令弹卡——探查不能断流，不能一律转提案', () {
      final r = checkCommand('find /var -name x',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.reason, equals(ApprovalReason.noMatchingRule));
    });

    test('元字符照常弹卡', () {
      // 样例换过：原本用的是 `ls -la | grep foo`，两段都在放行清单里，管道
      // 窄门上线后它**合法放行**，不再是「应该弹卡的元字符命令」这个概念的
      // 有效样例。换成第二段含 `tee`（能写文件、不在清单）的写法。
      //
      // 守的性质没变：元字符不能让命令绕过规则。新放行的行为由
      // `pipeline_gate_test.dart` 与本文件「管道窄门接入判定顺序」那组守护，
      // 覆盖没有丢失。
      final r = checkCommand('ls -la | tee /etc/x',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.reason, equals(ApprovalReason.shellMetachar));
    });

    test('凭据边界在 plan 下仍然生效', () {
      final r = checkCommand('cat ~/.ssh/id_rsa',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.denyHit, isTrue);
      expect(r.canRemember, isFalse);
    });

    test('写文件转提案，不弹卡', () {
      final r = checkFileWrite('/etc/nginx/nginx.conf',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.deferToPlan));
    });

    test('写文件命中凭据边界时仍是审批，不是提案', () {
      // 判定顺序：凭据边界永远最先。转提案会让一次凭据写入绕过那道警示。
      final r = checkFileWrite('/home/u/.ssh/authorized_keys',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.reason, equals(ApprovalReason.credentialDeny));
    });

    test('bypass 仍然盖过 plan 的转提案', () {
      final r = checkFileWrite('/etc/nginx/nginx.conf',
          rules: ruleSet, mode: PermissionMode.bypass);
      expect(r.decision, equals(ToolDecision.allow));
    });

    test('readOnly 模式下写文件还是强制审批，不受影响', () {
      // 旧命名下这档叫 `ask`，2026-10-13 改名后叫 `readOnly`（新 `ask`
      // 继承了旧 `plan` 的攒批语义，写文件进提案队列）。
      final r = checkFileWrite('/etc/nginx/nginx.conf',
          rules: ruleSet, mode: PermissionMode.readOnly);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.reason, equals(ApprovalReason.fileWrite));
    });
  });

  group('管道窄门接入判定顺序', () {
    test('纯只读管道在 ask 档直接放行', () {
      final r = checkCommand('journalctl -u nginx | grep error',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.allow));
      expect(r.reason, isNull);
    });

    test('某段不在清单时仍按元字符审批', () {
      final r = checkCommand('ps aux | tee /etc/x',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.reason, equals(ApprovalReason.shellMetachar));
    });

    test('带引号的管道仍按元字符审批', () {
      final r = checkCommand("grep 'error 500' x.log | head",
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.reason, equals(ApprovalReason.shellMetachar));
    });

    // 顺序不变量：窄门必须在凭据边界**之后**。
    // 这条测试挂了说明窄门被挪到了第 1 步之前，那是一个数据外泄口子。
    test('凭据 deny 优先于窄门 —— 两段都在清单也不放行', () {
      final r = checkCommand('cat ~/.ssh/id_rsa | head',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.needApproval));
      expect(r.reason, equals(ApprovalReason.credentialDeny));
      expect(r.canRemember, isFalse);
    });

    // 顺序不变量：bypass 必须在窄门**之前**。
    test('bypass 档下含引号的管道照样放行', () {
      final r = checkCommand("grep 'x' a.log | head",
          rules: ruleSet, mode: PermissionMode.bypass);
      expect(r.decision, equals(ToolDecision.allow));
    });

    test('plan 档与 ask 档在窄门上行为一致', () {
      final r = checkCommand('ps aux | grep java',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.decision, equals(ToolDecision.allow));
    });

    test('窄门放行的命令不产生可记住的规则', () {
      final r = checkCommand('ps aux | grep java',
          rules: ruleSet, mode: PermissionMode.ask);
      expect(r.canRemember, isFalse);
      expect(r.suggestedRule, isEmpty);
    });
  });
}
