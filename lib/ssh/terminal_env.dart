// SPDX-License-Identifier: GPL-3.0-or-later
/// FlyTerm 对远端声明的颜色能力。
///
/// 远端 TUI（Claude CLI / delta / bat / nvim）靠 `COLORTERM` 判断能不能发
/// 24-bit RGB。这个变量缺失时它们退回 256 色调色板，而调色板量化会把「深靛蓝
/// 代码块底」这类颜色打到色立方的**纯蓝** `#0000FF`（色号 21）——
/// 2026-09-22 真机截图里那块刺眼的蓝就是这么来的。
///
/// 那块蓝换终端主题不会变：RGB / 256 色立方都绕过 `TerminalTheme.blue`
/// （见 `lib/ui/terminal/terminal_themes.dart`，五套主题的 blue 分别是
/// 569CD6 / BD93F9 / 268BD2 / 66D9EF / 268BD2，没有一套是纯蓝），所以这只能
/// 在「让程序别降级」这一侧修。
///
/// ## 为什么不用 SSH 的 env 请求
///
/// dartssh2 的 `SSHClient.shell(environment: ...)` 在服务端拒绝 env 请求时会
/// **关掉 channel 并抛 [SSHChannelRequestError]**（ssh_client.dart:503-512）。
/// sshd 默认只 `AcceptEnv LANG LC_*`，所以对绝大多数服务器这等于每次建连都先
/// 失败一次再重开 channel。代价太大，不走这条路 —— 改为在我们自己拉起 shell
/// 的地方注入：本地 PTY 的 env map、QUIC server 的 `spawn_pty`、tmux 的 `-e`。
///
/// ## 为什么 mosh 上不能声明
///
/// mosh 直到 **1.4.0（2022-09）** 才支持 24-bit 色，而 Ubuntu 20.04 / 22.04
/// 仍然是 1.3.2。在 1.3 上声明 truecolor 只会让应用发出 mosh emulator 读不懂的
/// RGB 序列，颜色**直接丢失** —— 比现在的 256 色降级更差。而 env 是在
/// `mosh-server new` 的 exec 那一刻就要定下来的，那时还没拿到版本号，没法按版本
/// 分流。所以所有注入点都按传输分流：QUIC / SSH / 本地 PTY 声明，mosh 不声明。
const String kColorTermValue = 'truecolor';

/// `KEY=VALUE` 形式，用于 tmux `-e` 与命令行前缀。见 [kColorTermValue]。
const String kColorTermAssignment = 'COLORTERM=$kColorTermValue';

/// 让 tmux 把 pane 里的 24-bit SGR 原样透传给客户端。
///
/// 只声明 [kColorTermAssignment] 不够：tmux 自己有一层颜色模型，默认按外层
/// TERM 的 terminfo 能力决定要不要保留 RGB，不认识 RGB 时会把 `48;2;r;g;b`
/// 量化回调色板 —— 等于白声明。
///
/// 用 `terminal-overrides ,*:Tc` 而不是 tmux 3.2 的 `terminal-features ,*:RGB`：
/// 后者在 3.2 以下是 unknown option，而链式命令里一条失败会让 tmux **跳过其后
/// 所有命令**（mouse on / history-limit 都会丢）。`Tc` 从 tmux 1.9 起就有，
/// 3.2+ 也仍然把它翻译成 RGB feature。
///
/// `-ga` 是追加：重连多次会让选项里堆出重复的 `,*:Tc`。tmux 匹配时取首个命中，
/// 重复项是惰性的，只是字符串变长（每次 6 字节），不影响正确性。用 `-g` 覆盖
/// 反而会抹掉用户 `.tmux.conf` 里自己的 overrides。
///
/// 值用双引号包住：`,*:Tc` 里的 `*` 会被交互式 shell 当 glob 展开。
const String kTmuxRgbOverride =
    r' \; set-option -ga terminal-overrides ",*:Tc"';
