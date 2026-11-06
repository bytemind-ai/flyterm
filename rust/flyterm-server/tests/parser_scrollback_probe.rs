// SPDX-License-Identifier: GPL-3.0-or-later
//! 探针：验证「scrollback ++ 可见屏」能从 vt100 parser 读成一条连续的物理
//! 行流，且四个失效场景全部天然正确。这是修复方案的承重机制。

/// scrollback 行 + 可见屏行，最旧在前。两段都是当前宽度下的物理行。
fn all_rows(p: &vt100::Parser) -> Vec<String> {
    let (_rows, cols) = p.screen().size();
    let mut out: Vec<String> = p
        .screen()
        .scrollback_rows_formatted(0, cols)
        .map(|r| String::from_utf8_lossy(&r).into_owned())
        .collect();
    out.extend(p.screen().rows(0, cols));
    out
}

#[test]
fn scrollback_plus_screen_is_a_contiguous_row_stream() {
    let mut p = vt100::Parser::new(6, 40, 1000);
    for i in 0..20 {
        p.process(format!("line{i}\r\n").as_bytes());
    }
    let rows = all_rows(&p);
    let joined: Vec<String> = rows.iter().map(|s| s.trim_end().to_string()).collect();
    for i in 0..20 {
        let needle = format!("line{i}");
        let hits = joined.iter().filter(|r| r.ends_with(&needle)).count();
        assert_eq!(hits, 1, "line{i} 出现 {hits} 次，完整流：{joined:?}");
    }
    let first = joined.iter().position(|r| r.ends_with("line0")).unwrap();
    let last = joined.iter().position(|r| r.ends_with("line19")).unwrap();
    assert!(first < last, "顺序错了：{joined:?}");
}

#[test]
fn alt_buffer_frames_never_enter_primary_scrollback() {
    let mut p = vt100::Parser::new(6, 40, 1000);
    for i in 0..10 {
        p.process(format!("primary{i}\r\n").as_bytes());
    }
    p.process(b"\x1b[?1049h");
    for f in 0..30 {
        p.process(format!("\x1b[HVIM-FRAME{f}\r\n").as_bytes());
    }
    p.process(b"\x1b[?1049l");
    let text = all_rows(&p).join("\n");
    assert!(
        !text.contains("VIM-FRAME"),
        "alt 帧漏进 primary scrollback：\n{text}"
    );
    assert!(
        text.contains("primary0"),
        "alt 之前的 primary 历史丢了：\n{text}"
    );
}

#[test]
fn in_place_redraw_collapses_to_final_state() {
    let mut p = vt100::Parser::new(8, 80, 1000);
    p.process(b"$ docker pull img\r\n");
    for pct in 0..20 {
        p.process(format!("Pulling layer a: {pct}%\r\n").as_bytes());
        p.process(format!("Pulling layer b: {pct}%\r\n").as_bytes());
        p.process(format!("Pulling layer c: {pct}%\r\n").as_bytes());
        if pct < 19 {
            p.process(b"\x1b[3A");
        }
    }
    let text = all_rows(&p).join("\n");
    let hits = text.matches("Pulling layer a").count();
    assert_eq!(hits, 1, "重绘残骸没有收敛，出现 {hits} 次：\n{text}");
}

#[test]
fn ed3_clear_wipes_scrollback() {
    let mut p = vt100::Parser::new(6, 40, 1000);
    for i in 0..30 {
        p.process(format!("SECRET{i}\r\n").as_bytes());
    }
    p.process(b"\x1b[H\x1b[2J\x1b[3J$ ");
    let text = all_rows(&p).join("\n");
    let hits = text.matches("SECRET").count();
    assert_eq!(hits, 0, "clear 之后仍有 {hits} 行残留：\n{text}");
}

#[test]
fn wrapped_long_lines_stay_physical_rows_on_both_sides() {
    // 20 列，每行 45 字符 → 每条逻辑行占 3 物理行。两段都是物理行，
    // 不存在「逻辑行 vs 物理行」的单位不匹配。
    let mut p = vt100::Parser::new(8, 20, 1000);
    p.process(b"KEEP-ME-OLDEST\r\n");
    for i in 0..6 {
        p.process(format!("L{i}-{}\r\n", "x".repeat(40)).as_bytes());
    }
    let text = all_rows(&p).join("\n");
    assert!(
        text.contains("KEEP-ME-OLDEST"),
        "最老的真历史丢了：\n{text}"
    );
    for i in 0..6 {
        assert!(text.contains(&format!("L{i}-")), "L{i} 丢了：\n{text}");
    }
}
