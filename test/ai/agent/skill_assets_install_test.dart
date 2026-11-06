import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/file_edit.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

void main() {
  List<ToolSpec> full() =>
      agentToolSpecsFor(AgentToolTier.full, hasSkills: true);

  ToolCall installCall({String name = 'deploy', Map<String, dynamic> extra = const {}}) =>
      ToolCall(id: 'c1', name: 'install_skill_assets',
          args: {'name': name, ...extra});

  AgentSkillAsset a(String p, String c, {bool x = false}) =>
      AgentSkillAsset(path: p, content: c, executable: x);

  group('buildInstallAssetsCommand', () {
    test('mkdir、写文件、按需 chmod', () {
      final cmd = buildInstallAssetsCommand('/home/u/.flyterm/skill-assets/d', [
        a('scripts/check.sh', 'echo hi', x: true),
        a('templates/n.conf', 'server {}'),
      ]);
      expect(cmd, startsWith('{ '));
      expect(cmd, endsWith('; }'));
      expect(cmd, contains('mkdir -p'));
      // 可执行位只加在 executable 的那个上。
      expect(cmd, contains('chmod +x'));
      // 载荷是 base64，正文不会被原样拼进命令。
      expect(cmd, isNot(contains('echo hi')));
      expect(cmd, isNot(contains('server {}')));
    });

    test('嵌套附件的父目录先建', () {
      final cmd = buildInstallAssetsCommand('/d', [
        a('a/b/c.sh', 'x'),
      ]);
      // `mkdir -p` 会连带建出中间层，所以根目录 + a/b 两次就够。
      // 关键是 a/b **必须**出现在写文件之前。
      final mkdirs = 'mkdir -p'.allMatches(cmd).length;
      expect(mkdirs, greaterThanOrEqualTo(2));
      final writeAt = cmd.indexOf('base64 -d');
      final parentAt = cmd.indexOf("'/d/a/b'");
      expect(parentAt, greaterThan(0));
      expect(parentAt, lessThan(writeAt),
          reason: '父目录的 mkdir 必须在写文件之前');
    });

    test('没有附件时只有 mkdir，不报错', () {
      final cmd = buildInstallAssetsCommand('/d', const []);
      expect(cmd, contains('mkdir -p'));
      expect(cmd, isNot(contains('base64 -d')));
    });

    test('含单引号/美元符的内容不会破坏命令（base64 转义）', () {
      final cmd = buildInstallAssetsCommand(
          '/d', [a('x.sh', r"echo 'hi' $USER `whoami`")]);
      expect(cmd, isNot(contains(r"echo 'hi'")));
      expect(cmd, isNot(contains(r'$USER')));
    });

    test('slug 只保留安全字符', () {
      expect(slugifySkillDir('nginx-troubleshooting'),
          equals('nginx-troubleshooting'));
      expect(slugifySkillDir('部署 脚本'), equals('skill'),
          reason: '全被折掉时回落');
      expect(slugifySkillDir('a/b c'), equals('a-b-c'));
      expect(slugifySkillDir('---x---'), equals('x'));
    });

    test(r'完整的安装路径用 ~ 而不是 $HOME —— 单引号内 $HOME 不展开', () {
      // 真实命令由 `skill_executors.dart` 拼成 `~/.flyterm/skill-assets/<slug>`，
      // 再经 `shellQuotePath` 引用。这里用同一种拼法验证落点可展开。
      const installDir = '~/.flyterm/skill-assets/deploy-check';
      final cmd = buildInstallAssetsCommand(installDir, [a('a.sh', 'x')]);
      expect(cmd, contains(r'"$HOME"' "'/.flyterm/skill-assets/deploy-check'"));
      expect(cmd, isNot(contains("'~/")),
          reason: '单引号内的 ~ 不展开，会出现字面 ~ 目录');
    });
  });

  group('判定路径不能带 slug（技能名会污染凭据判定）', () {
    // 回归：`checkPath` 曾经拼成 `/root/.flyterm/skill-assets/<slug>`，而
    // 凭据 deny 清单里有一批**不带路径锚点**的模式（`credentials.json`、
    // `service[-_]?account[\w.-]*\.json`、`\.env(\.\w+)?`）—— 技能名
    // 叫这类名字时会误命中，弹出一条与事实无关的「内容将发送给 <provider>」
    // 警告；bypass 档下还会被莫名拦住。
    //
    // 修法：判定只传目录前缀，不拼 slug —— 危险程度由**目录**决定，
    // 不由那个文件夹叫什么决定。
    test('技能名叫 credentials.json 不误命中凭据边界', () {
      // 这个 skill 名在旧实现下会被 `isCredentialDeny` 判为 true。
      final checkPath = '/.flyterm/skill-assets';
      final check = checkFileWrite(checkPath,
          rules: const PermissionRuleSet(defaultAllowRules),
          mode: PermissionMode.ask);
      expect(check.denyHit, isFalse,
          reason: '附件目录永远不敏感 —— 不该弹凭据警示');
    });

    test('带 slug 的旧形态确实会误命中（这个 bug 的形态）', () {
      // 钉住旧行为，让「为什么不能拼 slug」在测试里可读。
      expect(isCredentialDeny('/root/.flyterm/skill-assets/credentials.json'),
          isTrue);
      expect(
          isCredentialDeny(
              '/root/.flyterm/skill-assets/service-account-key.json'),
          isTrue);
      // 而不带 slug 的目录前缀对全部模式都是安全的。
      expect(isCredentialDeny('/.flyterm/skill-assets'), isFalse);
    });

    test('技能名里的凭据样式都不再影响判定', () {
      const safe = '/.flyterm/skill-assets';
      // 这批名字在旧写法下**确实会误命中**（已验证）；用来证明新写法真的
      // 把它们屏蔽了。`my.env` 不在此列 —— `.env` 模式要求前面有分隔符，
      // 它在旧写法下本来就不命中（列在这里只会给测试增加无区分度的噪声）。
      const wouldFalsePositive = [
        'credentials.json',
        'service-account-key.json',
        '.env',
        'id_rsa',
      ];
      for (final name in wouldFalsePositive) {
        final slug = slugifySkillDir(name);
        // 新写法：判定根本不看 slug，所以坏名字不需要被“避开”。
        expect(isCredentialDeny(safe), isFalse,
            reason: 'name=$name 时目录前缀仍应安全');
        // 旧写法确实会命中 —— 保证这个用例不是空转。
        expect(isCredentialDeny('/root/.flyterm/skill-assets/$slug'), isTrue,
            reason: 'name=$name 在旧写法下本该误命中');
      }
    });
  });

  group('install_skill_assets 执行', () {
    test('ask 模式弹审批，批准后投送', () async {
      final runner = FakeRunner();
      final loop = makeLoop(
        mode: PermissionMode.readOnly,
        runner: runner,
        toolSpecs: full,
        skillNamesProvider: () => const ['deploy'],
        skillAssetProvider: (n, {alsoAllow = const {}}) async =>
            [a('scripts/x.sh', 'echo hi', x: true)],
        provider: FakeProvider([
          AIResponse(toolCalls: [installCall()]),
          const AIResponse(text: 'ok'),
        ]),
      );
      final fut = loop.send('go');
      await Future<void>.delayed(Duration.zero);

      expect(loop.pendingApprovals, hasLength(1));
      loop.respondApproval(
          loop.pendingApprovals.first.seq, ApprovalDecision.allowOnce);
      await fut;

      expect(runner.ran, hasLength(1));
      expect(runner.ran.single, contains('base64 -d'));
      expect(runner.ran.single, contains('chmod +x'));
    });

    test('用户在卡上看到的是附件全文，不是文件名', () async {
      final loop = makeLoop(
        mode: PermissionMode.readOnly,
        toolSpecs: full,
        skillNamesProvider: () => const ['deploy'],
        skillAssetProvider: (n, {alsoAllow = const {}}) async =>
            [a('scripts/x.sh', 'UNIQUE_MARKER_CONTENT', x: true)],
        provider: FakeProvider([
          AIResponse(toolCalls: [installCall()]),
          const AIResponse(text: 'ok'),
        ]),
      );
      final fut = loop.send('go');
      await Future<void>.delayed(Duration.zero);
      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.preview, isNotNull);
      expect(ev.preview!.newText, contains('UNIQUE_MARKER_CONTENT'),
          reason: '用户在批准一段自己没读过的、将来会被执行的文字');
      expect(ev.preview!.newText, contains('(executable)'));
      loop.respondApproval(
          loop.pendingApprovals.first.seq, ApprovalDecision.reject);
      await fut;
    });

    test('bypass 模式直接放行', () async {
      final runner = FakeRunner();
      final loop = makeLoop(
        mode: PermissionMode.bypass,
        runner: runner,
        toolSpecs: full,
        skillNamesProvider: () => const ['deploy'],
        skillAssetProvider: (n, {alsoAllow = const {}}) async =>
            [a('x.sh', 'z')],
        provider: FakeProvider([
          AIResponse(toolCalls: [installCall()]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      expect(loop.pendingApprovals, isEmpty);
      expect(runner.ran, hasLength(1));
    });

    test('plan 模式进提案队列而非弹卡 —— 它改的是这台服务器', () async {
      final loop = makeLoop(
        mode: PermissionMode.ask,
        toolSpecs: full,
        skillNamesProvider: () => const ['deploy'],
        skillAssetProvider: (n, {alsoAllow = const {}}) async =>
            [a('x.sh', 'z')],
        provider: FakeProvider([
          AIResponse(toolCalls: [installCall()]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      expect(loop.events.whereType<PlanProposalEvent>(), isNotEmpty);
      expect(loop.pendingApprovals, isEmpty);
    });

    test('技能没有附件时不报错，也不跑命令', () async {
      final runner = FakeRunner();
      final loop = makeLoop(
        mode: PermissionMode.ask,
        runner: runner,
        toolSpecs: full,
        skillNamesProvider: () => const ['deploy'],
        skillAssetProvider: (n, {alsoAllow = const {}}) async => const [],
        provider: FakeProvider([
          AIResponse(toolCalls: [installCall()]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.status, equals(ToolCallStatus.done));
      expect(ev.output, contains('no attached files'));
      expect(runner.ran, isEmpty);
      expect(loop.pendingApprovals, isEmpty);
    });

    test('名字不在白名单时拒绝 —— 不能变成绕过索引上限的后门', () async {
      final runner = FakeRunner();
      final loop = makeLoop(
        mode: PermissionMode.bypass,
        runner: runner,
        toolSpecs: full,
        skillNamesProvider: () => const ['other'],
        skillAssetProvider: (n, {alsoAllow = const {}}) async =>
            [a('x.sh', 'z')],
        provider: FakeProvider([
          AIResponse(toolCalls: [installCall(name: 'secret')]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.status, equals(ToolCallStatus.failed));
      expect(ev.output, contains('No skill named'));
      expect(runner.ran, isEmpty);
    });

    test('库里存着不安全 path 时拒绝投送', () async {
      final runner = FakeRunner();
      final loop = makeLoop(
        mode: PermissionMode.bypass,
        runner: runner,
        toolSpecs: full,
        skillNamesProvider: () => const ['deploy'],
        skillAssetProvider: (n, {alsoAllow = const {}}) async =>
            [a('../../.ssh/authorized_keys', 'k')],
        provider: FakeProvider([
          AIResponse(toolCalls: [installCall()]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.status, equals(ToolCallStatus.failed));
      expect(runner.ran, isEmpty);
    });

    test('远端写入失败时把输出回填给模型', () async {
      final loop = makeLoop(
        mode: PermissionMode.bypass,
        runner: FakeRunner(
          result: const CommandOutput(
              stdout: '', stderr: 'mkdir: permission denied', exitCode: 1),
        ),
        toolSpecs: full,
        skillNamesProvider: () => const ['deploy'],
        skillAssetProvider: (n, {alsoAllow = const {}}) async =>
            [a('x.sh', 'z')],
        provider: FakeProvider([
          AIResponse(toolCalls: [installCall()]),
          const AIResponse(text: 'ok'),
        ]),
      );
      await loop.send('go');
      final ev = loop.events.whereType<ToolCallEvent>().single;
      expect(ev.status, equals(ToolCallStatus.failed));
      expect(ev.output, contains('permission denied'));
    });

    test('lean 档不声明这个工具 —— 它是需审批的写入', () {
      final lean = agentToolSpecsFor(AgentToolTier.lean, hasSkills: true)
          .map((t) => t.name);
      final fullNames = agentToolSpecsFor(AgentToolTier.full, hasSkills: true)
          .map((t) => t.name);
      expect(lean, isNot(contains('install_skill_assets')));
      expect(fullNames, contains('install_skill_assets'));
    });

    test('save_skill 的 spec 暴露了 assets 参数', () {
      // **守的是“executor 支持但 spec 没暴露”这个漏**：模型只能看到 spec，
      // 参数不在 spec 里就永远不会传，executor 里那条路径成为死代码。
      // 第一版正是这样：先加了 executor，忘了加 spec。
      final props =
          saveSkillToolSpec.parameters['properties'] as Map<String, dynamic>;
      expect(props.keys, contains('assets'));
      final assets = props['assets'] as Map<String, dynamic>;
      expect(assets['type'], equals('array'));
      final itemProps =
          (assets['items'] as Map<String, dynamic>)['properties']
              as Map<String, dynamic>;
      expect(itemProps.keys, containsAll(['path', 'content', 'executable']));
    });
  });
}
