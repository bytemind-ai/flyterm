// SPDX-License-Identifier: GPL-3.0-or-later
//! RESUME 恢复负载的组装。产出一段字节流，让客户端 xterm 从**任意**先前的
//! 解析器状态重建出服务端当前的终端状态 —— 无论它当时停在 SGR 中间、在 alt
//! buffer 里、还是干净的冷启动。
//!
//! # 唯一一条路径
//!
//! 这里曾经有两个函数：primary 走 `serialize_with_history`（历史 + 当前屏，
//! 逐行流式），alt 走 `serialize`（绝对定位快照）。分成两条的代价是 alt 负载
//! 不带 primary 历史 —— 客户端冷启动后退出 TUI 就是一片空白 primary。
//!
//! 现在合成一条：primary 历史与可见屏永远都发，alt 只是在后面**叠加**一层
//! alt 屏快照。
//!
//! # 历史从哪来：只能是 parser，不能是字节流 ring
//!
//! 历史段与当前屏段必须出自**同一个求值状态**。这不是风格选择，是这一整类
//! bug 的根源所在：
//!
//! 上一版从 `LineRing`（原始 PTY 字节流按 `\n` 切出的**逻辑行**）取历史，
//! 再按「`history.len()` − 物理屏幕行数」剔掉重叠部分。两个量根本不是同一个
//! 单位，这个减法不可能对：
//!
//!   * **原地重绘**（`docker pull` / `cargo build` / 两行 prompt：光标上移再
//!     重写）每轮都往 ring 追加新逻辑行，物理行数却不变 —— 实测 20 轮重绘在
//!     负载里留下 20 份副本，屏幕上只有 1 份。
//!   * **alt buffer**：ring 无条件吞下每个字节，vim / htop / claude 刷的每一帧
//!     都进去了 —— 实测 71 行 TUI 帧内容混进 primary 历史。
//!   * **折行**：手机窄屏下一条逻辑行占多个物理行，剔掉的逻辑行数**多于**当前
//!     屏实际覆盖的，真历史被静默丢掉。
//!   * **`clear`**：ring 不认识 ED 2 / ED 3，被清掉的内容作为「历史」回放回来。
//!
//! 改从 parser 取之后这四条全部消失，而且不是靠打补丁 —— vt100 本身就是终端
//! 仿真器，重绘收敛、alt 隔离（alt grid 恒以 `scrollback_len: 0` 创建）、
//! ED 3 清 scrollback 都是它的份内之事。两段都是**当前宽度下的物理行**，顺序
//! 拼接即可，**没有任何去重**要做。
//!
//! 回归用例见 `tests/replay_duplication_repro.rs`（四个场景）与
//! `tests/parser_scrollback_probe.rs`（parser 侧的天然正确性）。

use vt100::Screen;

/// Section 1 + 2: hard reset followed by safe-default DEC private modes.
/// Always emitted regardless of screen state. ~120 bytes total.
const HARD_RESET_AND_SAFE_MODES: &[u8] = b"\x1bc\x1b[!p\x1b[?1049l\x1b[2J\x1b[H\x1b[0m\
                                            \x1b[?25h\x1b[?7h\x1b[?12l\x1b[?1006l\x1b[?1004l\x1b[?2004l";

/// 行与行之间的分隔：复位属性 + 换行。
///
/// 复位不是保守起见，是 `rows_formatted` 的契约：它每行都**假设起始属性是
/// 默认值**，只在偏离默认时才发 SGR。一行以 inverse 结束时不会补 `\x1b[0m`，
/// 而下一行若是默认属性则一个 SGR 都不发 —— 直接拼接就会让上一行的属性漏进
/// 下一行，整行变色块（真机上表现为输入框下边框与状态行全带背景）。
///
/// 复位也不会丢掉本该延续的属性：既然每行都从默认算起，需要的属性它自己会
/// 重新发一遍。
const ROW_SEPARATOR: &[u8] = b"\x1b[0m\r\n";

/// 组装 RESUME 恢复负载。
///
/// `history_budget_bytes` 只约束 **primary scrollback** 那一段（从最新往旧取，
/// 装不下的最老部分丢弃）。可见屏与 alt 快照无条件全发 —— 它们是「当前状态」，
/// 截断就等于恢复不出来。
///
/// # 幂等
///
/// 整段是一个原子的重建指令：重复应用、乱序应用、并发应用都收敛到同一状态。
/// 这是客户端可以六路并发发起 RESUME 而不需要任何协调的**前提**（见
/// `session_resume_coordinator.dart` 的文档：coordinator 消除的是浪费，正确性
/// 来自这里的幂等）。
///
/// 幂等靠两件事：
///
/// 1. `ED 3`（`\x1b[3J`，清 scrollback）**不能省**。前缀里的 `\x1bc`（RIS）在
///    客户端渲染器 xterm.dart 上是空操作（它的 ESC 分派表里那一行是注释掉的），
///    `\x1b[!p`（DECSTR）也只是个 stub。真正生效的只有 `2J`，而 `2J` 在
///    xterm.dart 里只擦**可见区**、不动 scrollback。本函数的负载行数经常远超
///    一屏，超出的部分写进去时会把前面的行顶进 scrollback —— 不清 scrollback
///    的话，每应用一次就在 scrollback 里多留一整份副本（真机症状：app 每切走
///    再切回来一次，往上翻就多看到一遍同样的内容）。
///
///    清掉的历史不会真的丢：紧接着写进去的就是 parser 里那份权威历史。**这是
///    与上一版的关键区别** —— 那时清完要靠客户端再发 `FetchScrollback` 把历史
///    取回来前插，清与补之间有个窗口，也有一整条会插错代的竞态链路。现在负载
///    自带全部历史，一次写完，那条链路整个删掉了。
///
/// 2. 每一段都是「先擦再画」而不是「追加」：primary 段靠 `ED 3` + 从 scrollback
///    顶部重写，alt 段靠 `2J` + `H` + 绝对定位的 `state_formatted()`。
pub fn serialize_resume(screen: &Screen, history_budget_bytes: usize) -> Vec<u8> {
    let (_rows, cols) = screen.size();

    // primary 的历史与可见屏。**始终读 primary grid**，与当前是否在 alt 无关
    // —— alt 会话也要带上 primary 历史，否则客户端冷启动后退出 TUI 就是一片
    // 空白 primary。
    let scrollback: Vec<Vec<u8>> = screen.primary_scrollback_rows_formatted(0, cols).collect();
    let visible: Vec<Vec<u8>> = screen.primary_rows_formatted(0, cols).collect();
    let (cursor_row, cursor_col) = screen.primary_cursor_position();

    // 可见屏输出到「最后一个有内容的行」为止。
    //
    // 不能只输出到 cursor_row：TUI 的输入框在屏幕下部而光标落在框**内**，框的
    // 下边框与状态行都在 cursor_row 之后 —— 截断就等于「输入框没弹出来」。
    //
    // 也不能无条件输出满 rows：shell 刚起来时只有一行 prompt，其余行是「从未
    // 使用」而非「空行」，全部输出会凭空造出一串换行把历史顶上去。
    //
    // 取两者的交集：到最后一个非空行为止，且至少到 cursor_row（光标那行即便是
    // 空的也要占位，否则定位列时没有行可落）。
    let last_content = visible.iter().rposition(|r| !r.is_empty()).unwrap_or(0);
    let last_row = last_content.max(cursor_row as usize);

    // scrollback 按预算从**最新**往旧取。最老的部分丢弃 —— 用户往上翻能翻多远
    // 由预算决定，而「最近这些」永远在。
    let sb_start = budget_cut(&scrollback, history_budget_bytes);

    let mut out = Vec::with_capacity(HARD_RESET_AND_SAFE_MODES.len() + 8192);
    out.extend_from_slice(HARD_RESET_AND_SAFE_MODES);
    out.extend_from_slice(b"\x1b[3J");

    // 历史段：逐行，每行后面都跟分隔符 —— 包括最后一行，它正好也是历史与
    // 可见屏之间的那道复位（ring 里最后一行可能以「属性开着」结束）。
    for row in &scrollback[sb_start..] {
        out.extend_from_slice(row);
        out.extend_from_slice(ROW_SEPARATOR);
    }

    // 可见屏段：逐行，行**之间**放分隔符。最后一行后面不放 —— 否则光标会被
    // 推到下一行，而 shell 刚启动那种「只有一行 prompt」的情形还会凭空多出
    // 一个换行。
    for (i, row) in visible.iter().enumerate().take(last_row + 1) {
        out.extend_from_slice(row);
        if i < last_row {
            out.extend_from_slice(ROW_SEPARATOR);
        }
    }

    // 光标现在停在 last_row，可能在 cursor_row 下方，需要抬回去。
    // 用 CUU（相对上移）而不是 CUP（绝对行列）：这段是流式输出，写的过程中
    // 屏幕可能已经滚动，绝对行号不可靠；而「上移几行」只依赖行数差。
    if last_row > cursor_row as usize {
        out.extend_from_slice(format!("\x1b[{}A", last_row - cursor_row as usize).as_bytes());
    }
    // 列用 CHA（绝对列）而不是相对移动：相对移动要知道「当前在第几列」，而那
    // 取决于最后一行的实际渲染宽度（宽字符、SGR 都影响），算不准。
    out.extend_from_slice(format!("\x1b[{}G", cursor_col + 1).as_bytes());
    out.extend_from_slice(b"\x1b[0m");

    // alt 段：叠在 primary 之上。
    //
    // 这一段继续用绝对定位的 `state_formatted()` 而不是逐行流式 —— alt 没有
    // scrollback 语义，画面是二维的（光标可能停在任意位置、下方也可能有内容），
    // 绝对定位对重建 TUI 画面更准。
    //
    // `\x1b[H` 是必需的：`state_formatted()` 内部从 `Pos::default()`（0,0）开始
    // 算相对移动，不先归位的话整幅画面会错位。
    if screen.alternate_screen() {
        out.extend_from_slice(b"\x1b[?1049h\x1b[2J\x1b[H");
        out.extend_from_slice(&screen.state_formatted());
        out.extend_from_slice(b"\x1b[0m");
    }

    out
}

/// 从尾部往前累计，返回「预算装得下的那一段」的起始下标。
///
/// 每行的成本要算上 [`ROW_SEPARATOR`] —— 不算进去会让实际字节超出预算。
///
/// 预算连一行都装不下时返回 `rows.len()`（即一行都不发）。这与
/// `LineRing::recent_lines_capped` 那个「至少给一行」的约定相反，是有意的：
/// 那里返回空会让调用方分不清「有历史」和「没历史」，而这里空就是空 ——
/// 可见屏无论如何都会发，历史段发不发不影响调用方的任何分支。
fn budget_cut(rows: &[Vec<u8>], budget: usize) -> usize {
    let mut total = 0usize;
    let mut start = rows.len();
    for (i, row) in rows.iter().enumerate().rev() {
        let cost = row.len() + ROW_SEPARATOR.len();
        if total + cost > budget {
            break;
        }
        total += cost;
        start = i;
    }
    start
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试用预算：足够大，不触发截断。截断行为由 `budget_tests` 专门测。
    const NO_LIMIT: usize = 1 << 20;

    fn roundtrip(rows: u16, cols: u16, input: &[u8]) -> (String, String) {
        let mut p1 = vt100::Parser::new(rows, cols, 0);
        p1.process(input);
        let snap = serialize_resume(p1.screen(), NO_LIMIT);
        let mut p2 = vt100::Parser::new(rows, cols, 0);
        p2.process(&snap);
        (p1.screen().contents(), p2.screen().contents())
    }

    #[test]
    fn empty_prompt() {
        let (orig, restored) = roundtrip(24, 80, b"$ ");
        assert_eq!(orig, restored);
    }

    #[test]
    fn plain_text_full_screen() {
        let mut input = Vec::new();
        for i in 0..24 {
            input.extend_from_slice(format!("line {:02}\r\n", i).as_bytes());
        }
        let (orig, restored) = roundtrip(24, 80, &input);
        assert_eq!(orig, restored);
    }

    #[test]
    fn sgr_colors_preserved() {
        let input = b"\x1b[31mred\x1b[32mgreen\x1b[0m normal";
        let (orig, restored) = roundtrip(24, 80, input);
        assert_eq!(orig, restored);
    }

    #[test]
    fn cursor_position_preserved() {
        let input = b"hello\x1b[10;5Hworld";
        let mut p1 = vt100::Parser::new(24, 80, 0);
        p1.process(input);
        let snap = serialize_resume(p1.screen(), NO_LIMIT);
        let mut p2 = vt100::Parser::new(24, 80, 0);
        p2.process(&snap);
        assert_eq!(p1.screen().cursor_position(), p2.screen().cursor_position());
    }

    #[test]
    fn alt_buffer_active() {
        let input = b"primary content\x1b[?1049halt content";
        let mut p1 = vt100::Parser::new(24, 80, 0);
        p1.process(input);
        assert!(p1.screen().alternate_screen());
        let snap = serialize_resume(p1.screen(), NO_LIMIT);
        let s = String::from_utf8_lossy(&snap);
        assert!(
            s.contains("\x1b[?1049h"),
            "snap missing alt switch: {:?}",
            s
        );
        let mut p2 = vt100::Parser::new(24, 80, 0);
        p2.process(&snap);
        assert!(p2.screen().alternate_screen(), "restored parser not in alt");
        assert_eq!(p1.screen().contents(), p2.screen().contents());
    }

    #[test]
    fn complex_tui_redraw() {
        let mut input = Vec::new();
        input.extend_from_slice(b"\x1b[?1049h\x1b[2J\x1b[H");
        for _ in 0..23 {
            input.extend_from_slice(b"~\r\n");
        }
        input.extend_from_slice(b"\x1b[7m-- INSERT --\x1b[0m");
        let (orig, restored) = roundtrip(24, 80, &input);
        assert_eq!(orig, restored);
    }

    #[test]
    fn alt_then_primary_returns_primary() {
        let input = b"primary\x1b[?1049halt\x1b[?1049l";
        let mut p1 = vt100::Parser::new(24, 80, 0);
        p1.process(input);
        assert!(!p1.screen().alternate_screen());
        let snap = serialize_resume(p1.screen(), NO_LIMIT);
        let s = String::from_utf8_lossy(&snap);
        let preamble_end = HARD_RESET_AND_SAFE_MODES.len();
        let after_preamble = &s[preamble_end..];
        assert!(
            !after_preamble.contains("\x1b[?1049h"),
            "snap erroneously switches to alt: {:?}",
            after_preamble
        );
    }
}

#[cfg(test)]
mod history_tests {
    use super::*;

    const NO_LIMIT: usize = 1 << 20;

    fn payload(p: &vt100::Parser) -> String {
        String::from_utf8_lossy(&serialize_resume(p.screen(), NO_LIMIT)).into_owned()
    }

    /// 历史段与可见屏段**不得重叠**。
    ///
    /// 这曾经是靠「`history.len()` − 物理屏幕行数」剔出来的，而两个量不是同一个
    /// 单位（详见本文件头部）。现在两段同源同单位，不重叠是**结构性**的 ——
    /// scrollback 装的正是已经滚出可见区的行，与可见区没有交集。
    #[test]
    fn scrollback_and_visible_screen_do_not_overlap() {
        let mut p = vt100::Parser::new(6, 40, 1000);
        // 8 行输出，屏幕只有 6 行 —— 前几行滚出可见区，其余还在屏上。
        for i in 0..8 {
            p.process(format!("line{i}\r\n").as_bytes());
        }
        let text = payload(&p);
        for i in 0..8 {
            let hits = text.matches(&format!("line{i}")).count();
            assert_eq!(hits, 1, "line{i} 出现了 {hits} 次\n完整负载：\n{text}");
        }
    }

    /// 历史段与可见屏段之间必须复位属性：scrollback 最后一行可能以「属性开着」
    /// 结束（真实流里关闭它的字节属于当前屏那一段）。不复位，历史的 inverse /
    /// 背景色会漏进可见屏第一行。
    #[test]
    fn attributes_do_not_leak_from_scrollback_into_the_screen() {
        let mut p = vt100::Parser::new(3, 40, 1000);
        // 开着 inverse 换行，把这一行顶进 scrollback，然后可见屏是默认属性。
        p.process(b"\x1b[7mold history\r\n");
        p.process(b"filler1\r\nfiller2\r\nfiller3\r\n");
        p.process(b"screen line");

        let text = payload(&p);
        let hist_at = text.find("old history").expect("历史在");
        let scr_at = text.find("screen line").expect("当前屏在");
        assert!(
            text[hist_at..scr_at].contains("\x1b[0m"),
            "历史的属性会漏进当前屏 —— 两段之间必须复位\n{text:?}"
        );
    }

    /// 光标**下方**的内容不能被截掉。
    ///
    /// 原实现在 `i > cursor_row` 处 break，理由是「shell 刚起来时屏幕只有一行
    /// prompt，其余是未使用而非空行，全部输出会凭空造空行把历史推上去」。那对
    /// shell 成立（光标在最后一行），对 TUI 不成立：Claude Code 的输入框在屏幕
    /// 下部，光标落在框**内**，而框的下边框与 `auto mode on` 状态行都在
    /// cursor_row 之后 —— 一 break 就没了，真机上表现为「输入框没弹出来」。
    #[test]
    fn rows_below_the_cursor_are_kept() {
        // 80 列 —— 40 列会让 rows_formatted 的列优化把内容拆到下一行，断言就会
        // 挂在折行上而不是真正的缺失上。
        let mut p = vt100::Parser::new(6, 80, 0);
        p.process(b"scrollback line\r\n");
        p.process(b"---- top border ----\r\n");
        p.process(b"> typed text\r\n");
        p.process(b"---- bottom border ----\r\n");
        p.process(b"auto mode on");
        // 把光标移回输入行（第 2 行，0-based），列停在 "> typed text" 之后。
        p.process(b"\x1b[3;13H");
        assert_eq!(p.screen().cursor_position().0, 2, "precondition");

        let text = payload(&p);
        // rows_formatted 用相对列移动优化输出，长行会被拆到下一段字节里。那是
        // 它的编码格式，客户端终端渲染时会还原 —— 断言看扁平化后的内容，否则
        // 测的是编码细节而不是「有没有被截掉」。
        let flat = text.replace("\r\n", "").replace('\n', "");

        assert!(flat.contains("> typed text"), "输入行必须在\n{text}");
        assert!(
            flat.contains("bottom border"),
            "光标下方的下边框被截掉了\n{text}"
        );
        assert!(
            flat.contains("auto mode on"),
            "光标下方的状态行被截掉了\n{text}"
        );
        // 光标必须被抬回输入行：last_row(4) - cursor_row(2) = 2 行。
        assert!(text.contains("\x1b[2A"), "光标没抬回 cursor_row\n{text}");
    }

    /// 但也不能因此凭空造空行 —— 那是原来那个 break 要防的东西。
    #[test]
    fn unused_rows_below_the_cursor_do_not_become_blank_lines() {
        let mut p = vt100::Parser::new(10, 40, 0);
        p.process(b"$ ");
        let text = payload(&p);
        // 只有一行 prompt，后面 9 行从未用过 —— 不该出现一串换行。
        assert_eq!(
            text.matches("\r\n").count(),
            0,
            "未使用的行被输出成了空行\n{text:?}"
        );
    }

    /// `rows_formatted` 的每一行都**假设起始属性是默认值** —— 它只在属性偏离
    /// 默认时才输出 SGR。实测：
    ///
    ///   row0 = "\x1b[7mBLOCK"   ← 开了 inverse，行末不关
    ///   row1 = "plain second"    ← 单元是默认属性，于是一个 SGR 都不发
    ///
    /// 直接拼接就会让 row0 的 inverse 漏进 row1，整行变成反色块。真机症状：
    /// 恢复后输入框下边框和 `auto mode on` 状态行每个词都带背景块。
    #[test]
    fn attributes_do_not_leak_between_screen_rows() {
        let mut p = vt100::Parser::new(4, 20, 0);
        p.process(b"\x1b[7mBLOCK\x1b[0m\r\n");
        p.process(b"plain second\r\n");
        p.process(b"third");

        let text = payload(&p);
        let block_at = text.find("BLOCK").expect("BLOCK 在");
        let plain_at = text.find("plain second").expect("plain second 在");
        assert!(
            text[block_at..plain_at].contains("\x1b[0m"),
            "inverse 会漏进下一行 —— 两行之间必须复位属性\n{text:?}"
        );
    }

    /// 负载自带历史 → 必须自带清 scrollback，否则客户端每应用一次就多一份副本。
    ///
    /// 这条锁的是**字节**而不是行为，因为行为差异在服务端的 vt100 上看不见：
    /// `2J` 对它就是清屏，重复应用天然收敛 —— 副本只在 xterm.dart 那边长出来。
    /// 对应的行为断言在 `test/ssh/aqt/resume_screen_idempotence_test.dart`
    /// （真 xterm）。
    #[test]
    fn payload_clears_client_scrollback_before_writing() {
        let mut p = vt100::Parser::new(4, 20, 0);
        p.process(b"screen line");
        let text = payload(&p);
        assert!(
            text.starts_with(&format!(
                "{}\x1b[3J",
                String::from_utf8_lossy(HARD_RESET_AND_SAFE_MODES)
            )),
            "负载必须以「前缀 + ED 3」开头：{text:?}"
        );
        // 清 scrollback 必须发生在内容之前，否则清掉的正是刚画好的那些。
        assert!(
            text.find("\x1b[3J").unwrap() < text.find("screen line").unwrap(),
            "ED 3 必须在内容之前：{text:?}"
        );
    }

    /// **alt 负载同样清 scrollback，然后自己把 primary 历史补回来。**
    ///
    /// 这与上一版相反 —— 那时 alt 走单独的 `serialize`，刻意**不**发 `ED 3`，
    /// 理由是「alt 负载不带 primary 历史，清了只是白白抹掉用户 primary 里的
    /// 那份」。理由成立，但代价是客户端冷启动（本地 primary 本来就是空的）后
    /// 退出 TUI 会看到一片空白。
    ///
    /// 现在 alt 负载也带 primary 历史，清完立刻用权威版本填回来，两头都对。
    #[test]
    fn alt_payload_also_carries_primary_history() {
        let mut p = vt100::Parser::new(4, 20, 1000);
        p.process(b"PRIMARY-HISTORY\r\n");
        p.process(b"f1\r\nf2\r\nf3\r\nf4\r\n"); // 把上面那行顶进 scrollback
        p.process(b"\x1b[?1049hALT-CONTENT");
        assert!(p.screen().alternate_screen(), "precondition");

        let text = payload(&p);
        assert!(text.contains("\x1b[3J"), "alt 负载也该带 ED 3：{text:?}");
        assert!(
            text.contains("PRIMARY-HISTORY"),
            "alt 负载必须带上 primary 历史：{text:?}"
        );
        assert!(text.contains("ALT-CONTENT"), "alt 屏内容丢了：{text:?}");
        // 顺序：primary 历史必须在切进 alt **之前**写完，否则会画进 alt buffer。
        assert!(
            text.find("PRIMARY-HISTORY").unwrap() < text.find("\x1b[?1049h").unwrap(),
            "primary 历史必须先于 ?1049h：{text:?}"
        );
    }
}

#[cfg(test)]
mod budget_tests {
    use super::*;

    #[test]
    fn cut_keeps_the_newest_rows_within_budget() {
        let rows: Vec<Vec<u8>> = (0..10).map(|i| format!("row{i}").into_bytes()).collect();
        // 每行 4 字节 + 6 字节分隔符 = 10。预算 25 装得下 2 行（20），装不下 3 行（30）。
        assert_eq!(budget_cut(&rows, 25), 8, "该保留最新的 2 行");
    }

    #[test]
    fn cut_returns_len_when_budget_fits_nothing() {
        let rows: Vec<Vec<u8>> = vec![b"aaaaaaaa".to_vec()];
        // 一行成本 8 + 6 = 14 > 5，一行都发不了。
        assert_eq!(budget_cut(&rows, 5), 1);
    }

    #[test]
    fn cut_takes_everything_when_budget_is_ample() {
        let rows: Vec<Vec<u8>> = (0..5).map(|i| format!("row{i}").into_bytes()).collect();
        assert_eq!(budget_cut(&rows, 1 << 20), 0);
    }

    /// 预算只约束历史段 —— 可见屏无论多小的预算都要全发，否则「当前状态」
    /// 恢复不出来。
    #[test]
    fn visible_screen_survives_a_zero_budget() {
        let mut p = vt100::Parser::new(4, 20, 1000);
        p.process(b"OLD-HISTORY\r\n");
        p.process(b"f1\r\nf2\r\nf3\r\nf4\r\n");
        p.process(b"VISIBLE-NOW");

        let text = String::from_utf8_lossy(&serialize_resume(p.screen(), 0)).into_owned();
        assert!(text.contains("VISIBLE-NOW"), "可见屏被预算截掉了：{text:?}");
        assert!(
            !text.contains("OLD-HISTORY"),
            "预算为 0 时不该发历史：{text:?}"
        );
    }
}
