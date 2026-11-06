import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_groups.dart';

void main() {
  group('leanToolSpecs', () {
    test('只有 bash / read_file / read_terminal / ask_user', () {
      // read_terminal 也进 lean：它无参数（小模型没有可写坏的形状），而「看用户
      // 屏幕上已经有的东西」是排查的基础动作。
      //
      // ask_user 同样无条件进 lean（2026-09）：分叉这件事跟工具生态无关——
      // 小模型撞上「猜不出该走哪条路」不比大模型少，反而更需要一个「问」的
      // 出口。见 agent_tools.dart 里 askUserToolSpec 上方的注释。
      expect(leanToolSpecs.length, equals(4));
      expect(leanToolSpecs.map((t) => t.name),
          containsAll(['bash', 'read_file', 'read_terminal', 'ask_user']));
    });

    test('bash 要求 command 与 description', () {
      final bash = leanToolSpecs.firstWhere((t) => t.name == 'bash');
      final req = (bash.parameters['required'] as List).cast<String>();
      expect(req, containsAll(['command', 'description']));
    });

    test('read_file 只要求 path', () {
      final rf = leanToolSpecs.firstWhere((t) => t.name == 'read_file');
      expect((rf.parameters['required'] as List), equals(['path']));
    });

    test('每个工具的 parameters 都是 object schema', () {
      for (final t in leanToolSpecs) {
        expect(t.parameters['type'], equals('object'));
      }
    });

    // 这是本任务的**目的**：描述短。行为约束搬到 system prompt 里说一次，
    // 不在每个工具的描述里重复一遍。
    test('工具描述保持精简', () {
      final bash = leanToolSpecs.firstWhere((t) => t.name == 'bash');
      expect(bash.description.length, lessThan(200),
          reason: 'bash 描述原来 1200+ 字符，约束已搬进 system prompt');

      final rf = leanToolSpecs.firstWhere((t) => t.name == 'read_file');
      expect(rf.description.length, lessThan(200));

      final total =
          leanToolSpecs.fold<int>(0, (s, t) => s + t.description.length);
      // 三个工具的描述合计原来约 265 字符；ask_user 加入后实测约 388 字符。
      //
      // 它的初版描述有 261 字符（把「什么时候该问」的边界也写了进去），会让
      // 合计到 526。按本文件顶部那条原则，那属于会话级行为准则、该放 system
      // prompt，于是精简到 123 字符——边界说明移到 `agent_prompt.dart` 的
      // `ask_user` 引导里。400 这条线只为新增一个工具留出必要余量，**不是**
      // 放宽了描述标准。
      expect(total, lessThan(400),
          reason: '三个工具的描述合计原来约 265 字符，ask_user 加入后约 526');
    });
  });

  group('fullToolSpecs', () {
    test('是 lean 加写/计划/后台/传输/查询/搜索/取网页工具，一个不多一个不少', () {
      // 断言的是**完整名字集合**，不是数量——数量是名字集合的推论，锁数量
      // 反而是锁了一个每加一个工具就必然要改的魔数（历史上已经改过好几轮：
      // 7 -> 9 -> 10 -> 11 -> 12 -> 14 -> 15，见 git blame）。unorderedEquals
      // 同时验证「没漏」与「没多」，且加新工具时报错信息直接是名字差异，
      // 比一个数字变了更好定位。
      expect(
          fullToolSpecs.map((t) => t.name),
          unorderedEquals([
            'bash',
            'read_file',
            'read_terminal',
            'ask_user',
            'write_file',
            'edit_file',
            'set_plan',
            'run_background',
            'check_job',
            'list_jobs',
            'download_file',
            'upload_file',
            'list_servers',
            'copy_between_servers',
            'glob',
            'grep',
            'web_fetch',
          ]));
    });

    test('lean 档里没有写文件工具', () {
      final names = leanToolSpecs.map((t) => t.name).toSet();
      expect(names.contains('write_file'), isFalse);
      expect(names.contains('edit_file'), isFalse);
    });

    test('write_file 的必填参数', () {
      final t = fullToolSpecs.firstWhere((t) => t.name == 'write_file');
      expect((t.parameters['required'] as List).cast<String>(),
          containsAll(['path', 'content', 'description']));
    });

    test('edit_file 的必填参数', () {
      final t = fullToolSpecs.firstWhere((t) => t.name == 'edit_file');
      expect((t.parameters['required'] as List).cast<String>(),
          containsAll(['path', 'old_string', 'new_string', 'description']));
    });

    test('set_plan 只必填 steps', () {
      final t = fullToolSpecs.firstWhere((t) => t.name == 'set_plan');
      expect((t.parameters['required'] as List), equals(['steps']));
      final steps = t.parameters['properties']['steps'] as Map;
      expect(steps['type'], equals('array'));
    });

    // 真机回归（2026-09-08，full 档 + bypass）：用户 `@` 一个上传类技能，模型
    // 本轮 0 次调用，改用自然语言回「请在你的手机上选择要上传的截图」，用户
    // 以为文件选择器坏了。
    //
    // 当时的描述是「The user picks which file — you only choose the
    // destination」。这句本身没错，但小模型的合理推论就是「那我得先让用户
    // 挑」。system prompt 里有纠正，可它只有一份、离调用决策远，而工具描述
    // 每轮随定义重发、紧贴决策点 —— 两者冲突时贴得近的赢。
    //
    // 这条守的是「描述里讲了调用时机」，不是某个具体措辞。谁要为省 token 把
    // 它删回去，先读上面这段。
    test('upload_file 的描述必须讲清调用时机，不能只说「用户挑文件」', () {
      final t = fullToolSpecs.firstWhere((t) => t.name == 'upload_file');
      final d = t.description.toLowerCase();
      expect(d, contains('at once'),
          reason: '要明确「立刻调」，否则模型会先用自然语言跟用户收集参数');
      expect(d, contains('never ask'),
          reason: '要显式禁止「请先选择文件」这类回应');
      expect(d, contains('picker'),
          reason: '要说清机制：调用工具会弹选择器，那就是用户选文件的方式');
    });

    test('全部工具描述合计仍然精简', () {
      final total =
          fullToolSpecs.fold<int>(0, (s, t) => s + t.description.length);
      // download_file / upload_file 加入后合计约 1167 字符；copy_between_servers
      // 加入后实测约 1630 字符；glob / grep 加入后实测 1888 字符；web_fetch
      // 加入后实测 1975 字符；ask_user 加入后实测 2239 字符。
      //
      // 1900 这条线是历史参照：早先 bash 与 read_file 两个工具的描述合计就是
      // 1900，那时的教训是「行为准则不要写进工具描述」（每轮重发 N 份，而
      // system prompt 只有一份）。
      //
      // 上限从 2000 抬到 2150（2026-09）**不是放宽标准，是工具数从 19 涨到
      // 21**。ask_user 的初版描述有 261 字符（把「什么时候该问」的边界写了
      // 进去），那会让合计到 2239；按本文件顶部那条原则，边界属于会话级行为
      // 准则、该放 system prompt，精简到 123 字符后合计 2101。
      //
      // 全表最长仍是 copy_between_servers（289 字符，它那段退路说明有一半
      // 属于 system prompt——那条才是「该精简」的典型，只是没人动过它）。
      expect(total, lessThan(2150),
          reason: 'full 档全部工具的描述合计不该大幅超过 ask_user 加入后的 2239 字符');
    });

    test('单个工具的描述平均长度可控', () {
      // 与上面那条互补：总长必然随工具数线性增长，锁总长早晚会因为「又加了
      // 一个工具」而红，那不是它想防的事。平均长度才是「描述要短」这件事的
      // 可持续指标，加工具不会让它漂移。
      final total =
          fullToolSpecs.fold<int>(0, (s, t) => s + t.description.length);
      expect(total / fullToolSpecs.length, lessThan(160),
          reason: '实测约 135 字符/个；超过 160 说明有工具在描述里写行为准则');
    });

    test('run_background / check_job 只在 full 档出现', () {
      final lean = agentToolSpecsFor(AgentToolTier.lean).map((t) => t.name);
      final full = agentToolSpecsFor(AgentToolTier.full).map((t) => t.name);

      expect(lean, isNot(contains('run_background')));
      expect(lean, isNot(contains('check_job')));
      expect(full, contains('run_background'));
      expect(full, contains('check_job'));
    });

    test('full 档 + 多机 + (可选)有技能 时的完整工具名集合，仍在模型选择准确率的安全区内',
        () {
      // 断言名字集合而不是数量：数量是名字集合的推论，且每加一个工具这个
      // 数字就必须跟着改一次（历史上已经改了好几轮：7 -> 9 -> 10 -> 11 ->
      // 12 -> 14 -> 15 -> 16，见 git blame）。save_skill 恒进 full 档、不随
      // hasSkills 变——一个技能都没有的时候恰恰最需要它（同一理由见
      // agent_tools.dart 里 agentToolSpecsFor 上方的注释）。hasSkills: true
      // 时再加上 load_skill。
      //
      // `hasOtherServers: true` 是必需的：默认 false 时 `list_servers` 与
      // `copy_between_servers` 不声明（单机下它们必然失败）。这条测试量的
      // 是「全档到底有哪些工具」，所以要在多机档下量。单机档由
      // `agent_single_server_test.dart` 守着。
      final baseNames = fullToolSpecs.map((t) => t.name);

      final withoutSkills =
          agentToolSpecsFor(AgentToolTier.full, hasOtherServers: true)
              .map((t) => t.name);
      // `more_tools` 与 `save_skill` 一样恒进 full 档：它是低频工具的唯一
      // 入口，自己被锁住就没人能解锁任何东西了。
      // SFTP 六件套恒进 full 档（与 save_skill / more_tools 同列）：它们
      // 操作远端文件，和 write_file 同类，不随 app 控制开关变。真正影响
      // 模型选择面的是 core 大小，见下一条测试。
      const sftpNames = [
        'sftp_list',
        'sftp_stat',
        'sftp_mkdir',
        'sftp_rename',
        'sftp_remove',
        'sftp_chmod',
      ];
      expect(
          withoutSkills,
          unorderedEquals([
            ...baseNames,
            'save_skill',
            // `save_note` 恒进 full 档，与 `save_skill` 同理由：一台机器都没
            // 记过笔记的时候恰恰最需要它——不该等 hasSkills/hasOtherServers
            // 才出现。
            'save_note',
            'more_tools',
            ...sftpNames,
          ]));

      final withSkills = agentToolSpecsFor(AgentToolTier.full,
              hasSkills: true, hasOtherServers: true)
          .map((t) => t.name);
      expect(
          withSkills,
          unorderedEquals([
            ...baseNames,
            'save_skill',
            'save_note',
            'more_tools',
            'load_skill',
            'install_skill_assets',
            ...sftpNames,
          ]));
    });

    // 全集会随功能增长，但**模型每轮实际看到的**不该跟着涨 —— 那才是
    // 「选择准确率安全区」的真正含义。on-demand 的工具用到才解锁，不占
    // 每轮的选择面。
    //
    // 开了 app 控制后全集从 26 涨到 44，而 core 只从 14 涨到 15（多的是
    // `app_state_read`，它是所有 app 操作的前置）。这条测试守的就是这个
    // 比例：往 app_config / app_session / sftp 组里加工具不会让它变红，
    // 但把工具直接挂进 core 会。
    test('core 工具数不随功能增长 —— on-demand 的不占每轮选择面', () {
      List<String> coreOf({required bool hasAppControl}) =>
          filterByUnlockedGroups(
            agentToolSpecsFor(AgentToolTier.full,
                hasSkills: true,
                hasOtherServers: true,
                hasAppControl: hasAppControl),
            const {},
          ).map((s) => s.name).toList();

      expect(coreOf(hasAppControl: false), hasLength(15));
      final withApp = coreOf(hasAppControl: true);
      expect(withApp, hasLength(16));
      expect(withApp, contains('app_state_read'));
      // 写操作一个都不该常驻
      for (final w in [
        'app_settings_set',
        'ssh_key_generate',
        'saved_command_create',
        'sftp_remove',
        'navigate_to',
      ]) {
        expect(withApp, isNot(contains(w)), reason: '$w 不该常驻 core');
      }
    });

    test('check_job 的 wait 有上限说明，参数齐全', () {
      final spec = fullToolSpecs.firstWhere((t) => t.name == 'check_job');
      final props = spec.parameters['properties'] as Map;
      expect(props.keys, containsAll(['job_id', 'since_line', 'wait']));
      expect(spec.parameters['required'], equals(['job_id']));
    });

    test('run_background 要求 description——审批卡靠它渲染', () {
      final spec = fullToolSpecs.firstWhere((t) => t.name == 'run_background');
      expect(spec.parameters['required'], containsAll(['command', 'description']));
    });
  });

  group('resolveToolTier', () {
    test('Ollama 判为 lean', () {
      expect(resolveToolTier(providerType: 'ollama'),
          equals(AgentToolTier.lean));
    });

    test('云端 provider 判为 full', () {
      expect(resolveToolTier(providerType: 'openai'),
          equals(AgentToolTier.full));
      expect(resolveToolTier(providerType: 'anthropic'),
          equals(AgentToolTier.full));
      expect(resolveToolTier(providerType: 'gemini'),
          equals(AgentToolTier.full));
    });

    test('未知 provider 类型判为 full（保守取可用，不保守取能力）', () {
      expect(resolveToolTier(providerType: 'whatever'),
          equals(AgentToolTier.full));
    });

    test('手动覆盖优先于自动判定', () {
      expect(
        resolveToolTier(providerType: 'ollama', override: AgentToolTier.full),
        equals(AgentToolTier.full),
      );
      expect(
        resolveToolTier(providerType: 'openai', override: AgentToolTier.lean),
        equals(AgentToolTier.lean),
      );
    });
  });

  group('agentToolSpecsFor', () {
    // 旧断言用 same() 守「不拷贝、直接返回常量引用」。新实现里函数体恒是
    // `[...base, if (...) ..., if (...) ...]`——list 字面量的 spread 恒
    // 分配一个新数组，不管两个 if 是否命中，所以恒不是同一个引用。full
    // 档还额外必然失效：save_skill 恒被追加，返回值恒比 fullToolSpecs 多
    // 一个工具，identical 在这里从「验证正确性」退化成「验证一个必然为假
    // 的命题」，没有再守的价值，直接删掉。
    //
    // 还活着的那部分不变量是：hasSkills: false 时，lean 档返回的“内容”
    // 应该和 leanToolSpecs 完全一致（技能相关的追加逻辑不该污染它）。改用
    // 内容相等来守这件事，identical 已知恒为 false 就不再断言。
    test('lean 档在无技能时，内容与 leanToolSpecs 一致', () {
      final result = agentToolSpecsFor(AgentToolTier.lean);
      expect(result, isNot(same(leanToolSpecs)));
      expect(result.map((t) => t.name), equals(leanToolSpecs.map((t) => t.name)));
    });
  });

  test('full 档含两个传输工具，lean 档没有', () {
    final full = fullToolSpecs.map((t) => t.name).toList();
    expect(full, contains('download_file'));
    expect(full, contains('upload_file'));

    final lean = leanToolSpecs.map((t) => t.name).toList();
    expect(lean, isNot(contains('download_file')));
    expect(lean, isNot(contains('upload_file')));
  });

  test('download_file 只要 remote_path + description', () {
    final spec = fullToolSpecs.firstWhere((t) => t.name == 'download_file');
    final required = spec.parameters['required'] as List;
    expect(required, containsAll(['remote_path', 'description']));
    final props = spec.parameters['properties'] as Map;
    expect(props.keys, containsAll(['remote_path', 'description']));
  });

  test('upload_file 收的是目录，不是文件路径', () {
    final spec = fullToolSpecs.firstWhere((t) => t.name == 'upload_file');
    final props = spec.parameters['properties'] as Map;
    expect(props.containsKey('remote_dir'), isTrue,
        reason: '参数名必须是 remote_dir —— 让「这是目录」在名字上就成立');
    // 描述里必须明说本地文件由用户选，否则模型会试图编一个本地路径参数。
    expect(spec.description.toLowerCase(), contains('user'));
  });

  group('copy_between_servers', () {
    test('只进 full 档', () {
      expect(fullToolSpecs.map((t) => t.name),
          contains('copy_between_servers'));
      expect(leanToolSpecs.map((t) => t.name),
          isNot(contains('copy_between_servers')));
    });

    test('必填三个参数，dest_path 可选', () {
      final spec =
          fullToolSpecs.firstWhere((t) => t.name == 'copy_between_servers');
      final required = spec.parameters['required'] as List;
      expect(required,
          containsAll(['from_server', 'to_server', 'remote_path', 'description']));
      expect(required, isNot(contains('dest_path')));
      final props = spec.parameters['properties'] as Map;
      expect(props.containsKey('dest_path'), isTrue);
    });

    test('描述里写明 100 MB 上限与 scp 退路 —— 否则模型会拿它传大文件然后反复撞墙',
        () {
      final spec =
          fullToolSpecs.firstWhere((t) => t.name == 'copy_between_servers');
      expect(spec.description, contains('100'));
      expect(spec.description.toLowerCase(), contains('scp'));
    });
  });
}
