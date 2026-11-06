// SPDX-License-Identifier: GPL-3.0-or-later
/// 通知文本上限。超出部分直接截断——通知栏本来也只显示两三行。
pub const MAX_NOTIFY_BYTES: usize = 512;

/// `char::is_control()` 只覆盖 Unicode 通用类别 Cc（C0/C1 控制码），漏掉两类
/// 同样能破坏"一行安全文本"这个承诺的码点：
///   - U+2028/U+2029（Zl/Zp，行/段分隔符）—— 很多渲染引擎（包括 Android 通知栏）
///     把它们当强制换行处理，`trim()` 只清理首尾，挡不住出现在文本中间的这两个码点。
///   - U+202A..U+202E、U+2066..U+2069、U+200E/U+200F、U+061C（Cf，双向控制符）
///     —— 可以让通知栏文字视觉上被反转或拼接来误导用户，是 Trojan Source 攻击
///     用的同一类技巧。这个函数是消毒的唯一关口，输入又完全不可信
///     （如 `flyterm notify "$(cat somefile)"`），必须显式挡住。
fn is_display_hazard(c: char) -> bool {
    matches!(c,
        '\u{2028}' | '\u{2029}'
        | '\u{202A}'..='\u{202E}'
        | '\u{2066}'..='\u{2069}'
        | '\u{200E}' | '\u{200F}' | '\u{061C}'
    )
}

/// 把任意用户输入变成可以安全塞进通知栏的一行文本。
///
/// 三件事：
/// - 控制字符（含上面列出的换行/双向控制类码点）换成空格——例如去掉 ESC 字节
///   本身，避免下游把它当转义序列的起始符解释；序列其余部分（如 `[31m`）作为
///   普通文本原样保留，并不会被整体清理掉。
/// - 首尾空白裁剪。
/// - 按字符边界截断到 MAX_NOTIFY_BYTES（按字节直接切会切碎多字节字符，产生
///   非法 UTF-8）。注意：这只保证不切碎单个 char，不保证不切碎跨多个 char 的
///   字形簇（如 emoji 修饰序列）——通知栏文本本来就可能被截断，为这个显示层面
///   的小瑕疵引入 unicode-segmentation 依赖不划算，这是有意接受的取舍。
pub fn sanitize_notify_text(input: &str) -> String {
    let cleaned: String = input
        .chars()
        .map(|c| {
            if c.is_control() || is_display_hazard(c) {
                ' '
            } else {
                c
            }
        })
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.len() <= MAX_NOTIFY_BYTES {
        return trimmed.to_string();
    }
    let mut end = MAX_NOTIFY_BYTES;
    while end > 0 && !trimmed.is_char_boundary(end) {
        end -= 1;
    }
    trimmed[..end].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_passes_through() {
        assert_eq!(sanitize_notify_text("构建完成"), "构建完成");
    }

    #[test]
    fn control_chars_become_spaces() {
        // 去掉 ESC 字节本身，避免下游把它当转义序列起始符解释；序列其余
        // 部分（这里是 `[31m`）作为普通文本原样保留，不会被整体清理掉。
        assert_eq!(sanitize_notify_text("a\x1b[31mb\nc"), "a [31mb c");
    }

    #[test]
    fn line_and_paragraph_separators_become_spaces() {
        // U+2029 不属于 Cc，`is_control()` 抓不到；很多渲染引擎（含 Android
        // 通知栏）把它当强制换行，会击穿"一行文本"的承诺，必须显式挡住。
        assert_eq!(sanitize_notify_text("ok\u{2029}pwned"), "ok pwned");
    }

    #[test]
    fn bidi_override_becomes_space() {
        // U+202E 是 Cf 类双向控制符，能让通知栏文字视觉上被反转/拼接来
        // 误导用户（Trojan Source 同类技巧），同样不属于 Cc，必须显式挡住。
        assert_eq!(sanitize_notify_text("a\u{202E}b"), "a b");
    }

    #[test]
    fn surrounding_whitespace_trimmed() {
        assert_eq!(sanitize_notify_text("  done\n"), "done");
    }

    #[test]
    fn exactly_at_limit_is_not_truncated() {
        // 锁定边界处的字节数不变量：长度恰好等于上限时一个字节都不该少。
        // 现有的超长测试都用 1000 字符，永远走截断分支，摸不到这个点。
        //
        // 注意别把这条当成"防止实现里的 `<=` 被误改成 `<`"的护栏——那是个
        // 等价变异，改了输出也不变：is_char_boundary(idx) 在 idx > len 时
        // 返回 false 而非 panic，所以掉进截断循环也会立刻停在同一位置。
        // 那行 `<=` 是给短文本省掉回退扫描的性能优化，不是正确性分支。
        assert_eq!(sanitize_notify_text(&"x".repeat(512)).len(), 512);
    }

    #[test]
    fn one_byte_over_limit_truncates_to_limit() {
        assert_eq!(sanitize_notify_text(&"x".repeat(513)).len(), 512);
    }

    #[test]
    fn truncates_to_512_bytes() {
        let long = "x".repeat(1000);
        assert_eq!(sanitize_notify_text(&long).len(), 512);
    }

    #[test]
    fn truncation_never_splits_a_utf8_char() {
        // 512 不是 3 的倍数，直接切会切碎汉字产生非法 UTF-8。
        let long = "中".repeat(1000);
        let out = sanitize_notify_text(&long);
        assert!(out.len() <= 512);
        assert_eq!(out.len() % 3, 0, "必须落在字符边界上");
        assert!(std::str::from_utf8(out.as_bytes()).is_ok());
    }

    #[test]
    fn truncation_may_split_a_grapheme_cluster_by_design() {
        // 有意接受的取舍：只保证不切碎单个 char / 不产生非法 UTF-8，不保证
        // 不切碎跨多个 char 的字形簇（如 emoji + 变体选择符/肤色修饰符）。
        // 这里用 "e" + U+0301 COMBINING ACUTE ACCENT（é 的组合形式，2 个
        // char、3 字节）构造一个恰好会在边界上被切开组合字符的场景：不应
        // panic，且输出必须仍是合法 UTF-8。这不是 bug，是已知取舍——不要
        // 把它当新问题重新排查。
        let combining = "e\u{0301}".repeat(200); // 200 * 3 = 600 字节 > 512
        let out = sanitize_notify_text(&combining);
        assert!(out.len() <= 512);
        assert!(std::str::from_utf8(out.as_bytes()).is_ok());
    }

    #[test]
    fn empty_input_yields_empty() {
        assert_eq!(sanitize_notify_text(""), "");
        assert_eq!(sanitize_notify_text("   "), "");
    }
}
