// SPDX-License-Identifier: GPL-3.0-or-later
/// 远端前台程序是否接管了输入行的渲染。
///
/// ## 为什么不复用 `SessionTab.remoteTuiHint`
///
/// 两者回答的是不同的问题，判据因此必须不同：
///
/// - `remoteTuiHint` 回答「滚轮手势该不该转成 SGR 鼠标事件」。它只认
///   光标隐藏（`?25l`）和 alt buffer（`?1049h`）—— 对那个问题够用。
/// - 这个函数回答「还要不要弹命令补全」。它必须**额外**认出在主 buffer 里
///   做全屏重绘的 TUI。
///
/// 两者曾经共用 `remoteTuiHint`，结果就是本函数存在的原因：Claude Code
/// 稳态下**两个信号一个都不发**。真机诊断实测 `tui:F xtCur:vis xtAlt:F`，
/// 而 `recent esc` 里全是 `^[[4A`(CUU) / `^[[33G`(CHA) / SGR —— 它在主
/// buffer 渲染以保留 scrollback，又要显示光标让用户看到输入位置。于是补全
/// 浮层照常弹出，盖在它的输入框上。
///
/// ## focus tracking 为什么是可用的判别点
///
/// `?1004h`（DECSET 1004，报告窗口焦点变化）是**全屏程序**才会开的：它要
/// 在失焦时暂停动画、重绘状态栏。`bash` / `readline` 没有任何理由关心窗口
/// 焦点 —— 它们开 `?2004h`（bracketed paste）但不开 `?1004h`。这让后者成为
/// 「主 buffer 里有全屏程序」的干净信号，而前者不行（readline 也开）。
///
/// ## [inTmux] 为什么必须排除
///
/// tmux attach 时自己就开 focus tracking（它要靠焦点变化更新状态栏）。不
/// 排除的话，tmux 会话从连上的那一刻起就被判成 TUI，**补全永久失效** ——
/// 那是比原 bug 更严重的回归。
///
/// 代价是 tmux 下仍然认不出 Claude Code（tmux 占用了这个信号，无法区分是
/// 谁开的）。那种场景下补全照旧会弹，是已知限制 —— 要根治得靠
/// `tmux display-message -p '#{pane_current_command}'` 直接问前台命令名，
/// 那是异步查询，不适合放在每次按键的路径上。
///
/// ## 参数都是 xterm 的权威状态
///
/// 调用方应直接传 `terminal.cursorVisibleMode` / `terminal.isUsingAltBuffer`
/// / `terminal.reportFocusMode` —— 那是解析完所有字节后屏幕真实的样子。
/// **不要**另起一套字符串搜索：`SessionTab._trackRemoteTui` 那套会在 ESC
/// 序列跨 chunk 边界被切断时漏掉事件，而 TUI 往往只在启动时宣告一次。
///
/// 抽成顶层纯函数而不是写进调用点，理由与 `agent_assembly.dart` 里的
/// `shouldDeclareAppTools` 相同：埋在闭包里的判据没人测得到。
bool foregroundOwnsInputLine({
  required bool cursorVisible,
  required bool altBuffer,
  required bool focusTracking,
  required bool inTmux,
}) =>
    !cursorVisible || altBuffer || (!inTmux && focusTracking);
