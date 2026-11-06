import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_groups.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

int bytes(String s) => utf8.encode(s).length;

/// full 档、所有组都没解锁时的工具名集合。
Set<String> lockedNames() => filterByUnlockedGroups(
        agentToolSpecsFor(AgentToolTier.full,
            hasSkills: true, hasOtherServers: true),
        const {})
    .map((s) => s.name)
    .toSet();

void main() {
  group('引导跟着工具走', () {
    test('工具没激活时，它的用法引导整段不出现', () {
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        tier: AgentToolTier.full,
        hasOtherServers: true,
        activeToolNames: lockedNames(),
      );
      expect(p, isNot(contains('upload_file')));
      expect(p, isNot(contains('download_file')));
      expect(p, isNot(contains('web_fetch')));
      expect(p, isNot(contains('copy_between_servers')));
    });

    test('激活后引导回来', () {
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        tier: AgentToolTier.full,
        hasOtherServers: true,
        activeToolNames: {...lockedNames(), 'upload_file', 'download_file'},
      );
      expect(p, contains('upload_file'));
      expect(p, contains('download_file'));
      expect(p, isNot(contains('web_fetch')));
    });

    test('core 工具的引导不受影响', () {
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        tier: AgentToolTier.full,
        hasOtherServers: true,
        activeToolNames: lockedNames(),
      );
      expect(p, contains('check_job'));
      expect(p, contains('run_background'));
      expect(p, contains('edit_file'));
    });

    test('prompt 里提到 more_tools，且说明了不要回绝用户', () {
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        tier: AgentToolTier.full,
        activeToolNames: lockedNames(),
      );
      expect(p, contains('more_tools'));
      expect(p.toLowerCase(), contains('cannot'),
          reason: '要写明「不要告诉用户你做不到」，这是最容易漏回来的失败模式');
    });

    test('activeToolNames 缺省时行为不变 —— 保护既有调用方', () {
      final p = buildAgentSystemPrompt(
          cwd: null, terminalContext: null, tier: AgentToolTier.full);
      expect(p, contains('upload_file'),
          reason: '不传这个参数时应当退回「全都发」，而不是「全都不发」');
    });
  });

  group('@ 引用语义条件化', () {
    test('本会话没出现过 @ 时，那四条整段消失', () {
      final p = buildAgentSystemPrompt(
        cwd: null, terminalContext: null, tier: AgentToolTier.full,
        hasAtReference: false,
      );
      expect(p, isNot(contains('A reference is a pointer')));
    });

    test('出现过 @ 时照常发', () {
      final p = buildAgentSystemPrompt(
        cwd: null, terminalContext: null, tier: AgentToolTier.full,
        hasAtReference: true,
      );
      expect(p, contains('A reference is a pointer'));
    });

    test('缺省为 true —— 漏传时保守地发，不让模型误解用户的 @', () {
      final p = buildAgentSystemPrompt(
          cwd: null, terminalContext: null, tier: AgentToolTier.full);
      expect(p, contains('A reference is a pointer'));
    });
  });

  group('文案压缩', () {
    test('EFFICIENCY 段压到 300 字节以内，但三层意思都在', () {
      final p = buildAgentSystemPrompt(
          cwd: null, terminalContext: null, tier: AgentToolTier.full);
      final start = p.indexOf('EFFICIENCY');
      expect(start, greaterThan(0));
      final end = p.indexOf('\n\n', start);
      final seg = p.substring(start, end);
      expect(bytes(seg), lessThan(300));
      // 三层意思：合并成一条命令 > 同一轮里并发 > 才拆到不同轮
      expect(seg.toLowerCase(), contains('single'));
      expect(seg.toLowerCase(), contains('same turn'));
    });

    test('「三处记忆」压到 200 字节以内，三个去处都还在', () {
      // 2026-10 第一处的载体从远端 ~/.flyterm/AGENTS.md 换成了 app 端的
      // `save_note` 工具（机器笔记落进 app 端 SQLite，见
      // agent_prompt.dart 里对应那段注释）——三处分界本身没变，只是第一处
      // 不再是「模型手动读写一个远端文件」，而是「调一个工具」。
      final p = buildAgentSystemPrompt(
        cwd: null, terminalContext: null, tier: AgentToolTier.full,
        activeToolNames: {'save_note', 'save_skill', 'bash'},
      );
      final start = p.indexOf('Three places');
      expect(start, greaterThan(0));
      final end = p.indexOf('\n', start);
      final seg = p.substring(start, end);
      expect(bytes(seg), lessThan(200));
      expect(seg, contains('save_note'));
      expect(seg, contains('save_skill'));
      expect(seg, contains('settings'));
    });
  });

  group('常驻体积基线', () {
    test('full 档、未解锁任何组时，system prompt + 工具定义 < 15800 字节', () {
      final specs = filterByUnlockedGroups(
          agentToolSpecsFor(AgentToolTier.full,
              hasSkills: true, hasOtherServers: true),
          const {});
      final toolsJson = jsonEncode(specs
          .map((s) => {
                'name': s.name,
                'description': s.description,
                'parameters': s.parameters,
              })
          .toList());
      final prompt = buildAgentSystemPrompt(
        cwd: '/var/www',
        terminalContext: null,
        tier: AgentToolTier.full,
        hasOtherServers: true,
        activeToolNames: specs.map((s) => s.name).toSet(),
        hasAtReference: false,
      );
      final total = bytes(prompt) + bytes(toolsJson);
      // 计划原稿这里写的是 7500，但那个数字本身就不可能达到：仅剩的 14 个
      // 常驻工具定义（more_tools 解锁后仍保留的那些，不含 6 个低频工具）
      // 单是 toolsJson 就有 ~7500B，system prompt 还没算进去。核对过 Task
      // 7/8/9 的三处 `if` 确实都在按预期生效（锁定态下 upload_file 等 6 个
      // 工具名与引导都不出现；@ 引用段随 hasAtReference 消失；EFFICIENCY /
      // 三处记忆两段确实被压缩），实测 total≈14791B。这与计划里另一处「5820
      // →4087 token（约 20349B→~14244B）」的目标换算基本吻合（20349B 对应
      // 5820 token，比例套到 4087 token 约等于 14244B），说明 14791B 才是
      // 优化后的真实体积，7500 是原稿的估算失误（很可能把"token"和"字节"
      // 换算错了），不是这一批改动的回归。
      //
      // 2026-10-14 重测收紧：跨机任务那一批（`run_background` / `check_job` /
      // `list_jobs`）给每个工具加了同一段 `server` 参数描述，`check_job` 一个
      // 就让 total 从 14791 涨到 15540。**这是有意的增量，不是悄悄膨胀**——
      // 参数说明每个工具都值得写全，否则模型漏报机器名。
      //
      // 上一版把阈值抬到 16000，理由是「三个工具加完预计 ~15800，故留到
      // 16000」——那是替后续改动预授权了增长，等于没测就放行。改为按实测收紧：
      //
      //   total 实测 15540（本次用 lessThan(1) 跑出来的
      //   system=7049 tools=8491）
      //   + `list_jobs` 加 server 的预估增量 185
      //   = 15725，再留 75 余量 → 15800
      //
      // 这个 185 是算出来的，不是拍的：`list_jobs` 本无必填参数，其
      // `parameters.properties` 为空对象（JSON 2B，即 `"{}"`）；加上 server 后为 218B，
      // 差值 185 = 逐字复用的描述文本 142B（与 `bash` / `run_background` /
      // `check_job` 里那段完全相同，见计划「文案与 bash 的 server 参数逐字一致」）
      // + JSON 结构包装（`"server":{"type":"string","description":""}`）43B。
      //
      // **2026-10-14 复核：`list_jobs` 加 server 已落地，total 仍是 15540，不会涨到 ~15725。**
      // 上面那句「应当涨到 ~15725，对不上就是增量来路不明」已经失效，原因不是
      // 增量丢了，而是**这道护栏看不见它**——本用例用
      // `filterByUnlockedGroups(specs, const {})` 测量，一个组都没解锁，而
      // `list_jobs` 属于 `jobs` 组（`tool_groups.dart:40`，组里只有它一个），
      // 于是被 `groupOf != null && !unlocked.contains(...)` 整条滤掉，对
      // 本次测量贡献 **0**。所以 `list_jobs` 的 `server` 描述**在测量之外**，
      // 别拿 15725 去对账。
      //
      // 这是这道护栏的**已知局限**，记在这里避免下次误判：跨机任务那批只给
      // `run_background` / `check_job` / `list_jobs` 三个加了 `server`，而三者
      // 只有前两个是 core 组（`groupOf == null`，常驻不被滤），它们的增量**是**
      // 被本护栏覆盖的（14791→15540 里，`check_job` 贡献主要部分）；三个里
      // 只有 `list_jobs` 因组门控漏掉。补第二套测量是后续项，不在本次范围。
      //
      // 「全局会话下 job 三件套可用」这项改动在本用例的配置下增量为 0：
      // 本测试压根没传 `requireExplicitServer`（只传 `hasOtherServers: true`），
      // `_withRequiredServer` 那条分支根本不进，`kSessionBoundToolNames`
      // 也不参与过滤。
      //
      // 顺带记下这项改动的实际形态（与早期推测相反）：job 三件套是**离开**
      // `kSessionBoundToolNames`、改走 `_withRequiredServer` 变必填，而不是
      // 「在全局会话下从工具清单消失」。所以全局会话下它们反而多出了一段
      // `server` 的必填描述——但那只影响 `requireExplicitServer: true`
      // 的配置，不在本用例测量范围内。
      expect(total, lessThan(15800),
          reason: 'system=${bytes(prompt)} tools=${bytes(toolsJson)}');
    });

    test('lean 档 < 6200 字节 —— 它本来就小，别让它涨', () {
      final specs = agentToolSpecsFor(AgentToolTier.lean, hasSkills: true);
      final toolsJson = jsonEncode(specs
          .map((s) => {
                'name': s.name,
                'description': s.description,
                'parameters': s.parameters,
              })
          .toList());
      final prompt = buildAgentSystemPrompt(
        cwd: '/var/www',
        terminalContext: null,
        tier: AgentToolTier.lean,
        activeToolNames: specs.map((s) => s.name).toSet(),
        hasAtReference: false,
      );
      // 实测 6142（system=3811 tools=2331），阈值 6200，只留 58 余量。
      //
      // 原先设的 7000 太松：破坏性验证时往常驻段塞了 1131 字节，full 档
      // 那条红了，这条却因为 6976 < 7000 差 24 字节漏了过去 —— 一条漏得过
      // 去的护栏等于没有护栏。
      expect(bytes(prompt) + bytes(toolsJson), lessThan(6200),
          reason: 'system=${bytes(prompt)} tools=${bytes(toolsJson)}');
    });
  });
}
