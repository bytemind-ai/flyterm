import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';

void main() {
  group('PermissionRule.matches', () {
    test('通配前缀匹配', () {
      const r = PermissionRule(pattern: 'systemctl status *');
      expect(r.matches('systemctl status nginx'), isTrue);
      expect(r.matches('systemctl status nginx --no-pager'), isTrue);
    });

    test('前缀必须是完整的词 —— statusx 不匹配 status', () {
      const r = PermissionRule(pattern: 'systemctl status *');
      expect(r.matches('systemctl statusx'), isFalse);
      expect(r.matches('systemctlx status nginx'), isFalse);
    });

    test('通配符要求至少有前缀那么多的词', () {
      const r = PermissionRule(pattern: 'systemctl status *');
      expect(r.matches('systemctl'), isFalse);
      expect(r.matches('systemctl status'), isTrue);
    });

    test('不带通配符的 pattern 要求完全相等', () {
      const r = PermissionRule(pattern: 'uptime');
      expect(r.matches('uptime'), isTrue);
      expect(r.matches('uptime -p'), isFalse);
    });

    test('多余空白不影响匹配', () {
      const r = PermissionRule(pattern: 'ls *');
      expect(r.matches('  ls   -la  /var  '), isTrue);
    });

    test('disabled 规则永不匹配', () {
      const r = PermissionRule(pattern: 'ls *', enabled: false);
      expect(r.matches('ls -la'), isFalse);
    });

    test('分词只认空格和制表符 —— 必须与 bash 的词边界一致', () {
      // bash 只把空格/制表符/换行当词分隔符。Dart 的 `\s` 还包含 VT / FF /
      // NBSP / U+2028 / U+3000，用它会让引擎以为 `systemctl<VT>status nginx`
      // 是三个词从而放行，而 bash 会把它当成一个词去找同名程序 ——
      // 「引擎以为批准的」与「实际会跑的」出现分歧。
      //
      // 一律用 \u 转义书写，不要在源码里嵌真实的不可见字符。
      const r = PermissionRule(pattern: 'systemctl status *');
      expect(r.matches('systemctlstatus nginx'), isFalse,
          reason: 'VT 在 bash 里不是词分隔符');
      expect(r.matches('systemctl\u000Cstatus nginx'), isFalse,
          reason: 'FF 在 bash 里不是词分隔符');
      expect(r.matches('systemctl\u00A0status nginx'), isFalse,
          reason: 'NBSP 在 bash 里不是词分隔符');
      expect(r.matches('systemctl\u3000status nginx'), isFalse,
          reason: '全角空格在 bash 里不是词分隔符');
      // 空格与制表符是真正的分隔符，必须照常匹配
      expect(r.matches('systemctl\tstatus\tnginx'), isTrue);
      expect(r.matches('systemctl \t status  nginx'), isTrue);
    });
  });

  group('PermissionRuleSet.allows', () {
    test('任意一条启用的规则命中即放行', () {
      const set = PermissionRuleSet([
        PermissionRule(pattern: 'ls *'),
        PermissionRule(pattern: 'df *'),
      ]);
      expect(set.allows('df -h'), isTrue);
      expect(set.allows('rm -rf /'), isFalse);
    });

    test('空规则集不放行任何命令', () {
      const set = PermissionRuleSet([]);
      expect(set.allows('ls'), isFalse);
    });
  });

  group('suggestRule', () {
    test('通配最后一个词', () {
      expect(suggestRule('systemctl status nginx'), equals('systemctl status *'));
      expect(suggestRule('kubectl get pods'), equals('kubectl get *'));
      expect(suggestRule('rm -rf /tmp/cache'), equals('rm -rf *'));
    });

    test('两词及以下全部保留，不退化成裸命令名', () {
      expect(suggestRule('uptime'), equals('uptime *'));
      expect(suggestRule('ls -la'), equals('ls -la *'));
      expect(suggestRule('df -h'), equals('df -h *'));
      // 这条是重点：绝不能变成 `sudo *`
      expect(suggestRule('sudo reboot'), equals('sudo reboot *'));
    });

    test('全局 flag 写在子命令前也不吞掉子命令', () {
      // 按 flag 切的启发式会在这里生成 `kubectl -n *`，放行该 namespace 下
      // 任意 kubectl 动作（含 delete / exec）。而这正是 kubectl / docker /
      // aws / ssh 最常见的参数顺序。
      expect(suggestRule('kubectl -n prod get pods'),
          equals('kubectl -n prod get *'));
      expect(suggestRule('kubectl -n prod delete pod x'),
          equals('kubectl -n prod delete pod *'));
      expect(suggestRule('docker -D exec -it web sh'),
          equals('docker -D exec -it web *'));
      expect(suggestRule('ssh -p 2222 host uptime'),
          equals('ssh -p 2222 host *'));
      expect(suggestRule('aws --profile prod s3 rm s3://bucket/key'),
          equals('aws --profile prod s3 rm *'));
    });

    test('危险命令保留到倒数第二个词', () {
      expect(suggestRule('sudo rm -rf /var/tmp'), equals('sudo rm -rf *'));
      expect(suggestRule('chmod -R 777 /var/www'), equals('chmod -R 777 *'));
      expect(suggestRule('kubectl exec pod -- rm -rf /'),
          equals('kubectl exec pod -- rm -rf *'));
      expect(suggestRule('git push origin main'), equals('git push origin *'));
    });

    test('规则宽窄不受参数值符号影响', () {
      // 按 flag 切的启发式在这两条上给出宽窄不同的规则，因为 `-5` 碰巧带负号
      // 就被当成了 flag。
      expect(suggestRule('nice -n 5 cmd'), equals('nice -n 5 *'));
      expect(suggestRule('nice -n -5 cmd'), equals('nice -n -5 *'));
    });

    test('空命令返回空串', () {
      expect(suggestRule('   '), equals(''));
    });
  });

  group('JSON 往返', () {
    test('规则集可序列化并读回', () {
      const set = PermissionRuleSet([
        PermissionRule(pattern: 'ls *'),
        PermissionRule(pattern: 'df *', builtin: true, enabled: false),
      ]);
      final back = PermissionRuleSet.fromJson(set.toJson());
      expect(back.rules.length, equals(2));
      expect(back.rules[1].builtin, isTrue);
      expect(back.rules[1].enabled, isFalse);
    });
  });

  group('defaultAllowRules', () {
    test('全部标记为 builtin', () {
      expect(defaultAllowRules.every((r) => r.builtin), isTrue);
    });

    test('覆盖高频只读命令', () {
      const set = PermissionRuleSet(defaultAllowRules);
      expect(set.allows('systemctl status nginx'), isTrue);
      expect(set.allows('journalctl -u nginx -n 50'), isTrue);
      expect(set.allows('kubectl get pods'), isTrue);
      expect(set.allows('docker logs abc123'), isTrue);
      expect(set.allows('cat /etc/nginx/nginx.conf'), isTrue);
    });

    test('写操作不在默认集里', () {
      const set = PermissionRuleSet(defaultAllowRules);
      expect(set.allows('rm -rf /tmp/x'), isFalse);
      expect(set.allows('systemctl restart nginx'), isFalse);
      expect(set.allows('kubectl delete pod x'), isFalse);
      expect(set.allows('kubectl exec -it pod -- sh'), isFalse);
    });

    test('带二级执行原语的命令一律不在默认集里', () {
      // 元字符检测拦不住这些——它们不含任何 shell 元字符。
      // 默认清单是唯一的约束点，见 defaultAllowRules 的准入标准。
      const set = PermissionRuleSet(defaultAllowRules);
      expect(set.allows('find /tmp -exec rm -rf {} +'), isFalse,
          reason: 'find -exec 可执行任意命令且无元字符');
      expect(set.allows('find /tmp -name x'), isFalse,
          reason: 'find 整体出局，不做 flag 级区分——那是能被绕过的黑名单');
      expect(set.allows('awk \'BEGIN{system("id")}\' /etc/hosts'), isFalse);
      expect(set.allows('xargs rm'), isFalse);
      expect(set.allows('eval echo hi'), isFalse);
      expect(set.allows('perl -e "system(1)"'), isFalse);
    });
  });

  group('git 只读规则组', () {
    const rules = PermissionRuleSet(defaultAllowRules);

    test('git status 放行', () {
      expect(rules.allows('git status'), isTrue);
      expect(rules.allows('git status --short'), isTrue);
    });

    test('git diff / log / branch 放行', () {
      expect(rules.allows('git diff HEAD~1'), isTrue);
      expect(rules.allows('git log --oneline -20'), isTrue);
      expect(rules.allows('git branch -a'), isTrue);
    });

    // 这条锁死 §五那段论证：全局 -c 只能出现在子命令之前，词前缀匹配因此
    // 天然把它挡在外面。挂了说明有人把规则改成了裸 `git *`。
    test('git -c core.pager 不放行 —— 词前缀天然挡住全局 flag', () {
      expect(rules.allows('git -c core.pager=x status'), isFalse);
    });

    test('写操作不放行', () {
      expect(rules.allows('git push origin main'), isFalse);
      expect(rules.allows('git commit -m x'), isFalse);
      expect(rules.allows('git config --global core.pager less'), isFalse);
      expect(rules.allows('git show HEAD'), isFalse);
    });
  });

  group('isCredentialDeny', () {
    test('SSH 私钥', () {
      expect(isCredentialDeny('cat ~/.ssh/id_rsa'), isTrue);
      expect(isCredentialDeny('cat /home/u/.ssh/id_ed25519'), isTrue);
    });

    test('裸文件名也拦 —— 用户的 cwd 可能就在 ~/.ssh', () {
      expect(isCredentialDeny('cat id_rsa'), isTrue);
      expect(isCredentialDeny('cat id_ed25519'), isTrue);
    });

    test('公钥不算', () {
      expect(isCredentialDeny('cat ~/.ssh/id_rsa.pub'), isFalse);
      expect(isCredentialDeny('cat id_rsa.pub'), isFalse);
      expect(isCredentialDeny('cat ~/.ssh/known_hosts'), isFalse);
    });

    test('authorized_keys —— 写它等于免审批装 SSH 后门，必须拦', () {
      // authorized_keys 不是私钥，但对它的写操作等价于在目标机器上开一个
      // 免密登录后门；对它的读操作也会把已授权的公钥列表（可用于枚举可信
      // 身份）带出去。之前只拦了 `.ssh/id_*` 与 `.ssh/identity`，漏了这条。
      expect(isCredentialDeny('cat ~/.ssh/authorized_keys'), isTrue);
      expect(isCredentialDeny('cat /root/.ssh/authorized_keys'), isTrue);
      expect(isCredentialDeny('echo ssh-ed25519 AAAA... >> ~/.ssh/authorized_keys'),
          isTrue);
      // authorized_keys2（早期 OpenSSH 的第二份授权文件，仍会被读取）也要拦。
      expect(isCredentialDeny('cat ~/.ssh/authorized_keys2'), isTrue);
      // 裸文件名版——cwd 可能就在 ~/.ssh 下。
      expect(isCredentialDeny('cat authorized_keys'), isTrue);
    });

    test('证书与密钥文件', () {
      expect(isCredentialDeny('cat /etc/ssl/server.pem'), isTrue);
      expect(isCredentialDeny('cat /etc/ssl/server.key'), isTrue);
      expect(isCredentialDeny('cat client.p12'), isTrue);
    });

    test('系统与云凭据', () {
      expect(isCredentialDeny('cat /etc/shadow'), isTrue);
      expect(isCredentialDeny('cat /etc/gshadow'), isTrue);
      expect(isCredentialDeny('cat ~/.aws/credentials'), isTrue);
      expect(isCredentialDeny('ls ~/.config/gcloud'), isTrue);
      expect(isCredentialDeny('cat ~/.docker/config.json'), isTrue);
      expect(isCredentialDeny('cat ~/.kube/config'), isTrue);
      expect(isCredentialDeny('cat ~/.azure/accessTokens.json'), isTrue);
      expect(isCredentialDeny('ls ~/.oci/'), isTrue);
      expect(isCredentialDeny('ls ~/.gnupg/'), isTrue);
      expect(isCredentialDeny('cat ~/.netrc'), isTrue);
      expect(isCredentialDeny('cat ~/.pgpass'), isTrue);
      expect(isCredentialDeny('cat ~/.npmrc'), isTrue);
      expect(isCredentialDeny('cat ~/.my.cnf'), isTrue);
      expect(isCredentialDeny('cat ~/.git-credentials'), isTrue);
    });

    test('dotenv 的后缀变体', () {
      expect(isCredentialDeny('cat /app/.env'), isTrue);
      expect(isCredentialDeny('cat .env.local'), isTrue);
      expect(isCredentialDeny('cat .env.production'), isTrue);
    });

    test('k8s secret', () {
      expect(isCredentialDeny('kubectl get secret my-secret -o yaml'), isTrue);
      expect(isCredentialDeny('kubectl describe secret my-secret'), isTrue);
      expect(isCredentialDeny('kubectl get secrets'), isTrue);
    });

    test('kubectl 的 flag 出现在任意位置都要拦', () {
      // 同一个病修一半等于没修：早先只放宽了「flag 在动词之前」，
      // 于是「flag 在动词与资源名之间」照漏。
      expect(isCredentialDeny('kubectl -n prod get secret x'), isTrue);
      expect(isCredentialDeny('kubectl --context prod describe secret x'), isTrue);
      expect(isCredentialDeny('kubectl get -n prod secrets'), isTrue);
      expect(isCredentialDeny('kubectl get --all-namespaces secrets'), isTrue);
      expect(isCredentialDeny('kubectl get -o json secret my-secret'), isTrue);
      expect(isCredentialDeny('kubectl describe -n kube-system secret x'), isTrue);
    });

    test('项目内的服务账号密钥与 state 文件', () {
      expect(isCredentialDeny('cat terraform.tfstate'), isTrue);
      expect(isCredentialDeny('cat service-account.json'), isTrue);
      // GCP 官방建议的文件名常带前缀词，开头锚点会让它整个漏掉
      expect(isCredentialDeny('cat gcp-service-account-key.json'), isTrue);
      expect(isCredentialDeny('cat credentials.json'), isTrue);
      expect(isCredentialDeny('cat vault.kdbx'), isTrue);
    });

    test('环境变量 dump', () {
      expect(isCredentialDeny('printenv'), isTrue);
      expect(isCredentialDeny('sudo printenv'), isTrue);
      // `env CMD` 是设置变量后执行，不 dump；且 /usr/bin/env 极常见
      expect(isCredentialDeny('env python script.py'), isFalse);
      expect(isCredentialDeny('/usr/bin/env node app.js'), isFalse);
    });

    test('cwd 绕过 —— 目录锚定的 deny 模式挡不住裸文件名', () {
      // 命令本身看不出问题，危险的是它跑在哪个目录下
      expect(isCredentialDeny('cat credentials'), isFalse);
      expect(isSensitiveCwd('/home/u/.aws'), isTrue);
      expect(isSensitiveCwd('/home/u/.kube'), isTrue);
      expect(isSensitiveCwd('/root/.ssh'), isTrue);
      expect(isSensitiveCwd('/home/u/.config/gcloud'), isTrue);
      expect(isSensitiveCwd('/etc/ssl/private'), isTrue);
    });

    test('/etc 不算敏感 cwd —— 它是最常见的工作目录之一', () {
      expect(isSensitiveCwd('/etc'), isFalse);
      expect(isSensitiveCwd('/etc/nginx'), isFalse);
      // /etc/shadow 靠裸文件名模式兜住
      expect(isCredentialDeny('cat shadow'), isTrue);
      expect(isCredentialDeny('cat gshadow'), isTrue);
      expect(isCredentialDeny('cat shadow.conf'), isFalse);
      expect(isCredentialDeny('systemctl status shadowsocks'), isFalse);
    });

    test('普通目录不算敏感 cwd', () {
      expect(isSensitiveCwd('/var/log'), isFalse);
      expect(isSensitiveCwd('/home/u/project'), isFalse);
      expect(isSensitiveCwd('/home/u/.config/myapp'), isFalse);
      expect(isSensitiveCwd('/home/u/.local/share'), isFalse);
      expect(isSensitiveCwd(null), isFalse);
      expect(isSensitiveCwd(''), isFalse);
    });

    test('/proc/<pid>/environ 等价于 printenv', () {
      expect(isCredentialDeny('cat /proc/self/environ'), isTrue);
      expect(isCredentialDeny('cat /proc/1234/environ'), isTrue);
      // 其他 /proc 项是正常诊断信息
      expect(isCredentialDeny('cat /proc/meminfo'), isFalse);
      expect(isCredentialDeny('cat /proc/1/status'), isFalse);
    });

    test('flyterm 备份文件 —— 按原文件是否敏感判定，不再一刀切', () {
      // `edit_file`/`write_file` 会把 `~/.env` 备份成 `~/..env.flyterm.bak`
      // （file_edit.dart `_dotBackupPath`：目录不变、文件名前加一个点）。
      // 反解出原文件名 `~/.env` 后照常命中 dotenv 模式 —— 拦截保留。
      expect(isCredentialDeny('cat ~/..env.flyterm.bak'), isTrue);
      expect(isCredentialDeny('cat /home/u/..env.flyterm.bak'), isTrue);
      // id_rsa 的备份：`.id_rsa.flyterm.bak`，反解出 `id_rsa` 仍敏感。
      expect(isCredentialDeny('cat ~/.ssh/.id_rsa.flyterm.bak'), isTrue);
      // nginx.conf 完全不敏感，它的备份现在按原文件判定，放行。
      // 这条断言是本次收窄的核心：旧版本一刀切拦截，这里曾经是 isTrue。
      expect(isCredentialDeny('cat ~/.nginx.conf.flyterm.bak'), isFalse);
    });

    group('.flyterm.bak 按原文件敏感性判定', () {
      test('不敏感文件的备份放行', () {
        expect(isCredentialDeny('cat /etc/.nginx.conf.flyterm.bak'), isFalse);
      });

      test('敏感文件的备份仍拦 —— 这是当初加这条规则要堵的洞', () {
        expect(isCredentialDeny(r'cat ~/..env.flyterm.bak'), isTrue);
      });

      test('私钥备份仍拦', () {
        expect(isCredentialDeny('cat /root/.ssh/.id_rsa.flyterm.bak'), isTrue);
      });

      test('二阶备份不会因只反解一层而漏过', () {
        // 真正的二阶嵌套（backup(backup('.env'))）按「每层加一个前导点」的
        // 命名规则展开是 `...env.flyterm.bak.flyterm.bak`（三个前导点对应
        // 两次嵌套）：一阶是 `..env.flyterm.bak`，把它再备份一次就是
        // `.` + `..env.flyterm.bak` + `.flyterm.bak`。只反解一层会剩下
        // `..env.flyterm.bak`，仍以 `.flyterm.bak` 结尾、不满足 dotenv 正则
        // 「后面紧跟空白或结尾」的要求，因此漏过；循环剥离两层后正确还原
        // 成 `.env`，命中 dotenv、仍然拦截。
        expect(
            isCredentialDeny(r'cat ~/...env.flyterm.bak.flyterm.bak'), isTrue);
      });

      test('反解不出原文件名时保持拦截', () {
        // 没有前导点 = 不是我们生成的备份名，按原样保守处理。
        expect(isCredentialDeny('cat weird.flyterm.bak'), isTrue);
      });
    });

    test('文件名恰好含 "flyterm" 但不是备份文件——不应被误伤', () {
      expect(isCredentialDeny('cat my-flyterm-notes.txt'), isFalse);
      expect(isCredentialDeny('cat ~/projects/flyterm/README.md'), isFalse);
      expect(isCredentialDeny('cat flyterm.bak.txt'), isFalse,
          reason: '不是 .flyterm.bak 结尾，只是名字里含这个片段');
    });

    test('普通命令不误伤', () {
      expect(isCredentialDeny('cat /etc/nginx/nginx.conf'), isFalse);
      expect(isCredentialDeny('systemctl status nginx'), isFalse);
      expect(isCredentialDeny('kubectl get pods'), isFalse);
      expect(isCredentialDeny('kubectl get secretstore'), isFalse);
      expect(isCredentialDeny('ls /environment'), isFalse);
      expect(isCredentialDeny('cat keyboard.txt'), isFalse);
      expect(isCredentialDeny('cat config.json'), isFalse);
      expect(isCredentialDeny('kubectl get cm app-config'), isFalse,
          reason: 'ConfigMap 按 k8s 约定不是 secret，拦它会大量误伤');
      expect(isCredentialDeny('cat server.crt'), isFalse,
          reason: '证书是公开材料，只有私钥要拦');
      expect(isCredentialDeny('cat request.csr'), isFalse);
      expect(isCredentialDeny('ls ~/.ssh/'), isFalse);
    });
  });
}
