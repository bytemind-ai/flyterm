// SPDX-License-Identifier: GPL-3.0-or-later
//! 快照必须能表达客户端 painter 会渲染的全部属性。
//!
//! 客户端 xterm.dart 的 painter.dart 只读 inverse / faint / bold / italic /
//! underline 五个位（blink / invisible / strikethrough 存进 cell 但从不画）。
//! 其中 faint(dim) 是上游 vt100 唯一表达不了的那个 —— 也就是屏幕快照相对
//! 「raw 字节重放」唯一的可见差集。补齐它，快照即无损。

/// 与真实 RESUME 路径一致的历史预算（`connection.rs::RESUME_HISTORY_BYTES`）。
const BUDGET: usize = 256 * 1024;

#[test]
fn snapshot_preserves_dim() {
    let mut parser = vt100::Parser::new(4, 20, 0);
    parser.process(b"\x1b[2mdim text\x1b[0m");
    let out = flyterm_server::snapshot::serialize_resume(parser.screen(), BUDGET);
    let s = String::from_utf8_lossy(&out);
    assert!(
        s.contains("\x1b[2m"),
        "序列化结果里应当有 SGR 2；实际输出：{s:?}"
    );
}

#[test]
fn dim_survives_a_snapshot_roundtrip() {
    // 快照喂回一个干净 parser，属性必须还在 —— 这是「无损」的实际含义。
    let mut a = vt100::Parser::new(4, 20, 0);
    a.process(b"\x1b[2mdim\x1b[0m");
    let snap = flyterm_server::snapshot::serialize_resume(a.screen(), BUDGET);

    let mut b = vt100::Parser::new(4, 20, 0);
    b.process(&snap);

    let cell = b.screen().cell(0, 0).expect("row 0 col 0 应当有内容");
    assert!(cell.dim(), "dim 属性在快照往返后丢失了");
}

#[test]
fn dim_and_bold_are_independent() {
    // bold 与 dim 共用 SGR 22 关闭（ECMA-48 的 "normal intensity"）。
    // 序列化时若把「关 dim」写成裸 22 而不重发 bold，bold 就被顺手关掉了。
    let mut a = vt100::Parser::new(4, 40, 0);
    a.process(b"\x1b[1;2mboth\x1b[22m neither \x1b[1mbold only");
    let snap = flyterm_server::snapshot::serialize_resume(a.screen(), BUDGET);

    let mut b = vt100::Parser::new(4, 40, 0);
    b.process(&snap);

    let both = b.screen().cell(0, 0).unwrap();
    assert!(both.bold() && both.dim(), "开头那段该同时是 bold 与 dim");

    // "bold only" 段：22 之后重新开了 bold，dim 应当是关的。
    // 列号：both=0..3，" neither "=4..12，所以 "bold only" 从 13 起。
    let bold_only = b.screen().cell(0, 13).unwrap();
    assert_eq!(bold_only.contents(), "b", "列号算错了就测不到想测的那一格");
    assert!(
        bold_only.bold(),
        "22 之后重开的 bold 必须保留 —— 若序列化把它写成 `1;22`，\
         22 会把刚开的 bold 又关掉"
    );
    assert!(!bold_only.dim(), "那一段不该是 dim");
}

#[test]
fn sgr_22_clears_both_bold_and_dim() {
    let mut p = vt100::Parser::new(2, 20, 0);
    p.process(b"\x1b[1;2mx\x1b[22my");
    let y = p.screen().cell(0, 1).unwrap();
    assert!(!y.bold(), "SGR 22 必须关 bold");
    assert!(
        !y.dim(),
        "SGR 22 必须同时关 dim —— 只关 bold 会让 dim 永久粘住"
    );
}

#[test]
fn sgr_0_clears_dim() {
    let mut p = vt100::Parser::new(2, 20, 0);
    p.process(b"\x1b[2mx\x1b[0my");
    assert!(!p.screen().cell(0, 1).unwrap().dim());
}

// ── serialize_resume：历史 + 可见屏的流式组装 ──────────────────
//
// 历史不再由调用方注入，而是来自 parser 自己的 scrollback —— 所以这些用例
// 靠「喂足够多行把老行顶出可见区」来造历史，而不是构造一个 Vec。
// 这正是那一整类 bug 的修法：历史与可见屏出自同一个求值状态。

/// 把 content 重放进一个干净 parser，返回可见区每行的文本。
fn replay(content: &[u8], rows: u16, cols: u16) -> Vec<String> {
    let mut p = vt100::Parser::new(rows, cols, 0);
    p.process(content);
    (0..rows)
        .map(|r| {
            (0..cols)
                .filter_map(|c| p.screen().cell(r, c).map(|x| x.contents()))
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect()
}

fn payload(p: &vt100::Parser) -> Vec<u8> {
    flyterm_server::snapshot::serialize_resume(p.screen(), BUDGET)
}

#[test]
fn history_lands_above_the_current_screen() {
    // 3 行屏幕、喂 4 行 —— 前 3 行进 scrollback，末行留在屏上。
    let mut origin = vt100::Parser::new(3, 40, 100);
    origin.process(b"history 0\r\nhistory 1\r\nhistory 2\r\n");
    origin.process(b"$ echo current");

    let lines = replay(&payload(&origin), 6, 40);

    // 6 行可见区装下 3 行历史 + 1 行当前屏，历史在上。
    assert_eq!(lines[0], "history 0");
    assert_eq!(lines[1], "history 1");
    assert_eq!(lines[2], "history 2");
    assert_eq!(lines[3], "$ echo current");
}

#[test]
fn no_phantom_blank_lines_after_the_cursor() {
    // shell 刚起来时只有一行 prompt，其余是「未使用」而不是「空行」。
    // 全部逐行输出会凭空产生一堆空行，把历史推上去。
    let mut origin = vt100::Parser::new(2, 40, 100);
    origin.process(b"old line\r\n");
    // 屏高 2：再喂一行就把 "old line" 顶进 scrollback。
    origin.process(b"filler\r\n$ ");

    let lines = replay(&payload(&origin), 24, 40);

    assert_eq!(lines[0], "old line", "历史该在最上面");
    assert_eq!(lines[1], "filler");
    assert_eq!(lines[2], "$");
    assert_eq!(lines[3], "", "prompt 之后不该有凭空造出来的内容");
}

#[test]
fn cursor_column_is_restored() {
    let mut origin = vt100::Parser::new(6, 40, 0);
    // 写 prompt 再左移两格 —— 模拟用户按了左箭头。
    origin.process(b"$ hello\x1b[2D");
    let (_, want_col) = origin.screen().cursor_position();

    let mut back = vt100::Parser::new(6, 40, 0);
    back.process(&payload(&origin));

    assert_eq!(back.screen().cursor_position().1, want_col);
}

#[test]
fn streaming_content_is_idempotent() {
    // 客户端有六个 RESUME 发起点，正确性完全押在这条不变量上。
    let mut origin = vt100::Parser::new(3, 40, 100);
    origin.process(b"h0\r\nh1\r\n");
    origin.process(b"$ work");
    let content = payload(&origin);

    let once = replay(&content, 6, 40);

    let mut twice_parser = vt100::Parser::new(6, 40, 0);
    twice_parser.process(&content);
    twice_parser.process(&content);
    let twice: Vec<String> = (0..6)
        .map(|r| {
            (0..40)
                .filter_map(|c| twice_parser.screen().cell(r, c).map(|x| x.contents()))
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect();

    assert_eq!(twice, once, "重复应用必须收敛到同一屏");
}

#[test]
fn sgr_survives_the_streaming_path() {
    let mut origin = vt100::Parser::new(2, 40, 100);
    origin.process(b"\x1b[31mred history\x1b[0m\r\n");
    origin.process(b"filler\r\n");
    origin.process(b"\x1b[2mdim current\x1b[0m");

    let mut back = vt100::Parser::new(4, 40, 0);
    back.process(&payload(&origin));

    assert!(
        back.screen().cell(0, 0).unwrap().fgcolor() != vt100::Color::Default,
        "历史行的颜色要留住"
    );
    assert!(
        back.screen().cell(2, 0).unwrap().dim(),
        "当前屏的 dim 要留住"
    );
}

#[test]
fn history_can_never_carry_mode_changes() {
    // 历史里混进 `?1049h` 会把客户端切进 alt buffer —— 往上翻个历史就切屏，
    // 是很难查的那种坏。
    //
    // 上一版靠 `strip_mode_changes` 逐字节剥离来防这件事（历史是原始 PTY
    // 字节，什么都可能混在里面）。现在历史是从 vt100 的 **cell 网格**渲染出来
    // 的，只可能含 SGR 与列移动 —— 模式序列在结构上进不来，那个剥离函数连同
    // 它的五个测试一起删掉了。
    let mut origin = vt100::Parser::new(2, 40, 100);
    // 真进一次 alt 再出来，让 alt 相关字节确实流经 parser。
    origin.process(b"\x1b[?1049hsneaky\x1b[?1049l");
    origin.process(b"line a\r\nline b\r\n$ ");

    let mut back = vt100::Parser::new(4, 40, 0);
    back.process(&payload(&origin));

    assert!(!back.screen().alternate_screen(), "历史不该把终端切进 alt");
}
