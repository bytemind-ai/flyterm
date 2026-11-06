// SPDX-License-Identifier: GPL-3.0-or-later
import 'tool_models.dart';

/// Agent 模式提供给模型的工具声明。
///
/// 工具数恒定，不随生态（k8s / docker / …）增长 —— 那条路会让工具表爆炸并
/// 伤害模型的选择准确率，且永远追不上真实排查手段的多样性。
///
/// ## 描述为什么这么短
///
/// 早先 `bash` 的描述有 1200+ 字符（约 345 token），装着 5 条行为约束：禁
/// 交互式命令、限制输出、加 `--no-pager`、优先聚合命令、截断提示。**这些是
/// 会话级的行为准则，不是这个工具的用法**，放在 system prompt 里说一次就够。
///
/// 工具定义每一轮都要重发，把准则写在这里等于每轮重复付费。短描述对小模型
/// 另有好处：长描述稀释注意力，反而更容易选错工具。
const List<ToolSpec> leanToolSpecs = [
  ToolSpec(
    name: 'bash',
    description: 'Run a non-interactive shell command on the remote server. '
        'Returns stdout, stderr and exit code.',
    parameters: {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'The exact shell command to run.',
        },
        'description': {
          'type': 'string',
          'description': "One short sentence, in the user's language, "
              'saying what this is for. Shown on the approval card.',
        },
        'server': {
          'type': 'string',
          'description': 'Optional. Exact name of another saved server to run '
              'this on. Omit to use the current session. Call `list_servers` '
              'first if you need the names.',
        },
      },
      'required': ['command', 'description'],
    },
  ),
  ToolSpec(
    name: 'read_file',
    description: 'Read a text file from the remote server with pagination. '
        'Returns at most 200 lines per call unless you raise `limit`.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Absolute path to the file.'},
        'offset': {
          'type': 'integer',
          'description': 'Line number to start from (1-based). Default 1.',
        },
        'limit': {
          'type': 'integer',
          'description': 'Maximum number of lines to read. Default 200.',
        },
        'server': {
          'type': 'string',
          'description': 'Optional. Exact name of another saved server to read '
              'from. Omit to use the current session.',
        },
      },
      'required': ['path'],
    },
  ),
  // 进 lean 档：无参数（小模型没有可写坏的形状），而「看用户屏幕上已经有的
  // 东西」是排查的基础动作，不是高级功能。
  //
  // system prompt 里那份终端内容是 loop 创建时的一次性快照，可能已经是几十条
  // 命令之前的了（见 terminal_screen.dart 里关于 prompt cache 断点的说明）。
  // 这个工具是模型拿到**此刻**屏幕的唯一途径。
  // 描述只说用法，不写「别重跑用户已经看得见输出的命令」那条准则 —— 那是会话
  // 级行为约束，按本文件顶部的原则归 system prompt，写在这里等于每轮重复付费。
  ToolSpec(
    name: 'read_terminal',
    description: "Read what is on the user's terminal screen right now.",
    parameters: {
      'type': 'object',
      'properties': <String, Object?>{},
    },
  ),
  // 无条件进 lean：与 load_skill（依赖用户有技能）不同，分叉这件事跟工具
  // 生态无关——小模型撞上「猜不出该走哪条路」的频率不比大模型低，反而更
  // 需要一个「问」的出口，否则退化成瞎猜。定义见下方 [askUserToolSpec]。
  askUserToolSpec,
];

/// 工具分档。
///
/// 本地小模型给五个工具会明显变差：工具越多选择越容易出错，而 `write_file`
/// / `edit_file` 的参数（整份内容、精确的 old_string）恰恰是小模型最容易
/// 写坏的形状。lean 档不是「阉割」，是把它做得对的那部分留下。
///
/// `run_background` / `check_job` 同样只进 full 档：job 生命周期要求模型
/// 记住一个 id 并在正确的时机回来查看，小模型在这上面翻车的代价不是「这一
/// 轮白费」，而是在用户服务器上留下一堆没人收的孤儿进程。
enum AgentToolTier { lean, full }

/// 决定用哪一档。
///
/// [override] 是**唯一**的兜底，且必须有：按 provider 判定必然误判「用
/// OpenAI 兼容端点跑本地小模型」这一种极常见的配置，而那种配置从 wire
/// format 上完全看不出来。
///
/// 未知类型判 full：未知大概率是新的云端服务，判错的代价是「小模型上工具
/// 太多」（用户能自己改档），反过来判 lean 的代价是「云端模型莫名少了三个
/// 工具」（用户不知道有档位这回事，只会觉得功能缺了）。
AgentToolTier resolveToolTier({
  required String providerType,
  AgentToolTier? override,
}) =>
    override ?? (providerType == 'ollama' ? AgentToolTier.lean : AgentToolTier.full);

/// `grep` / `glob` 单次返回的行数上限。
///
/// 这个上限就是那两个工具存在的全部意义，所以它必须由实现保证、不能开放成
/// 参数：模型自己在 `bash` 里加 `| head` 会因为管道是元字符而弹审批卡，不加
/// 则输出完全不设限、随手撞上 8 KiB 截断把要找的那几行挤到尾巴外面。
///
/// 100 行按每行 80 字符估算约 8 KiB，正好压在输出截断线附近 —— 再大就是在
/// 为一份必然被截掉尾巴的结果付钱。命中上限时模型该做的是缩小 pattern。
///
/// 放在这里而不是 `agent_loop.dart`：它是工具契约的一部分（写进了工具描述
/// 和 system prompt），不是执行细节。`agent_prompt.dart` 也要读它，而那个
/// 文件本来就 import 这里。
const int kSearchResultLimit = 100;

/// full 档新增的工具。
///
/// 描述一律短，理由同 [leanToolSpecs] 上方那段：约束写在 system prompt 里。
const List<ToolSpec> _extraFullToolSpecs = [
  ToolSpec(
    name: 'write_file',
    description: 'Create or overwrite a text file on the remote server. '
        'Always requires the user to approve. Max 6 KiB.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Absolute path to write.'},
        'content': {
          'type': 'string',
          'description': 'The complete new contents of the file.',
        },
        'description': {
          'type': 'string',
          'description': "One short sentence, in the user's language, "
              'saying what this writes and why. Shown on the approval card.',
        },
        'server': {
          'type': 'string',
          'description': 'Optional. Exact name of another saved server to '
              'write on. Omit to use the current session.',
        },
      },
      'required': ['path', 'content', 'description'],
    },
  ),
  ToolSpec(
    name: 'edit_file',
    description: 'Replace one exact block of text in an existing file. '
        '`old_string` must appear EXACTLY once — include surrounding lines to '
        'make it unique. Always requires approval. Max 6 KiB.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Absolute path to edit.'},
        'old_string': {
          'type': 'string',
          'description': 'Exact text to replace, including whitespace.',
        },
        'new_string': {
          'type': 'string',
          'description': 'Replacement text. Empty string deletes.',
        },
        'description': {
          'type': 'string',
          'description': "One short sentence, in the user's language, "
              'saying what this changes and why. Shown on the approval card.',
        },
        'server': {
          'type': 'string',
          'description': 'Optional. Exact name of another saved server to '
              'write on. Omit to use the current session.',
        },
      },
      'required': ['path', 'old_string', 'new_string', 'description'],
    },
  ),
  // grep / glob 存在的理由不是「bash 干不了」——是 bash 干这件事时会撞上
  // 两条互相矛盾的约束。
  //
  // system prompt 硬要求每条命令都限制输出（`head` / `-n`），而 `|` 是
  // `hasShellMetachar` 里的元字符：`grep -rn x /var/log | head -50` 因此
  // 必然弹审批卡。反过来不带管道的 `grep -rn x /var/log` 命中默认规则里的
  // `grep *` 免审批，但输出完全不设上限，随手就能撞上 8 KiB 截断，把真正
  // 需要的那几行挤到尾巴外面。**限制输出与免审批在 bash 上是互斥的。**
  //
  // find 更直接：`find *` 被明确排除在默认放行清单外（理由见
  // permission_rules.dart —— `find /tmp -exec rm -rf {} +` 不含元字符却匹配
  // 那个前缀），所以按名字找文件每次都要用户点一下。
  //
  // 这两个工具把上限做进实现里：模型只给 pattern 和 path，管道由我们拼，
  // 判定走 `cat <path>`（与 read_file 同一口径，不留绕过规则的后门）。
  ToolSpec(
    name: 'glob',
    description: 'Find files by name pattern on the remote server. '
        'Returns at most 100 paths.',
    parameters: {
      'type': 'object',
      'properties': {
        'pattern': {
          'type': 'string',
          'description': "Filename pattern, e.g. '*.conf' or 'nginx*'. "
              'Matched against the file name only, not the whole path.',
        },
        'path': {
          'type': 'string',
          'description': 'Directory to search under. Defaults to the working '
              'directory.',
        },
        'server': {
          'type': 'string',
          'description': 'Optional. Exact name of another saved server to '
              'search on. Omit to use the current session.',
        },
      },
      'required': ['pattern'],
    },
  ),
  ToolSpec(
    name: 'grep',
    description: 'Search file contents by regular expression on the remote '
        'server. Returns at most 100 matching lines, each prefixed with '
        'file:line.',
    parameters: {
      'type': 'object',
      'properties': {
        'pattern': {
          'type': 'string',
          'description': 'Basic regular expression to search for.',
        },
        'path': {
          'type': 'string',
          'description': 'File or directory to search. Directories are '
              'searched recursively. Defaults to the working directory.',
        },
        'include': {
          'type': 'string',
          'description': "Optional. Only search files whose name matches this "
              "pattern, e.g. '*.log'.",
        },
        'server': {
          'type': 'string',
          'description': 'Optional. Exact name of another saved server to '
              'search on. Omit to use the current session.',
        },
      },
      'required': ['pattern'],
    },
  ),
  ToolSpec(
    name: 'set_plan',
    // 「每完成一步再调一次」必须明写。早先只说了「每次发整个列表」，模型
    // 据此理解为「开局公布一次计划」，`current` 从此停在 0 —— 清单变成一张
    // 静态海报，而它唯一的价值是回答「现在做到哪了」。用户实测时得在对话里
    // 手动教模型推进，那说明缺的是工具描述而不是模型能力。
    description: 'Show the user your step list for a long investigation. '
        'Re-send the WHOLE list after finishing EACH step, advancing '
        '`current`; set it to the list length when all done.',
    parameters: {
      'type': 'object',
      'properties': {
        'steps': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'All steps, in order. Keep each one short.',
        },
        'current': {
          'type': 'integer',
          'description': 'Index (0-based) of the step you are on now. '
              'Steps before it render as done; equal to the list length '
              'means everything is finished.',
        },
      },
      'required': ['steps'],
    },
  ),
  ToolSpec(
    name: 'run_background',
    description: 'Start a long-running command in the background and return '
        'immediately with a job id. Use for anything over ~15s.',
    parameters: {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'The exact shell command to run in the background.',
        },
        'description': {
          'type': 'string',
          'description': "One short sentence, in the user's language, "
              'saying what this is for. Shown on the approval card.',
        },
        'server': {
          'type': 'string',
          'description': 'Optional. Exact name of another saved server to run '
              'this on. Omit to use the current session. Call `list_servers` '
              'first if you need the names.',
        },
      },
      'required': ['command', 'description'],
    },
  ),
  ToolSpec(
    name: 'check_job',
    description: 'Wait for and read new output from a background job. Blocks '
        'on the server until there is new output or the job ends.',
    parameters: {
      'type': 'object',
      'properties': {
        'job_id': {
          'type': 'string',
          'description': 'The id returned by `run_background`.',
        },
        'since_line': {
          'type': 'integer',
          'description': 'Line number you have already read up to. Pass the '
              '`lines` value from the previous check. Default 0.',
        },
        'wait': {
          'type': 'integer',
          'description': 'Seconds to wait for new output before returning, '
              '0-60. Prefer a large value: each call resends the whole '
              'conversation, so waiting longer is cheaper than polling.',
        },
        'server': {
          'type': 'string',
          'description': 'Optional. Exact name of another saved server to run '
              'this on. Omit to use the current session. Call `list_servers` '
              'first if you need the names.',
        },
      },
      'required': ['job_id'],
    },
  ),
  ToolSpec(
    name: 'list_jobs',
    description: "List background jobs on this server (id, status, log "
        "size). Use when you've lost a job id.",
    parameters: {
      'type': 'object',
      'properties': {
        // **与 `bash` 那段逐字一致**，不是凑巧写得像：工具定义每轮重发，
        // 同一句话写四遍就等于四倍付费。四件套（bash/run_background/
        // check_job/list_jobs）共用同一段文本，改一处就该四处一起改。
        'server': {
          'type': 'string',
          'description': 'Optional. Exact name of another saved server to run '
              'this on. Omit to use the current session. Call `list_servers` '
              'first if you need the names.',
        },
      },
    },
  ),
  ToolSpec(
    name: 'download_file',
    description: 'Copy a file from the remote server to the user\'s phone. '
        'Always requires the user to approve. The file lands in their '
        'Downloads folder; its contents are NOT shown to you.',
    parameters: {
      'type': 'object',
      'properties': {
        'remote_path': {
          'type': 'string',
          'description': 'Absolute path of the file to copy down.',
        },
        'description': {
          'type': 'string',
          'description': "One short sentence, in the user's language, "
              'saying what this is for. Shown on the approval card.',
        },
      },
      'required': ['remote_path', 'description'],
    },
  ),
  ToolSpec(
    name: 'upload_file',
    // 这条描述必须讲清**调用时机**，不能只讲「谁挑文件」。
    //
    // 原文案是「The user picks which file — you only choose the destination」。
    // 真机（2026-09-08，full 档 + bypass）实测：用户 `@` 一个上传类技能，模型
    // 一个工具都没调（本轮 0 次调用），改用自然语言回「请在你的手机上选择要
    // 上传的截图，我会把它传到 X 目录」—— 用户以为文件选择器坏了。
    //
    // 「用户挑文件」这句话本身没错，但它在小模型那里的合理推论就是「那我得
    // 先让用户挑」。system prompt 里有一条纠正（`Call it as soon as...`），
    // 可 system prompt 只有一份、离调用决策很远，而工具描述每轮随定义重发、
    // 紧贴决策点，方向却是相反的。两者冲突时贴得近的那份赢。
    //
    // 本文件顶部的原则是「行为约束写 system prompt，别写进工具描述」，这条
    // 不违反它：**「什么时候该调这个工具」属于工具描述的职责**（`web_fetch`
    // 的设计也是同一句：工具描述是给「该不该调这个工具」用的）。多出的
    // 几十 token 换掉一次「用户以为功能坏了」是划算的。
    // 字数受 `全部工具描述合计仍然精简` 那条断言约束（上限 2000）。第一版写
    // 到 362 字符直接把总数顶到 2169，按那条注释自己的规矩「红了不是让你调高
    // 上限，是让你先去精简描述」压回 185：删掉「你只选目的地」（`remote_dir`
    // 的参数说明里已经写了）和「你看不到他们的文件系统」（与「别先问」同义）。
    description: 'Send a phone file to a remote directory. Call it at once — '
        'a picker opens on the phone, that is how they choose; never ask '
        'them to name a file first. Always requires the user to approve.',
    parameters: {
      'type': 'object',
      'properties': {
        'remote_dir': {
          'type': 'string',
          'description': 'Absolute path of the destination DIRECTORY. '
              'It must already exist.',
        },
        'description': {
          'type': 'string',
          'description': "One short sentence, in the user's language, "
              'saying what this is for. Shown on the approval card.',
        },
      },
      'required': ['remote_dir', 'description'],
    },
  ),
  ToolSpec(
    name: 'list_servers',
    description: 'List the servers saved on this device. Use it before '
        'passing `server` to another tool. `creds_ok: false` means this app '
        'cannot connect there on its own — do not target those.',
    parameters: {
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  ),
  ToolSpec(
    name: 'copy_between_servers',
    // 上限与退路必须留在这里（有测试守着）：模型拿它传大文件然后反复撞墙
    // 是踩过的坑，而 system prompt 那份说明只在 `hasOtherServers` 分支里，
    // 靠它兜底不够稳。
    //
    // 删掉的是两段真正属于别处的话：「中转所以两台机器不必互通」那句展开
    // 在 agent_prompt.dart 里有完整版，这里留个 relaying 足够；「需要用户
    // 批准」是系统行为——审批由 tool_registry 强制执行，模型知不知道都一样，
    // 写进来只是每轮多发一遍。
    description: 'Copy one file between two saved servers, relaying through '
        'the phone. Max 100 MB — above that, run `scp` on the source host '
        'via `bash`.',
    parameters: {
      'type': 'object',
      'properties': {
        'from_server': {
          'type': 'string',
          'description': 'Exact name of the source server.',
        },
        'to_server': {
          'type': 'string',
          'description': 'Exact name of the destination server.',
        },
        'remote_path': {
          'type': 'string',
          'description': 'Absolute path of the file on the source server.',
        },
        'dest_path': {
          'type': 'string',
          'description': 'Absolute path on the destination server. Omit to '
              'use the same path as the source.',
        },
        'description': {
          'type': 'string',
          'description': "One short sentence, in the user's language, "
              'saying what this is for. Shown on the approval card.',
        },
      },
      'required': ['from_server', 'to_server', 'remote_path', 'description'],
    },
  ),
  // ## 为什么只进 full 档
  //
  // `via` 的语义（内网走远端、公网走手机）对本地小模型太抽象 —— 而 lean 档
  // 的准入标准正是「最不容易写坏的形状」（`load_skill` 进 lean 是因为「一个
  // 名字」）。`resolveWebTarget` 已经让 `via` 在绝大多数情况下不必填，但填错
  // 的代价是取不到，而 lean 档用户（Ollama）恰恰最可能在没有外网的内网环境
  // 里用。
  //
  // ## 为什么没有 headers / method / body
  //
  // `headers` 会把这个工具从「取公开内容」变成任意 HTTP 客户端：模型能把
  // `Authorization: Bearer <用户的 token>` 发给任意站点。而凭据边界是本项目
  // 里唯一连 bypass 都覆盖不了的一条，不该从侧门被打开。
  //
  // `method`/`body` 意味着 POST，那是写操作，要重做 `checkFileWrite` 那一整套
  // 提案/审批语义。「调这个 API 触发重启」应该走 `bash curl`，正常地弹卡。
  ToolSpec(
    name: 'web_fetch',
    description: 'Fetch the text of a web page or HTTP endpoint. GET only. '
        'Returns at most 8 KiB of text.',
    parameters: {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description': 'Full URL. http and https only.',
        },
        'via': {
          'type': 'string',
          'enum': ['phone', 'server'],
          'description': 'Optional. Where to fetch from. Omit and FlyTerm '
              'picks: private addresses go through the server, public ones '
              "through the phone. Pass 'server' when the phone has no "
              'internet access.',
        },
      },
      'required': ['url'],
    },
  ),
];

const List<ToolSpec> fullToolSpecs = [...leanToolSpecs, ..._extraFullToolSpecs];

/// 向用户提问。**无条件声明**（不像 `load_skill` 依赖用户有技能）：小模型同样
/// 会遇到分叉，而且它更需要问而不是猜。
///
/// ## 描述里只有用法，没有「什么时候该问」
///
/// 初版把边界也写进了描述（「只在猜错代价高且跑命令查不到时才用」），描述长
/// 261 字符、把两条上限都撑破了。按本文件顶部那条原则，那两句是**会话级行为
/// 准则而不是这个工具的用法**，属于 system prompt——工具定义每轮重发，写在这里
/// 等于每轮重复付费，而且长描述会稀释小模型的注意力。
///
/// 边界说明在 `agent_prompt.dart` 的 `ask_user` 引导里（「先查再问」那两条）。
/// **改这里之前先确认那边还在**——两处同时缺失会让模型退化成「猜不出就问」。
///
/// 留下的两句都是用法：「给具体选项」定义了这个工具是什么，「选项要短到能
/// 放进按钮」约束选项的形状——否则模型会问出「请描述你的需求」这种要长篇
/// 作答的问题，而免掉打字正是这个工具存在的主要意义。
///
/// **不能再说「用户不打字」。** 那句话在自由输入上线（`ask_executors.dart`
/// 的 free-form 分支）之前是对的，现在是错的——用户在清单里始终能点开一个
/// 输入框自己打字，而这句每轮都发给模型，写错了就是每轮都在撒谎。约束改成
/// 只讲选项本身的形状（短到能放进按钮），不再对用户的行为下断言。
const ToolSpec askUserToolSpec = ToolSpec(
  name: 'ask_user',
  description: 'Ask the user to choose between concrete options. Keep each '
      'option short enough to fit on a button.',
  parameters: {
    'type': 'object',
    'properties': {
      'question': {
        'type': 'string',
        'description': "One sentence, in the user's language.",
      },
      'header': {
        'type': 'string',
        'description': 'Optional 1-3 word category, e.g. "instance".',
      },
      'options': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'label': {
              'type': 'string',
              'description': 'Short enough to fit on a button.',
            },
            'description': {
              'type': 'string',
              'description': 'Optional one-line elaboration.',
            },
          },
          'required': ['label'],
        },
        'description': 'Two to four options.',
      },
    },
    'required': ['question', 'options'],
  },
);

/// 技能加载。**两档都声明**（前提是确实有技能）。
///
/// 与 `write_file` / `run_background` 不同，它单参数、只读、无副作用 ——
/// 是小模型最不容易写坏的形状。把它挡在 lean 档外面等于让本地小模型用不上
/// 用户沉淀的全部运维知识，而它恰恰是最需要这些知识的那一档。
///
/// 描述保持一行，行为约束（别猜正文、一次会话只 load 一次）写在 system
/// prompt 里 —— 理由见本文件顶部那段。
const ToolSpec loadSkillToolSpec = ToolSpec(
  name: 'load_skill',
  description: 'Read the full text of one of your skills. The available '
      'names are listed in the system prompt.',
  parameters: {
    'type': 'object',
    'properties': {
      'name': {
        'type': 'string',
        'description': 'Exact name of the skill, as listed in the system '
            'prompt.',
      },
    },
    'required': ['name'],
  },
);

/// 技能检索。**只在有条目被挤出索引时声明**（见 `agentToolSpecsFor`）。
///
/// 描述里明说「system prompt 里那份列表不全」，否则模型没有理由怀疑还有别的
/// 技能存在——索引常驻这件事本身会让它以为看到的就是全部。
const ToolSpec searchSkillsToolSpec = ToolSpec(
  name: 'search_skills',
  description: 'Search your skills by keyword. The list in the system prompt '
      'is only the most-used ones; you have more. Returns names and '
      'one-line descriptions — call `load_skill` afterwards to read one.',
  parameters: {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'Keywords describing the problem, e.g. "nginx 502" '
            'or "mysql replication lag". Not a skill name.',
      },
    },
    'required': ['query'],
  },
);

/// 附件投送。**与 `load_skill` 同在 `hasSkills` 闸门后，但只进 full 档。**
///
/// ## 为什么不在 lean 档
///
/// 它是一次**需审批的写入**，与 `save_skill` 同类 —— 而那个也是只进 full
/// 档。lean 档的纪律是「小模型的选择面小」，多一个写工具就是多一次选错
/// 的机会。读取知识（`load_skill`）不需要分档，因为那是纯读、无副作用；
/// 改变远端状态（本工具、`save_skill`）要分。
///
/// 代价：lean 档下模型 load 一个带附件的技能后会看到 `load_skill` 返回值里
/// 那句 “install with `install_skill_assets`”，但工具表里没有它。它会把这
/// 件事告诉用户，而不是默默跳过 —— 比隐式缺工具好。真正跑带脚本的技能是
/// full 档的场景（用户选了更强模型）。
///
/// ## 描述要讲清「什么时候调」
///
/// 这是本文件里唯一一个「前提条件不在本工具参数里」的工具：模型必须先
/// `load_skill` 拿到清单，才知道有附件、才知道有哪些 path。`load_skill` 的
/// 返回值里会写「install with `install_skill_assets`」，两处互相引用。
///
/// 不按「有附件才声明」区分：附件清单是异步的，而工具表要在建轮次时同步
/// 拼出来 —— 而言“有附件”是少数，先声明、调用时再报「该技能没有附件」
/// 比隐式缺工具好诊断（对照 `load_skill` 的同一条约束）。
const ToolSpec installSkillAssetsToolSpec = ToolSpec(
  name: 'install_skill_assets',
  description: 'Write a skill\'s attached files (scripts, templates) to the '
      'server and mark the executable ones. Requires approval. Call it after '
      '`load_skill`, before running anything in that skill\'s assets list.',
  parameters: {
    'type': 'object',
    'properties': {
      'name': {
        'type': 'string',
        'description': 'Exact name of the skill whose assets to install.',
      },
      'server': {
        'type': 'string',
        'description': 'Optional. Another saved server to install on. Omit '
            'for the current session.',
      },
    },
    'required': ['name'],
  },
);

/// 技能保存。**只进 full 档。**
///
/// 三个字段（尤其是要自己拟一句 description、再把整段流程组织成 body）
/// 正是小模型容易写坏的形状，与 `write_file` 出局 lean 档同一个理由。
///
/// ## `assets` 是可选参数
///
/// 从 store 到这个工具是 “查、想、写” 里唯一需要知道**附件存在**的地方。
/// 不写在这里的话，模型永远不知道可以带脚本 —— executor 里那条路径变成
/// 死代码（真发生过：先加了 executor，忘了加 spec）。
///
/// 描述里只给两个字“when to use”，写法细节（路径要相对、可执行位怎么标、
/// 单个多大）放在参数说明里 —— 那是“怎么填这个参数”，属于工具描述的职责。
const ToolSpec saveSkillToolSpec = ToolSpec(
  name: 'save_skill',
  description: 'Save a reusable skill to the user\'s phone. Always requires '
      'the user to approve. Use it when the user asks you to remember a '
      'procedure — attach any script or template it needs via `assets` so '
      'the steps do not have to be rewritten every time.',
  parameters: {
    'type': 'object',
    'properties': {
      'name': {
        'type': 'string',
        'description': 'Short slug-like name, e.g. `nginx-troubleshooting`.',
      },
      'description': {
        'type': 'string',
        'description': 'ONE short line saying when this skill applies. This '
            'is the only part that stays in every prompt, so make it precise '
            'and keep it under 200 bytes.',
      },
      'body': {
        'type': 'string',
        'description': 'The full skill text in markdown. Max 8 KiB.',
      },
      'assets': {
        'type': 'array',
        'description': 'Optional files the skill ships with (a script, a '
            'config template), stored on the phone and written to the '
            'server by `install_skill_assets` when the skill is used. Max 8 '
            'files, 4 KiB each. Only attach a file the body actually tells '
            'you to run.',
        'items': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Relative path inside the skill\'s own folder, '
                  'e.g. `scripts/check.sh`. No leading `/` and no `..`.',
            },
            'content': {
              'type': 'string',
              'description': 'The complete file contents. Max 4 KiB.',
            },
            'executable': {
              'type': 'boolean',
              'description': 'true only for files meant to be run. They get '
                  '`chmod +x` on install.',
            },
          },
          'required': ['path', 'content'],
        },
      },
    },
    'required': ['name', 'description', 'body'],
  },
);

/// 机器笔记追加。**只进 full 档**，与 `save_skill` 同理由。
///
/// 与 `save_skill` 同在 `skills` 组、必须一起解锁：两者是一对二选一
/// （「这是跨机套路」vs「这是这台机器的事」），只给模型其中一个，它必然
/// 把机器事实硬塞进 skill。
const ToolSpec saveNoteToolSpec = ToolSpec(
  name: 'save_note',
  description: 'Append a fact about ONE specific machine to the notes kept '
      'for it on the user\'s phone. Always requires the user to approve. Use '
      'it for conventions and quirks of that box ("this one uses podman, not '
      'docker", "logs live on /data"). For a procedure that would apply on '
      'ANY machine, use `save_skill` instead. Your text is APPENDED to what '
      'is already there — never restate existing content.',
  parameters: {
    'type': 'object',
    'properties': {
      'body': {
        'type': 'string',
        'description': 'The fact, in markdown. Keep it short — the whole '
            'notes file is resent on every single turn.',
      },
      'heading': {
        'type': 'string',
        'description': 'Optional short heading for this section, e.g. '
            '`containers`.',
      },
      'server': {
        'type': 'string',
        'description': 'Which machine this is about. Required when the '
            'session is not tied to a single server.',
      },
    },
    'required': ['body'],
  },
);

/// 解锁一组低频工具。
///
/// ## 为什么要有这个工具
///
/// 19 个工具的定义每轮常驻约 2942 token，其中传输 / web / 技能保存 / 任务
/// 列表这 6 个在多数会话里一次都用不上。把它们的声明推迟到真要用的那一刻，
/// 常驻部分省下约 930 token/轮。
///
/// 代价是解锁那一轮会击穿 prompt cache（断点 2/3 打在工具定义末项，清单一变
/// 前缀就失效）。所以：一次解锁一组、本会话不回收。
/// `more_tools` 的声明。**按可用性动态生成，不是常量。**
///
/// `app_config` 只在 [hasAppControl] 为真时列出。静态列出它会让没开 app
/// 控制的用户那边出现这样一轮：模型调 `more_tools('app_config')` → 执行器
/// 回「已激活 app_settings_set」（组名确实存在）→ 下一轮发现工具并没有出现。
/// 白烧一轮且模型困惑 —— 与 `hasOtherServers` 为 false 时藏掉
/// `copy_between_servers` 是同一条原则：**不告诉模型它有用不了的东西**。
ToolSpec moreToolsToolSpecFor({bool hasAppControl = false}) {
  final groups = <String>[
    'transfer',
    'sftp',
    'web',
    'skills',
    'jobs',
    if (hasAppControl) 'app_config',
    if (hasAppControl) 'app_session',
  ];
  return ToolSpec(
    name: 'more_tools',
    description:
        'Activate a group of additional tools for this conversation. '
        'Groups: transfer (upload_file, download_file, copy_between_servers), '
        // SFTP 一组六个：逐一列出而不是写「list, stat, …」—— 模型靠这段
        // 描述判断「哪个组里有我要的工具」，抽写的词（`list`）跟真实工具名
        // （`sftp_list`）对不上，它就无法把「我想列个目录」映射到这个组。
        'sftp (sftp_list, sftp_stat, sftp_mkdir, sftp_rename, sftp_remove, '
        'sftp_chmod), '
        'web (web_fetch), '
        'skills (save_skill, save_note, skill_list, skill_delete, '
        'skill_set_enabled, skill_update), '
        'jobs (list_jobs)'
        '${hasAppControl ? ', app_config (app_settings_set, '
            'server_entry_create, server_entry_update, server_entry_delete, '
            'tunnel_create, tunnel_close, keybar_item_add, keybar_item_remove, '
            'ssh_key_generate, ssh_key_list, saved_command_create, '
            'saved_command_delete, saved_command_list, known_host_list, '
            'known_host_forget), app_session (session_open, session_close, '
            'layout_set, navigate_to)' : ''}. '
        'They stay available for the rest of the session.',
    parameters: {
      'type': 'object',
      'properties': {
        'group': {
          'type': 'string',
          'enum': groups,
          'description': 'Which group to activate.',
        },
      },
      'required': ['group'],
    },
  );
}

/// 运行一条用户保存的命令。**两档都声明**（前提是确实有可用的）。
///
/// 只有两个参数、且没有自由文本，是小模型也写得来的形状 —— 与 `load_skill`
/// 一样进 lean 档。
///
/// ## 为什么是一个工具而不是每条命令一个
///
/// 每条收藏生成一个工具语义更清晰（模型看到的就是 `deploy`、`rollback`），
/// 但工具表会随用户配置线性增长，正是本文件顶部否决过的那条路。用这一个
/// 工具 + system prompt 里的索引，用户加十条命令，工具清单仍然只多一个。
///
/// 名字不叫 `run_favorite`：「收藏」是 app 内部叫法，对模型没有信息量。
/// 也不叫 `run_command`：太容易和 `bash` 混。
const ToolSpec runSavedCommandToolSpec = ToolSpec(
  name: 'run_saved_command',
  description: 'Run one of the user\'s saved commands by name, filling in '
      'its placeholders. The available names and their parameters are '
      'listed in the system prompt.',
  parameters: {
    'type': 'object',
    'properties': {
      'name': {
        'type': 'string',
        'description': 'Exact name of the saved command, as listed in the '
            'system prompt.',
      },
      'params': {
        'type': 'object',
        'description': 'One entry per placeholder the command declares. '
            'Values may only contain letters, digits, spaces and '
            '. - _ / : = , @ + — anything else is rejected.',
      },
    },
    'required': ['name'],
  },
);

/// 组装这一轮要发给模型的工具清单。
///
/// [hasSkills] / [hasSavedCommands] 都默认 false：漏传的后果应该是「少了一个
/// 工具」（模型照常工作），而不是「声明了一个必然返回『你没有可用的』的
/// 工具」—— 后者正是 `agent_prompt.dart` 顶部警告的那种错法，模型会反复
/// 尝试、每次撞上 `_executeOne` 的闸门、白烧一轮。
///
/// 注意 `save_skill` **不**受任何一个开关影响：一个技能都没有的时候恰恰
/// 是最需要它的时候。而 `run_saved_command` 受 [hasSavedCommands] 影响 ——
/// agent 不能自己新建收藏命令，没有就是没有。

/// 全局会话里必须消失的工具。
///
/// 判据是「没有默认机器时它**必然失败**」,而不是「它经常用不上」——后者只会
/// 少几个工具,模型照常工作;前者会让模型反复尝试、每次撞上 `_executeOne`
/// 的闸门、白烧一轮。与 `hasOtherServers` 为 false 时藏掉 `list_servers`
/// 是同一条原则:**不声明,而不是声明了再回错误**。
///
/// 剩下的四个成员、三种成因:
///
/// - `read_terminal`:依赖一块并不存在的终端屏幕。全局会话没有终端页,
///   数据源是 app 侧的 `terminalTextProvider`,给不了。
/// - `run_saved_command`:schema 里**压根没有 `server` 字段**——
///   `runSavedCommandToolSpec` 的 `properties` 只有 `name` / `params`。
///   这不是「忘了标必填」,是 [_withRequiredServer] 根本无从下手:它只给
///   已经有 `server` 属性的 spec 加必填,不会凭空新增一个。放进清单的话,
///   模型调用它会一路走到 `MissingServerRunner`,但那句「请带上 `server`
///   重试」的提示在这个工具上无路可退——它没有这个参数可填。要不要给它加
///   `server`、怎么加,是独立的产品问题。
/// - `download_file` / `upload_file`:`transfer_executors.dart` 的
///   `download()` 与 `upload()` 都是直接 `opsProvider(null)`——它们**没有**
///   `resolveServerTarget` 那一步,仍然只会作用在当前会话那台机器。
///   除了留在本集合,它们还**必须**留在 prompt 的 `noServerNames` 负面
///   名单里:把这段读成「传输工具已经能跨机」,就会把它们从负面名单里删掉,
///   于是 prompt 告诉模型可以用一个其实用不了的参数——正是上面警告的那种
///   错法。
///
/// **job 三件套(2026-10 已离开本集合,不要再放回来。)**
/// `run_background` / `check_job` / `list_jobs` 曾经在这里,理由是它们的
/// 执行器硬编码 `runnerProvider(null)`——那时这个理由成立。阶段 1 给三个
/// 工具都加了 `server` 参数并接上 `resolveServerTarget`(见
/// `job_executors.dart`,三处都在走它,`runnerProvider(null)` 已不再出现;
/// `run_background` / `check_job` 分别见 commit `13fa4720` / `e8745cb3`,
/// `list_jobs` 见 `89e20b50`),于是它们跟 `bash` 一样走
/// [_withRequiredServer]——`server` 从可选变**必填**,而不是整条消失。
///
/// 判据是「有没有能力」而不是「有没有默认机器」:三个工具既然能显式指定
/// 目标,在全局会话里就不是必然失败,而「必须让模型说清楚操作哪台机器」
/// 正是这个模式想要的约束。连 `check_job` 也不例外,尽管它的归属解析有
/// 「任务事件记录的 `serverId`」这一档兜底(见 `jobExecutors.checkJob`)。
/// 选必填是因为那份兜底依赖内存里的 `ctx.events`:压缩、重启、resume 之后
/// 事件可能已经不在,这时回退只会给出「job 不存在,日志可能被清理了」这种
/// **指错根因**的提示(源码注释里的原话),同时把还在跑的任务永久标成已完成
/// (`job.exitCode ??= -1`)。一致性与可预测性优先——全局会话里模型本来就
/// 该知道自己在操作哪台机器。
///
/// 不声明而不是「声明了再回错误」:同上。
const Set<String> kSessionBoundToolNames = {
  'read_terminal',
  'download_file',
  'upload_file',
  'run_saved_command',
};

/// app 自身状态的只读查询。**core 常驻**（在 `hasAppControl` 为真时）。
///
/// 合并成单个带 section 参数的工具而不是 4 个只读工具：只读需求本身是
/// 「看一眼现状」，4 个独立 schema 要多占约 3 倍 token，而模型选 section
/// 的难度并不比选工具高。
///
/// 常驻的理由与 `check_job` 同：它是所有 app 操作的前置 —— 模型不知道
/// 当前字体是 13 就没法说「字体 13 → 15」，不知道有哪些 tab 就没法关对。
///
/// **没有 `server` 参数**：app 工具操作的是本机 app，不是任何一台远端。
/// 这也让它在 `requireExplicitServer` 分支里能原样通过 `_withRequiredServer`。
const appStateReadToolSpec = ToolSpec(
  name: 'app_state_read',
  description:
      'Read FlyTerm app state. Use this before changing anything so you can '
      'report what changed. Returns only user-facing settings; AI/agent '
      'configuration and security toggles are not readable.',
  parameters: {
    'type': 'object',
    'properties': {
      'section': {
        'type': 'string',
        'enum': [
          'settings',
          'servers',
          'sessions',
          'tunnels',
          'keybar',
          'ui',
        ],
        'description': 'Which part of the app state to read.',
      },
    },
    'required': ['section'],
  },
);

/// 改一个 app 设置。**on-demand，属 `app_config` 组。**
const appSettingsSetToolSpec = ToolSpec(
  name: 'app_settings_set',
  description:
      'Change one FlyTerm setting. Only user-facing display and connection '
      'settings are writable — security toggles and AI/agent configuration '
      'are not. Call app_state_read(section:"settings") first to see the '
      'writable keys and their current values. Changes are logged and the '
      'user can undo them.',
  parameters: {
    'type': 'object',
    'properties': {
      'key': {
        'type': 'string',
        'description': 'Setting key, e.g. "fontSize" or "terminalTheme".',
      },
      'value': {
        'description': 'New value. Numbers, booleans, or enum names '
            '(use the exact name as returned by app_state_read).',
      },
    },
    'required': ['key', 'value'],
  },
);

/// 新建一条服务器条目。**不收任何凭据字段** —— 密码/私钥只能用户自己填。
///
/// 这条边界在 schema 层面就堵死，不靠运行时判断：凭据经由模型就等于经由
/// 模型的上下文、日志和服务端。
const serverEntryCreateToolSpec = ToolSpec(
  name: 'server_entry_create',
  description:
      'Add a saved server entry to FlyTerm. Credentials cannot be set here — '
      'the entry is created with password auth and the user fills in the '
      'password (or switches to a key) themselves in the server form.',
  parameters: {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'description': 'Display name, must be unique.'},
      'host': {'type': 'string', 'description': 'Hostname or IP.'},
      'port': {'type': 'integer', 'description': 'SSH port. Defaults to 22.'},
      'user': {'type': 'string', 'description': 'Login user name.'},
      'group': {'type': 'string', 'description': 'Optional group label.'},
    },
    'required': ['name', 'host', 'user'],
  },
);

const serverEntryUpdateToolSpec = ToolSpec(
  name: 'server_entry_update',
  description:
      'Change connection details of a saved server. Only host, port, user '
      'and group can be changed — credentials and transport settings cannot.',
  parameters: {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'description': 'Which server to change.'},
      'host': {'type': 'string'},
      'port': {'type': 'integer'},
      'user': {'type': 'string'},
      'group': {'type': 'string'},
    },
    'required': ['name'],
  },
);

const serverEntryDeleteToolSpec = ToolSpec(
  name: 'server_entry_delete',
  description:
      'Delete a saved server entry. Always asks the user first, in every '
      'permission mode. The stored SSH key itself is not deleted.',
  parameters: {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'description': 'Which server to delete.'},
    },
    'required': ['name'],
  },
);

/// 开一条端口转发。**在硬清单里** —— 任何权限档都会先问用户。
///
/// 不可撤销：`tunnel_close` 能关掉端口，但关掉不等于撤销那段已经发生的暴露。
const tunnelCreateToolSpec = ToolSpec(
  name: 'tunnel_create',
  description:
      'Open an SSH port forward. Always asks the user first, in every '
      'permission mode — an exposed port cannot be un-exposed afterwards.',
  parameters: {
    'type': 'object',
    'properties': {
      'server': {'type': 'string', 'description': 'Saved server name.'},
      'local_port': {'type': 'integer', 'description': 'Port on this device.'},
      'remote_host': {
        'type': 'string',
        'description': "Target host as seen from the server, e.g. 'localhost'.",
      },
      'remote_port': {'type': 'integer'},
      'direction': {
        'type': 'string',
        'enum': ['local', 'remote'],
        'description': 'local = device port reaches a remote service. '
            'Defaults to local.',
      },
      'label': {'type': 'string', 'description': 'Optional display label.'},
    },
    'required': ['server', 'local_port', 'remote_host', 'remote_port'],
  },
);

const tunnelCloseToolSpec = ToolSpec(
  name: 'tunnel_close',
  description: 'Close an active port forward. Call '
      'app_state_read(section:"tunnels") first to get the id.',
  parameters: {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'Tunnel id from app_state_read.'},
    },
    'required': ['id'],
  },
);

/// 往自定义按键栏加一个按钮。
///
/// `sequence` 用方括号占位符而不是嵌套 JSON：KeyToken 是 sealed 层级，让
/// 模型构造嵌套结构既费 token 又容易写坏（每多一层括号就多一次出错机会）。
const keybarItemAddToolSpec = ToolSpec(
  name: 'keybar_item_add',
  description:
      'Add a button to the on-screen key bar. The sequence is plain text with '
      r'special keys in square brackets: "git status\n", "[ctrl-c]", '
      '"cd [tab]". Call app_state_read(section:"keybar") to see existing keys.',
  parameters: {
    'type': 'object',
    'properties': {
      'label': {'type': 'string', 'description': 'Button caption, unique.'},
      'sequence': {
        'type': 'string',
        'description': 'Text to send, with special keys as [name] — e.g. '
            '[enter], [tab], [esc], [ctrl-c], [up], [page-up], [f5]. '
            'Write a literal "[" as "[[".',
      },
      'sticky': {
        'type': 'boolean',
        'description': 'Acts as a modifier applied to the next key (like CTRL).',
      },
      'repeatable': {
        'type': 'boolean',
        'description': 'Repeats while held down.',
      },
    },
    'required': ['label', 'sequence'],
  },
);

const keybarItemRemoveToolSpec = ToolSpec(
  name: 'keybar_item_remove',
  description: 'Remove a button from the on-screen key bar by its label.',
  parameters: {
    'type': 'object',
    'properties': {
      'label': {'type': 'string', 'description': 'Caption of the key to remove.'},
    },
    'required': ['label'],
  },
);

/// 在后台开一个终端会话。**不把用户的焦点切过去。**
const sessionOpenToolSpec = ToolSpec(
  name: 'session_open',
  description:
      'Open a terminal session for a saved server in the background. The '
      "user's current screen is not switched — they get a prompt to enter it "
      'when they want. An optional command is pre-filled but NOT executed.',
  parameters: {
    'type': 'object',
    'properties': {
      'server': {'type': 'string', 'description': 'Saved server name.'},
      'command': {
        'type': 'string',
        'description': 'Optional. Pre-filled into the input line for the user '
            'to review and press enter. It is never executed automatically.',
      },
    },
    'required': ['server'],
  },
);

const sessionCloseToolSpec = ToolSpec(
  name: 'session_close',
  description:
      'Close a terminal session by its index. Asks the user first if the '
      'session still has a live connection — that cannot be undone. Call '
      'app_state_read(section:"sessions") for the indexes.',
  parameters: {
    'type': 'object',
    'properties': {
      'index': {'type': 'integer', 'description': 'Index from app_state_read.'},
    },
    'required': ['index'],
  },
);

const layoutSetToolSpec = ToolSpec(
  name: 'layout_set',
  description: 'Change the terminal split layout.',
  parameters: {
    'type': 'object',
    'properties': {
      'mode': {
        'type': 'string',
        'enum': ['off', 'horizontal', 'vertical'],
        'description': 'off = single pane.',
      },
    },
    'required': ['mode'],
  },
);

/// 生成一对 SSH 密钥。**私钥不进返回值** —— 只回公钥供用户贴到服务器。
const sshKeyGenerateToolSpec = ToolSpec(
  name: 'ssh_key_generate',
  description:
      'Generate an SSH key pair. The private key is stored in the device '
      'keystore and is never returned — you get the public key to give to '
      'the user so they can add it to the server. Use this after creating a '
      'server entry, since credentials cannot be set directly.',
  parameters: {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'description': 'Key name, must be unique.'},
      'type': {
        'type': 'string',
        'enum': ['ed25519', 'rsa'],
        'description': 'Defaults to ed25519.',
      },
    },
    'required': ['name'],
  },
);

const sshKeyListToolSpec = ToolSpec(
  name: 'ssh_key_list',
  description:
      'List saved SSH keys — names, types and public keys. Private keys have '
      'no read path at all.',
  parameters: {'type': 'object', 'properties': <String, Object?>{}},
);

/// 把用户带到 app 里的某个界面。
///
/// 这是「AI 作为入口」最本质的能力 —— 没有它，AI 只能口头指路。
const navigateToToolSpec = ToolSpec(
  name: 'navigate_to',
  description:
      "Open a screen in the FlyTerm app. Use this instead of telling the user "
      'where to tap. Call app_state_read(section:"ui") for the destination '
      'list and where the user currently is.',
  parameters: {
    'type': 'object',
    'properties': {
      'target': {
        'type': 'string',
        'enum': [
          'ai',
          'servers',
          'settings',
          'ssh_keys',
          'ai_providers',
          'agent_settings',
          'tunnels',
          'keybar',
          'known_hosts',
        ],
        'description': 'Which screen to open.',
      },
    },
    'required': ['target'],
  },
);

/// SFTP 文件管理。**对象是远端文件**，所以走 `checkFileWrite` / `checkReadFile`
/// 那套路径判定，不是 app 控制的权限轴。
const List<ToolSpec> sftpToolSpecs = [
  ToolSpec(
    name: 'sftp_list',
    description: 'List a directory on the remote server over SFTP.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Absolute directory path.'},
        'server': {'type': 'string', 'description': 'Optional server name.'},
      },
      'required': ['path'],
    },
  ),
  ToolSpec(
    name: 'sftp_stat',
    description: 'Get size, type and permissions of a remote path.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'server': {'type': 'string'},
      },
      'required': ['path'],
    },
  ),
  ToolSpec(
    name: 'sftp_mkdir',
    description: 'Create a directory on the remote server.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'server': {'type': 'string'},
        'description': {
          'type': 'string',
          'description': "One short sentence in the user's language, "
              'shown on the approval card.',
        },
      },
      'required': ['path'],
    },
  ),
  ToolSpec(
    name: 'sftp_rename',
    description: 'Rename or move a remote file or directory.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Current absolute path.'},
        'to': {'type': 'string', 'description': 'New absolute path.'},
        'server': {'type': 'string'},
        'description': {'type': 'string'},
      },
      'required': ['path', 'to'],
    },
  ),
  ToolSpec(
    name: 'sftp_remove',
    description:
        'Delete a remote file or directory. Directories must be empty. '
        'Always requires approval.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'server': {'type': 'string'},
        'description': {'type': 'string'},
      },
      'required': ['path'],
    },
  ),
  ToolSpec(
    name: 'sftp_chmod',
    description: 'Change permissions of a remote path.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'mode': {
          'type': 'string',
          'description': 'Octal mode such as "644" or "755".',
        },
        'server': {'type': 'string'},
        'description': {'type': 'string'},
      },
      'required': ['path', 'mode'],
    },
  ),
];

const savedCommandCreateToolSpec = ToolSpec(
  name: 'saved_command_create',
  description:
      'Save a command for later reuse. It becomes callable via '
      'run_saved_command and appears in the user\'s favourites.',
  parameters: {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'description': 'Short unique name.'},
      'command': {'type': 'string', 'description': 'The command text.'},
    },
    'required': ['name', 'command'],
  },
);

const savedCommandDeleteToolSpec = ToolSpec(
  name: 'saved_command_delete',
  description: 'Delete a saved command by name.',
  parameters: {
    'type': 'object',
    'properties': {
      'name': {'type': 'string'},
    },
    'required': ['name'],
  },
);

const savedCommandListToolSpec = ToolSpec(
  name: 'saved_command_list',
  description: 'List saved commands with their command text.',
  parameters: {'type': 'object', 'properties': <String, Object?>{}},
);

/// 技能自管理。
///
/// AI 是技能库唯一的生产者（`save_skill`），这组工具让它也成为维护者 ——
/// 否则库只增不减，越过索引上限之后早期的技能静默沉底。
const List<ToolSpec> skillManageToolSpecs = [
  ToolSpec(
    name: 'skill_list',
    description:
        'List all saved skills, including disabled ones and ones pushed out '
        'of the prompt index. `in_prompt: false` means the skill exists but '
        'you cannot see it in your system prompt — it is effectively dead '
        'weight. Use hit_count and last_used to decide what to clean up.',
    parameters: {'type': 'object', 'properties': <String, Object?>{}},
  ),
  ToolSpec(
    name: 'skill_delete',
    description: 'Delete a skill by name.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    },
  ),
  ToolSpec(
    name: 'skill_set_enabled',
    description:
        'Enable or disable a skill. Disabled skills stay saved but do not '
        'take up a slot in the prompt index.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'enabled': {'type': 'boolean'},
      },
      'required': ['name', 'enabled'],
    },
  ),
  ToolSpec(
    name: 'skill_update',
    description:
        "Change a skill's description or body. The description is the only "
        'part that goes into your system prompt, so it decides whether this '
        'skill gets recalled at the right moment.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'description': {'type': 'string'},
        'body': {'type': 'string'},
      },
      'required': ['name'],
    },
  ),
];

/// 已信任主机。「为什么连不上 X」的常见根因是主机密钥变了。
const List<ToolSpec> knownHostToolSpecs = [
  ToolSpec(
    name: 'known_host_list',
    description:
        'List trusted SSH host keys with fingerprints. Check this when a '
        'connection suddenly fails host key verification.',
    parameters: {'type': 'object', 'properties': <String, Object?>{}},
  ),
  ToolSpec(
    name: 'known_host_forget',
    description:
        'Forget a trusted host key. The next connection will ask the user to '
        'verify the fingerprint again. This cannot be undone — re-trusting is '
        "the user's decision to make, not yours.",
    parameters: {
      'type': 'object',
      'properties': {
        'host': {'type': 'string'},
        'port': {'type': 'integer', 'description': 'Defaults to 22.'},
        'key_type': {
          'type': 'string',
          'description': 'From known_host_list, e.g. "ssh-ed25519".',
        },
      },
      'required': ['host', 'key_type'],
    },
  ),
];

/// 把一条 spec 的 `server` 参数从可选改成必填。
///
/// 没有 `server` 属性的 spec 原样返回 —— 调用方不必先判断哪些工具有这个参数。
///
/// `parameters` 是 `const` map,不能原地改,所以逐层拷出新的。深度只有两层
/// (`properties` / `required`),不需要通用深拷贝。
ToolSpec _withRequiredServer(ToolSpec s) {
  final props = s.parameters['properties'];
  if (props is! Map || !props.containsKey('server')) return s;

  final newProps = Map<String, dynamic>.from(props);
  newProps['server'] = {
    'type': 'string',
    'description': 'Required. Exact name of the saved server to act on. '
        'This session is not attached to any machine — call `list_servers` '
        'to get the names.',
  };

  final required = (s.parameters['required'] as List?)?.cast<String>() ?? const [];
  return ToolSpec(
    name: s.name,
    description: s.description,
    parameters: {
      ...s.parameters,
      'properties': newProps,
      'required': [...required, 'server'],
    },
  );
}

List<ToolSpec> agentToolSpecsFor(
  AgentToolTier tier, {
  bool hasSkills = false,

  /// 有技能因为超出索引上限而没进 system prompt 吗？
  ///
  /// false 时 `search_skills` 与它的 prompt 引导整段不出现。判据与
  /// [hasSkills] 同理：全部技能都在索引里时，搜索只会搜出模型已经看得见的
  /// 东西，白烧一轮工具往返。
  bool hasSkillOverflow = false,
  bool hasSavedCommands = false,

  /// 除当前这台之外，用户还存了别的服务器吗？
  ///
  /// false 时不声明 `list_servers` 与 `copy_between_servers`。判据是**必然
  /// 失败**而不是「用得少」：单机下 `copy_between_servers` 没有第二个目标，
  /// `list_servers` 只会回一条模型已经在用的机器。
  ///
  /// 默认 false 与 [hasSkills] 同理：漏传的后果应该是「少两个工具」，而不是
  /// 「告诉模型它有两个其实用不了的工具」—— 后者会让它反复尝试、每次撞上
  /// `_executeOne` 的闸门、白烧一轮。
  bool hasOtherServers = false,

  /// 这个会话没有默认机器(全局 AI tab),每次调用都必须显式带 `server`。
  ///
  /// true 时三件事一起发生,缺一不可:
  /// 1. 所有**带 `server` 属性**的工具，`server` 从可选变必填（不止是
  ///    「支持多机」那几个：含 `bash` 等 core 工具、job 三件套、`sftp_*`、
  ///    以及 `save_note` / `tunnel_create` / `session_open` 这类 app 工具，
  ///    判据是下面过滤里 `_withRequiredServer` 的 `containsKey('server')`）
  /// 2. [kSessionBoundToolNames] 整组不声明
  /// 3. `list_servers` 无条件声明 —— 模型拿不到确切名字就一步也走不了,
  ///    这与 [hasOtherServers] 的单机优化正好相反,所以要显式压过它
  ///
  /// 默认 false:漏传的后果是「退回绑定当前会话的老行为」(终端页正确),
  /// 而不是「让终端页的工具凭空多出一个必填参数」。
  bool requireExplicitServer = false,

  /// app 自身控制是否可用（`AppControlService` 是否注入、权限档是否非 off）。
  ///
  /// false 时 `app_state_read` / `app_settings_set` 整组不声明。默认 false
  /// 与 [hasSkills] 同理：漏传的后果应该是「少两个工具」，而不是「多出两个
  /// 调用会报 not available 的工具」。
  bool hasAppControl = false,
}) {
  final base = tier == AgentToolTier.lean ? leanToolSpecs : fullToolSpecs;
  final specs = <ToolSpec>[
    for (final s in base)
      if (hasOtherServers ||
          requireExplicitServer ||
          (s.name != 'list_servers' && s.name != 'copy_between_servers'))
        s,
    if (hasSkills) loadSkillToolSpec,
    if (hasSkills && tier == AgentToolTier.full) installSkillAssetsToolSpec,
    if (hasSkillOverflow) searchSkillsToolSpec,
    if (tier == AgentToolTier.full) saveSkillToolSpec,
    if (tier == AgentToolTier.full) saveNoteToolSpec,
    if (tier == AgentToolTier.full)
      moreToolsToolSpecFor(hasAppControl: hasAppControl),
    if (hasSavedCommands) runSavedCommandToolSpec,
    // 无条件加入是对的 —— `filterByUnlockedGroups` 是第二道闸，它会按
    // `app_config` 组把未解锁的 `app_settings_set` 滤掉。这个「conditional
    // 在前、解锁在后」的顺序是 tool_groups.dart 文档注释里写明的既定规矩。
    if (hasAppControl) appStateReadToolSpec,
    if (hasAppControl) appSettingsSetToolSpec,
    if (hasAppControl) serverEntryCreateToolSpec,
    if (hasAppControl) serverEntryUpdateToolSpec,
    if (hasAppControl) serverEntryDeleteToolSpec,
    if (hasAppControl) tunnelCreateToolSpec,
    if (hasAppControl) tunnelCloseToolSpec,
    if (hasAppControl) keybarItemAddToolSpec,
    if (hasAppControl) keybarItemRemoveToolSpec,
    if (hasAppControl) sessionOpenToolSpec,
    if (hasAppControl) sessionCloseToolSpec,
    if (hasAppControl) layoutSetToolSpec,
    if (hasAppControl) sshKeyGenerateToolSpec,
    if (hasAppControl) sshKeyListToolSpec,
    if (hasAppControl) navigateToToolSpec,
    if (hasAppControl) savedCommandCreateToolSpec,
    if (hasAppControl) savedCommandDeleteToolSpec,
    if (hasAppControl) savedCommandListToolSpec,
    if (hasAppControl) ...skillManageToolSpecs,
    if (hasAppControl) ...knownHostToolSpecs,
    // SFTP 不受 app 控制开关影响 —— 它操作的是远端文件，和 write_file
    // 同类，只在 full 档声明（参数形状对小模型偏复杂）。
    if (tier == AgentToolTier.full) ...sftpToolSpecs,
  ];
  if (!requireExplicitServer) return specs;
  return [
    for (final s in specs)
      if (!kSessionBoundToolNames.contains(s.name)) _withRequiredServer(s),
  ];
}
