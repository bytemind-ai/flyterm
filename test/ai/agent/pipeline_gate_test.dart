import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/pipeline_gate.dart';

void main() {
  const rules = PermissionRuleSet(defaultAllowRules);

  group('管道窄门 —— 放行', () {
    test('两段只读管道成立', () {
      expect(isReadOnlyPipeline('journalctl -u nginx | grep error', rules),
          isTrue);
    });

    test('三段只读管道成立', () {
      expect(isReadOnlyPipeline('ps aux | grep java | head -20', rules), isTrue);
    });

    test('四段只读管道成立', () {
      expect(
          isReadOnlyPipeline('cat a | grep b | head -5 | tail -2', rules),
          isTrue);
    });

    test('段间多空格与 tab 不影响判定', () {
      expect(isReadOnlyPipeline('ps aux\t|   grep java', rules), isTrue);
    });

    // 反斜杠转义：放行是**正确**的，不是漏洞。
    // bash 把 `\|` 当字面量，实际执行的是 `ls` 带两个字面参数 `|` 和 `ls`，
    // 而 `ls *` 本就允许 ls 带任意参数。安全性来自前缀包含：bash 真正执行的
    // 命令，其词元以规则前缀开头（这里是 `ls`），后面跟什么都在规则允许范围
    // 内；而不来自「这个段匹配不上规则」——`[ls, \]` 照样命中 `ls *`。
    // 谁想把这条「修」成拒绝，先想清楚这一点。
    test('反斜杠转义的管道放行，且这是正确行为', () {
      expect(isReadOnlyPipeline(r'ls \| ls', rules), isTrue);
    });
  });

  group('管道窄门 —— 不成立', () {
    test('含单引号', () {
      expect(isReadOnlyPipeline("grep 'error 500' x.log | head", rules),
          isFalse);
    });

    test('含双引号', () {
      expect(
          isReadOnlyPipeline('grep "error" x.log | head', rules), isFalse);
    });

    test('含重定向', () {
      expect(isReadOnlyPipeline('ps aux | grep x > /tmp/f', rules), isFalse);
    });

    test('含输入重定向', () {
      expect(isReadOnlyPipeline('grep x < /tmp/f | head', rules), isFalse);
    });

    test('含分号', () {
      expect(isReadOnlyPipeline('ls | head; rm -rf /', rules), isFalse);
    });

    test('含后台符', () {
      expect(isReadOnlyPipeline('ls | head & whoami', rules), isFalse);
    });

    test('含反引号', () {
      expect(isReadOnlyPipeline('ls | grep `whoami`', rules), isFalse);
    });

    test('含命令替换', () {
      expect(isReadOnlyPipeline(r'ls | grep $(whoami)', rules), isFalse);
    });

    test('双竖线产生空段', () {
      expect(isReadOnlyPipeline('ls || whoami', rules), isFalse);
    });

    test('尾段为空', () {
      expect(isReadOnlyPipeline('ls|', rules), isFalse);
    });

    test('段仅由空白构成', () {
      expect(isReadOnlyPipeline('ls |   | head', rules), isFalse);
    });

    test('超过四段', () {
      expect(isReadOnlyPipeline('ls | ls | ls | ls | ls', rules), isFalse);
    });

    test('任一段不在放行清单（tee 能写文件）', () {
      expect(isReadOnlyPipeline('ps aux | tee /etc/x', rules), isFalse);
    });

    test('第一段不在清单', () {
      expect(isReadOnlyPipeline('systemctl restart nginx | head', rules),
          isFalse);
    });

    test('没有管道符时不成立', () {
      expect(isReadOnlyPipeline('ls -la', rules), isFalse);
    });
  });
}
