// SPDX-License-Identifier: GPL-3.0-or-later
//! 「回放内容重复」的回归套件。
//!
//! 这四个场景曾经全部失败 —— 它们是同一个根因的四张脸：恢复负载的历史段来自
//! `LineRing`（原始 PTY 字节流按 `\n` 切的**逻辑行**），当前屏段来自 vt100
//! parser（**求值后的物理行**），两者之间用「逻辑行数 − 物理行数」这个减法对接。
//! 单位不匹配，调参只能修掉某一个特例；这条 bug 线上前后打了四个补丁
//! （`0157b42`、`29a8410`、`466e841`、`61997ca`），症状每次换个场景就回来。
//!
//! 现在历史与当前屏都从 parser 读，两段同源同单位，**没有去重要做**。
//! 详见 `src/snapshot.rs` 头部。
//!
//! 改动前的实测数字记在每个用例的注释里 —— 那是这些断言的分量所在。

use flyterm_server::snapshot::serialize_resume;

/// 与真实 RESUME 路径一致的预算（`connection.rs::RESUME_HISTORY_BYTES`）。
const BUDGET: usize = 256 * 1024;

/// 把一段真实 PTY 字节流喂给 parser —— 就是 `pty_task.rs` 读循环干的事。
///
/// scrollback 给 1000 行，与生产默认（`--scrollback-max-lines 3000`）同一个量级。
fn feed(rows: u16, cols: u16, chunks: &[&[u8]]) -> vt100::Parser {
    let mut parser = vt100::Parser::new(rows, cols, 1000);
    for c in chunks {
        parser.process(c);
    }
    parser
}

fn payload(parser: &vt100::Parser) -> String {
    String::from_utf8_lossy(&serialize_resume(parser.screen(), BUDGET)).into_owned()
}

/// 场景 1：**原地重绘**（`docker pull` / `cargo build` / powerlevel10k 两行
/// prompt —— 光标上移再重写同一批行）。
///
/// 改动前：负载里 20 份，屏幕上 1 份。每一轮重绘都往 ring 追加新的逻辑行，屏幕
/// 物理行数不变，而去重只剔 `last_row + 1` 行 —— 剩下的重绘残骸全被当成「历史」
/// 拼在当前屏上方。真机症状就是往上翻看到同一段进度条几十遍。
///
/// 改动后：parser 是终端仿真器，重绘天然收敛到最终状态。
#[test]
fn in_place_redraw_churn_is_not_replayed_as_history() {
    let mut chunks: Vec<Vec<u8>> = vec![b"$ docker pull img\r\n".to_vec()];
    // 20 轮进度重绘：写 3 行，再上移 3 行，下一轮盖掉它们。
    for pct in 0..20 {
        chunks.push(format!("Pulling layer a: {pct}%\r\n").into_bytes());
        chunks.push(format!("Pulling layer b: {pct}%\r\n").into_bytes());
        chunks.push(format!("Pulling layer c: {pct}%\r\n").into_bytes());
        if pct < 19 {
            chunks.push(b"\x1b[3A".to_vec());
        }
    }
    let refs: Vec<&[u8]> = chunks.iter().map(|c| c.as_slice()).collect();
    let parser = feed(24, 80, &refs);

    let on_screen = parser.screen().contents();
    assert_eq!(
        on_screen.matches("Pulling layer a").count(),
        1,
        "前置条件：屏幕上只该有一份进度行，实际屏幕：\n{on_screen}"
    );

    let text = payload(&parser);
    let hits = text.matches("Pulling layer a").count();
    assert_eq!(
        hits, 1,
        "恢复负载里「Pulling layer a」出现了 {hits} 次，屏幕上只有 1 次。\n\
         重绘残骸被当成历史回放了。"
    );
}

/// 场景 2：**alt buffer 污染**。ring 曾经无条件吞下每一个 PTY 字节，包括全屏
/// TUI（vim / htop / claude）在 alt buffer 里刷的每一帧。退出 alt 后 primary
/// 屏幕恢复原样，ring 尾部却全是 TUI 的帧内容 —— 它们从来不属于 primary 的
/// scrollback。
///
/// 改动前：71 行 TUI 帧内容混进 primary 历史。
///
/// 改动后：vt100 的 alt grid 恒以 `scrollback_len: 0` 创建，帧进不了 primary
/// scrollback —— 是结构性的，不是过滤出来的。
#[test]
fn alt_buffer_frames_do_not_leak_into_primary_history() {
    let mut chunks: Vec<Vec<u8>> = vec![b"$ echo before\r\nbefore\r\n$ vim\r\n".to_vec()];
    // 进 alt，刷 15 帧，每帧 5 行，然后退出 alt。
    chunks.push(b"\x1b[?1049h".to_vec());
    for frame in 0..15 {
        chunks.push(b"\x1b[H".to_vec());
        for line in 0..5 {
            chunks.push(format!("VIM-FRAME{frame}-LINE{line}\r\n").into_bytes());
        }
    }
    chunks.push(b"\x1b[?1049l".to_vec());
    chunks.push(b"$ ".to_vec());

    let refs: Vec<&[u8]> = chunks.iter().map(|c| c.as_slice()).collect();
    let parser = feed(24, 80, &refs);

    assert!(
        !parser.screen().alternate_screen(),
        "前置条件：已经退出 alt buffer"
    );
    let on_screen = parser.screen().contents();
    assert!(
        !on_screen.contains("VIM-FRAME"),
        "前置条件：primary 屏幕上不该有 TUI 帧内容，实际：\n{on_screen}"
    );

    let text = payload(&parser);
    let vim_lines = text.matches("VIM-FRAME").count();
    assert_eq!(
        vim_lines, 0,
        "恢复负载里混进了 {vim_lines} 行 alt buffer 的 TUI 帧内容 —— \
         用户往上翻会看到 vim 的画面被摊平重复多遍。"
    );
    assert!(
        text.contains("before"),
        "alt 之前的 primary 历史必须还在：\n{text}"
    );
}

/// 场景 3：**折行**。`LineRing` 存逻辑行（刻意的设计：客户端按当前宽度自己折），
/// 屏幕给的是物理行。一条超过 cols 的逻辑行占 2+ 物理行，于是
/// `history.len() - (last_row + 1)` 剔掉的逻辑行数**多于**当前屏实际覆盖的
/// —— 真历史被静默丢掉。手机终端列数窄，长行折行是常态而非边缘情况。
///
/// 改动前：`KEEP-ME-OLDEST` 与 L0–L3 全丢，只剩 L4/L5。
///
/// 改动后：两段都是**同一宽度下的物理行**，不存在单位换算。
#[test]
fn wrapped_lines_do_not_drop_real_history() {
    // 20 列，每行 45 字符 → 每条逻辑行占 3 物理行。
    let mut chunks: Vec<Vec<u8>> = vec![b"KEEP-ME-OLDEST\r\n".to_vec()];
    for i in 0..6 {
        chunks.push(format!("L{i}-{}\r\n", "x".repeat(40)).into_bytes());
    }
    let refs: Vec<&[u8]> = chunks.iter().map(|c| c.as_slice()).collect();
    let parser = feed(8, 20, &refs);

    let text = payload(&parser);
    assert!(
        text.contains("KEEP-ME-OLDEST"),
        "最老的那行真历史被丢掉了：\n{text}"
    );
    for i in 0..6 {
        assert!(text.contains(&format!("L{i}-")), "L{i} 丢了：\n{text}");
    }
}

/// 场景 4：**`clear` 之后**。屏幕被清空只剩 prompt，ring 却仍持有清屏之前的
/// 一切（它不认识 ED 2 / ED 3），于是被用户 `clear` 掉的内容全部作为「历史」
/// 回放回来。
///
/// 改动前：9 行已清掉的内容回放回来。
///
/// 改动后：`ED 3` 由 vt100 真正实现（vendored 补的，上游把 mode 3 落进
/// `unhandled ED mode`），scrollback 被清空。
#[test]
fn cleared_content_does_not_come_back_as_history() {
    let mut chunks: Vec<Vec<u8>> = Vec::new();
    for i in 0..10 {
        chunks.push(format!("SECRET-LINE-{i}\r\n").into_bytes());
    }
    // clear(1) 干的事：ED 2 + 光标归位 + ED 3（清 scrollback）。
    chunks.push(b"\x1b[H\x1b[2J\x1b[3J$ ".to_vec());

    let refs: Vec<&[u8]> = chunks.iter().map(|c| c.as_slice()).collect();
    let parser = feed(24, 80, &refs);

    let on_screen = parser.screen().contents();
    assert!(
        !on_screen.contains("SECRET-LINE"),
        "前置条件：clear 之后屏幕上不该有内容，实际：\n{on_screen}"
    );

    let text = payload(&parser);
    let hits = text.matches("SECRET-LINE").count();
    assert_eq!(
        hits, 0,
        "被 clear 掉的内容有 {hits} 行作为「历史」回放回来了。"
    );
}

/// 场景 5：**恢复负载必须幂等**。
///
/// 客户端有六个 RESUME 发起点，`session_resume_coordinator.dart` 只合并在途
/// 请求、不保证只发一次 —— 正确性完全押在负载的幂等上。
///
/// 在服务端的 vt100 上「重复应用收敛」是必要条件（不是充分条件：`ED 3` 对
/// vt100 的影响看不出来，因为它没有 scrollback 语义上的副本累积）。客户端真
/// xterm 上的行为断言在 `test/ssh/aqt/resume_screen_idempotence_test.dart`。
#[test]
fn applying_the_payload_twice_converges() {
    let parser = feed(
        10,
        40,
        &[b"line0\r\nline1\r\nline2\r\nline3\r\nline4\r\n", b"$ "],
    );
    let text = payload(&parser);

    let mut once = vt100::Parser::new(10, 40, 1000);
    once.process(text.as_bytes());
    let mut twice = vt100::Parser::new(10, 40, 1000);
    twice.process(text.as_bytes());
    twice.process(text.as_bytes());

    assert_eq!(
        once.screen().contents(),
        twice.screen().contents(),
        "应用两次与一次的可见屏不同 —— 负载不幂等"
    );
    assert_eq!(
        once.screen().cursor_position(),
        twice.screen().cursor_position(),
        "应用两次后光标位置漂了"
    );
}

/// 场景 6：**alt 会话也要带上 primary 历史**。
///
/// 上一版 alt 走单独的 `serialize`，只发 alt 屏。客户端冷启动（本地 primary
/// 本来就是空的）时在 TUI 里恢复，退出 TUI 后看到的是一片空白 primary ——
/// 服务端明明还留着那段历史。
#[test]
fn alt_session_payload_carries_primary_history() {
    let parser = feed(
        6,
        40,
        &[
            b"$ echo hello\r\nhello\r\n$ tail -f log\r\n",
            b"pad1\r\npad2\r\npad3\r\npad4\r\npad5\r\n",
            b"\x1b[?1049hTUI-SCREEN",
        ],
    );
    assert!(parser.screen().alternate_screen(), "前置条件：在 alt 里");

    let text = payload(&parser);
    assert!(text.contains("TUI-SCREEN"), "alt 屏内容丢了：\n{text}");
    assert!(
        text.contains("hello"),
        "alt 负载必须带上 primary 历史：\n{text}"
    );
    // 顺序：primary 段必须在切进 alt **之前**写完，否则会画进 alt buffer。
    assert!(
        text.find("hello").unwrap() < text.find("\x1b[?1049h").unwrap(),
        "primary 历史必须先于 ?1049h：\n{text}"
    );
}
