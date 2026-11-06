// `~` 开头的路径。
//
// 这个 bug 是真机上暴露的，而它本来完全测得到 —— 单元测试断言的都是「命令
// 字符串长什么样」，没人问过「这条命令在 shell 里跑得通吗」。所以这个文件
// 里的关键几条会真的调 sh 跑一遍。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/shell_guard.dart';

/// 在真 shell 里跑一条命令，返回 (exitCode, stdout, stderr)。
///
/// [cwd] 用于测「相对于 cwd 落错地方」那类 bug —— 不传则在测试进程自己的
/// cwd 里跑。
Future<(int, String, String)> _sh(String script, {String? cwd}) async {
  final r = await Process.run('sh', ['-c', script], workingDirectory: cwd);
  return (r.exitCode, (r.stdout as String), (r.stderr as String));
}

void main() {
  group('shellQuotePath', () {
    test(r'~/ 前缀转成可展开的 "$HOME"，其余部分仍被 quote', () {
      expect(shellQuotePath('~/.config/notes.txt'),
          r'"$HOME"' "'/.config/notes.txt'");
    });

    test('单独一个 ~ 就是家目录', () {
      expect(shellQuotePath('~'), r'"$HOME"');
    });

    test('绝对路径行为与 shellQuote 完全一致', () {
      expect(shellQuotePath('/etc/nginx/nginx.conf'),
          shellQuote('/etc/nginx/nginx.conf'));
    });

    test('相对路径也不变', () {
      expect(shellQuotePath('.'), shellQuote('.'));
    });

    test('~user/ 不认，整段当字面路径 —— 与修复前一致，不是新退步', () {
      // shell 的 ~user 展开在双引号内同样不生效，转了也没用。
      expect(shellQuotePath('~root/x'), shellQuote('~root/x'));
    });

    test('路径中间的 ~ 不碰', () {
      expect(shellQuotePath('/tmp/~backup'), shellQuote('/tmp/~backup'));
    });

    // ── `$HOME/` 前缀（2026-10-13）────────────────────────────
    //
    // 同一个病在 `$HOME/` 上复发过一次，见 `install_skill_assets`。

    test(r'$HOME/ 前缀也转成可展开的 "$HOME" —— 而不是被 quote 成字面量', () {
      expect(shellQuotePath(r'$HOME/.flyterm/skill-assets'),
          r'"$HOME"' "'/.flyterm/skill-assets'");
    });

    test(r'单独一个 $HOME 就是家目录', () {
      expect(shellQuotePath(r'$HOME'), r'"$HOME"');
    });

    test(r'路径中间的 $HOME 不碰（只认前缀）', () {
      expect(shellQuotePath(r'/tmp/$HOME/x'), shellQuote(r'/tmp/$HOME/x'));
    });

    test(r'$HOMELESS 之类不误命中 —— 必须紧跟斜杠或结尾', () {
      expect(shellQuotePath(r'$HOMELESS/x'), shellQuote(r'$HOMELESS/x'));
      expect(shellQuotePath(r'$HOME_x/y'), shellQuote(r'$HOME_x/y'));
    });
  });

  group('在真 shell 里验证（这才是当初漏掉的那一层）', () {
    test('shellQuote 的 ~ 路径确实写不进去 —— 这就是那个 bug', () async {
      final home = Directory.systemTemp.createTempSync('quote_bug');
      try {
        final (code, _, err) = await _sh(
          'export HOME=${shellQuote(home.path)}; '
          'mkdir -p "\$HOME/.config"; '
          'printf x > ${shellQuote('~/.config/notes.txt')}',
        );
        expect(code, isNot(0), reason: '单引号内的 ~ 不展开，这条必须失败');
        expect(err.toLowerCase(), contains('directory'));
        expect(File('${home.path}/.config/notes.txt').existsSync(), isFalse);
      } finally {
        home.deleteSync(recursive: true);
      }
    });

    test('shellQuotePath 的 ~ 路径写得进去', () async {
      final home = Directory.systemTemp.createTempSync('quote_fix');
      try {
        final (code, _, err) = await _sh(
          'export HOME=${shellQuote(home.path)}; '
          'mkdir -p "\$HOME/.config"; '
          'printf hello > ${shellQuotePath('~/.config/notes.txt')}',
        );
        expect(code, 0, reason: err);
        final f = File('${home.path}/.config/notes.txt');
        expect(f.existsSync(), isTrue);
        expect(f.readAsStringSync(), 'hello');
      } finally {
        home.deleteSync(recursive: true);
      }
    });

    test('注入防护没有因为这个改动变弱', () async {
      // 路径里塞一个想闭合引号再接命令的载荷。它必须被当成字面文件名，
      // 而不是被执行。
      final home = Directory.systemTemp.createTempSync('quote_inj');
      final canary = '${home.path}/PWNED';
      try {
        final payload = "~/x'; touch ${shellQuote(canary)}; #";
        await _sh(
          'export HOME=${shellQuote(home.path)}; '
          'printf x > ${shellQuotePath(payload)}',
        );
        expect(File(canary).existsSync(), isFalse,
            reason: '路径里的命令被执行了 —— 注入防护破了');
      } finally {
        home.deleteSync(recursive: true);
      }
    });

    test(r'shellQuote 的 $HOME/ 路径确实落错地方 —— 复发的那个 bug', () async {
      // 与上面那条 `~` 的 bug 成对，但**失败形态不同**，这一点很重要：
      //
      // `~` 那个是「报错失败」（命令非 0，用户看得见）。
      // `$HOME` 这个是「**成功但落错地方**」：命令返回 0，而文件全落在
      // **cwd 下一个字面名为 `$HOME` 的目录**里。因为落点是相对于 cwd 的，
      // 每台机器的结果还不一样 —— 完全不可预测。
      //
      // 之所以要 `mkdir -p` 先行：直接 `printf > '$HOME/x'` 会因为父目录
      // 不存在而报错（见下面那条），而真实命令总是先 mkdir。
      final home = Directory.systemTemp.createTempSync('home_bug');
      final cwd = Directory.systemTemp.createTempSync('home_bug_cwd');
      try {
        final (code, _, _) = await _sh(
          'export HOME=${shellQuote(home.path)}; '
          'mkdir -p ${shellQuote(r'$HOME/.flyterm/skill-assets/d')}; '
          'printf x > ${shellQuote(r'$HOME/.flyterm/skill-assets/d/a.sh')}',
          cwd: cwd.path,
        );
        // 命令**返回 0** —— 这就是它危险的地方：不报错，但落错了地方。
        expect(code, 0, reason: '这就是这个 bug 的可怕之处：命令报告成功');
        expect(File('${home.path}/.flyterm/skill-assets/d/a.sh').existsSync(),
            isFalse, reason: '文件没有落到真正的家目录');
        // 而是落在 cwd 下的字面 `$HOME` 目录里
        expect(
            File('${cwd.path}/\$HOME/.flyterm/skill-assets/d/a.sh')
                .existsSync(),
            isTrue,
            reason: r'应当出现在 cwd 下字面名为 $HOME 的目录里 —— 这正是 bug 的形态');
      } finally {
        home.deleteSync(recursive: true);
        cwd.deleteSync(recursive: true);
      }
    });

    test(r'shellQuotePath 的 $HOME/ 路径写得进去', () async {
      final home = Directory.systemTemp.createTempSync('home_fix');
      try {
        final (code, _, err) = await _sh(
          'export HOME=${shellQuote(home.path)}; '
          'mkdir -p ${shellQuotePath(r'$HOME/.flyterm')}; '
          'printf hello > ${shellQuotePath(r'$HOME/.flyterm/x')}',
        );
        expect(code, 0, reason: err);
        final f = File('${home.path}/.flyterm/x');
        expect(f.existsSync(), isTrue,
            reason: r'$HOME 没被展开 —— 修复没生效');
        expect(f.readAsStringSync(), 'hello');
      } finally {
        home.deleteSync(recursive: true);
      }
    });

    test(r'$HOME/ 路径的注入防护也成立', () async {
      final home = Directory.systemTemp.createTempSync('home_inj');
      final canary = '${home.path}/PWNED';
      try {
        final payload = r'$HOME/x' "'; touch ${shellQuote(canary)}; #";
        await _sh(
          'export HOME=${shellQuote(home.path)}; '
          'printf x > ${shellQuotePath(payload)}',
        );
        expect(File(canary).existsSync(), isFalse,
            reason: r'$HOME 分支把命令执行了 —— 注入防护破了');
      } finally {
        home.deleteSync(recursive: true);
      }
    });
  });
}
