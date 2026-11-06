import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';

import '_prompt_helpers.dart';

void main() {
  group('agentToolSpecsFor(hasOtherServers)', () {
    test('只有一台机器时不声明 list_servers / copy_between_servers', () {
      final specs = agentToolSpecsFor(AgentToolTier.full,
          hasOtherServers: false);
      final names = specs.map((s) => s.name).toSet();
      expect(names, isNot(contains('list_servers')));
      expect(names, isNot(contains('copy_between_servers')));
      // 其余 full 档工具照旧
      expect(names, contains('bash'));
      expect(names, contains('edit_file'));
      expect(names, contains('grep'));
    });

    test('有多台机器时两个工具都在', () {
      final names = agentToolSpecsFor(AgentToolTier.full,
              hasOtherServers: true)
          .map((s) => s.name)
          .toSet();
      expect(names, contains('list_servers'));
      expect(names, contains('copy_between_servers'));
    });

    test('默认值是 false —— 漏传要少两个工具，不是多两个拿不到的', () {
      final names =
          agentToolSpecsFor(AgentToolTier.full).map((s) => s.name).toSet();
      expect(names, isNot(contains('list_servers')));
    });

    test('lean 档本来就没有这两个，传 true 也不会凭空多出来', () {
      final names = agentToolSpecsFor(AgentToolTier.lean,
              hasOtherServers: true)
          .map((s) => s.name)
          .toSet();
      expect(names, isNot(contains('list_servers')));
      expect(names, isNot(contains('copy_between_servers')));
    });
  });

  group('buildAgentSystemPrompt(hasOtherServers)', () {
    String promptFor({required bool multi}) => buildAgentSystemPrompt(
          cwd: '/home/ops',
          terminalContext: null,
          tier: AgentToolTier.full,
          hasOtherServers: multi,
        );

    test('单机时四条多机引导都不出现', () {
      final p = promptFor(multi: false);
      expect(p, isNot(contains('list_servers')));
      expect(p, isNot(contains('copy_between_servers')));
      expect(p, isNot(contains('one `bash` call per machine')));
      expect(p, isNot(contains('do NOT take `server`')));
    });

    test('多机时四条都在', () {
      final p = promptFor(multi: true);
      expect(p, contains('list_servers'));
      expect(p, contains('copy_between_servers'));
      expect(p, contains('one `bash` call per machine'));
      expect(p, contains('do NOT take `server`'));
    });

    test('job 三件套不在「do NOT take server」名单 —— 它们确实带 server', () {
      // 这是「阶段 1 加完 server 参数、prompt 却仍然禁止」那个遗漏的回归护栏。
      // 断言方式刻意从「全文 contains」改成「先抽出那句再检查成员」：
      // 旧断言只验字符串存在，名单里点了谁根本测不到，所以点错工具名能一路
      // 溜过（run_background/check_job/list_jobs 被列进去过）。
      final p = promptFor(multi: true);
      final line = noServerSentence(p);
      for (final name in const [
        'run_background',
        'check_job',
        'list_jobs',
      ]) {
        expect(line, isNot(contains('`$name`')),
            reason: '`$name` 带 server，却出现在「do NOT take server」里：$line');
      }
    });

    test('真不支持 server 的三个仍在名单里 —— 名单不能反向漏', () {
      // 上一条只证明了「不该有的没有」。不补这条的话，把名单整段删空也能
      // 让上一条通过，而 download_file/upload_file/set_plan 会失去「别传
      // server」的提示。两条一起才钉死：名单 == 单 {这三个}。
      // 判据见实现注释：这三个执行器里根本解析不到 server
      // （transfer_executors.dart 的 download/upload 走 opsProvider(null)；
      // agent_loop.dart 的 _executeSetPlan 只读 steps/current）。
      final line = noServerSentence(promptFor(multi: true));
      for (final name in const [
        'download_file',
        'upload_file',
        'set_plan',
      ]) {
        expect(line, contains('`$name`'),
            reason: '`$name` 确实不支持 server，必须留在禁止名单里：$line');
      }
    });

    test('名单被 has() 滤空时不输出残缺的「 and  do NOT take」', () {
      // `noServerNames` 三个都可能因未解锁被滤掉。空名单必须一条都不写：
      // 漏掉 length == 0 这一档就会拼出「\`\` and \`\` do NOT take ...」
      // 这种残句（还会白烧 token）。这里只放行 `bash`（跨机引导的触发条件
      // 是 hasOtherServers，与工具解锁无关），三个工具名一个都不 active。
      final p = buildAgentSystemPrompt(
        cwd: '/home/ops',
        terminalContext: null,
        tier: AgentToolTier.full,
        hasOtherServers: true,
        activeToolNames: {'bash'},
      );
      expect(p, isNot(contains('do NOT take `server`')));
      expect(p, isNot(contains('do NOT take')),
          reason: '空名单退化成残句：${noServerSentence(p)}');
      // 跨机那条正面引导仍在（它不依赖这三个工具解锁）——证明上面不是
      // 「整段都没输出」的假通过。
      expect(p, contains('list_servers'));
    });

    test('单机 prompt 确实更短', () {
      expect(promptFor(multi: false).length,
          lessThan(promptFor(multi: true).length));
    });

    test('其余 full 档引导不受影响', () {
      final p = promptFor(multi: false);
      expect(p, contains('edit_file'));
      expect(p, contains('run_background'));
      expect(p, contains('save_skill'));
    });
  });
}

// noServerSentence 已提取到 `_prompt_helpers.dart`：本文件与
// `agent_prompt_test.dart` 的通用守卫都要切同一句，各写一份的话措辞一变就
// 会有一份静默退化成「永远空串」。
