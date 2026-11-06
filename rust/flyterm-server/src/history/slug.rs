// SPDX-License-Identifier: GPL-3.0-or-later
pub fn slugify(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut last_dash = true; // prevent leading dash
    for ch in input.chars().take(256) {
        let lower = ch.to_ascii_lowercase();
        let safe = matches!(lower, 'a'..='z' | '0'..='9');
        if safe {
            out.push(lower);
            last_dash = false;
        } else if !last_dash {
            out.push('-');
            last_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    if out.len() > 64 {
        out.truncate(64);
        while out.ends_with('-') {
            out.pop();
        }
    }
    if out.is_empty() {
        return "default".to_string();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::slugify;

    #[test]
    fn slug_lowercase_alphanumeric() {
        assert_eq!(slugify("claude"), "claude");
        assert_eq!(slugify("Claude"), "claude");
    }

    #[test]
    fn slug_spaces_become_dashes() {
        assert_eq!(slugify("claude code"), "claude-code");
    }

    #[test]
    fn slug_collapses_repeats_and_trims() {
        assert_eq!(slugify("  hello  world  "), "hello-world");
        assert_eq!(slugify("a//b\\c"), "a-b-c");
    }

    #[test]
    fn slug_empty_to_default() {
        assert_eq!(slugify(""), "default");
        assert_eq!(slugify("   "), "default");
    }

    #[test]
    fn slug_max_64_chars() {
        let long = "a".repeat(200);
        assert!(slugify(&long).len() <= 64);
    }

    #[test]
    fn slug_path_traversal_safe() {
        assert!(!slugify("../etc/passwd").contains(".."));
        assert!(!slugify("/etc/passwd").contains('/'));
    }
}
