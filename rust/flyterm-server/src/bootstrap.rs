// SPDX-License-Identifier: GPL-3.0-or-later
pub struct BootstrapInfo<'a> {
    pub version: u8,
    pub port: u16,
    pub spki_base64: &'a str,
    pub token: &'a [u8; 32],
}

impl BootstrapInfo<'_> {
    pub fn format(&self) -> String {
        let token_b64 = crate::b64::encode_no_pad(self.token);
        format!(
            "AQT_VER={}\nAQT_PORT={}\nAQT_PUBKEY={}\nAQT_TOKEN={}\n",
            self.version, self.port, self.spki_base64, token_b64
        )
    }

    pub fn print_to_stdout(&self) -> std::io::Result<()> {
        use std::io::Write;
        let s = self.format();
        std::io::stdout().write_all(s.as_bytes())?;
        std::io::stdout().flush()
    }
}

/// Decide what `--status` should print given the contents of `daemon.info`.
///
/// The file records `AQT_PID=<pid>` of the daemon that wrote it. A daemon can
/// die without cleaning up (SIGKILL, OOM, crash, host reboot), leaving a stale
/// `daemon.info` behind. If `--status` printed it verbatim, the App would fire
/// a QUIC handshake at a port nobody listens on and time out after 5s
/// ("Future not completed"). So we verify liveness first.
///
/// Returns:
/// - `Some(content)` — the daemon is alive (or the file predates the AQT_PID
///   line, in which case we preserve the legacy trust-it behavior); print it.
/// - `None` — the recorded PID is dead; caller should delete the stale file
///   and print nothing so the App bootstraps a fresh daemon.
///
/// `is_alive` is injected so the decision logic is unit-testable without a
/// real process; production passes a `/proc/<pid>/exe` existence check.
pub fn daemon_info_if_alive(content: &str, is_alive: impl Fn(i32) -> bool) -> Option<String> {
    let pid = content.lines().find_map(|line| {
        line.strip_prefix("AQT_PID=")
            .and_then(|v| v.trim().parse::<i32>().ok())
    });
    match pid {
        // No AQT_PID line: legacy daemon predating this field. Preserve the
        // old behavior (trust the file) rather than wiping a possibly-live one.
        None => Some(content.to_string()),
        Some(pid) if is_alive(pid) => Some(content.to_string()),
        Some(_) => None,
    }
}

/// `daemon.sessions` 的内容：活跃会话数，由 daemon 定期刷新。
///
/// 单独一个文件而不是改写 `daemon.info`：后者在启动时写一次就不再动，
/// 它的存在与否本身就是「daemon 起来了」的信号，不该被周期性重写打扰。
pub fn sessions_line(count: usize) -> String {
    format!("AQT_SESSIONS={count}\n")
}

/// `--status` 的完整输出：活着的 daemon 的 `daemon.info`，再加上
/// `daemon.sessions` 里的会话数（格式不对就忽略 —— 会话数只用于提示，
/// 不能因为它坏了让 App 连不上）。
pub fn status_output(
    info: &str,
    sessions: Option<&str>,
    is_alive: impl Fn(i32) -> bool,
) -> Option<String> {
    let mut out = daemon_info_if_alive(info, is_alive)?;
    let count = sessions.and_then(|s| {
        s.lines().find_map(|l| {
            l.strip_prefix("AQT_SESSIONS=")?
                .trim()
                .parse::<usize>()
                .ok()
        })
    });
    if let Some(n) = count {
        out.push_str(&sessions_line(n));
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_appends_session_count_when_alive() {
        let info = "AQT_PORT=61005\nAQT_PUBKEY=x\nAQT_VERSION=v\nAQT_PID=1234\n";
        let out = status_output(info, Some("AQT_SESSIONS=3\n"), |_| true).unwrap();
        assert!(out.starts_with(info), "{out:?}");
        assert!(out.ends_with("AQT_SESSIONS=3\n"), "{out:?}");
    }

    #[test]
    fn status_without_sessions_file_has_no_count() {
        let info = "AQT_PORT=61005\nAQT_PID=1234\n";
        assert_eq!(status_output(info, None, |_| true).as_deref(), Some(info));
    }

    #[test]
    fn status_ignores_malformed_sessions_file() {
        let info = "AQT_PORT=61005\nAQT_PID=1234\n";
        for junk in [
            "",
            "AQT_SESSIONS=",
            "AQT_SESSIONS=abc\n",
            "garbage\nAQT_PORT=1\n",
        ] {
            assert_eq!(
                status_output(info, Some(junk), |_| true).as_deref(),
                Some(info),
                "{junk:?}"
            );
        }
    }

    #[test]
    fn status_dead_daemon_prints_nothing_even_with_sessions_file() {
        let info = "AQT_PORT=61005\nAQT_PID=1234\n";
        assert_eq!(
            status_output(info, Some("AQT_SESSIONS=3\n"), |_| false),
            None
        );
    }

    #[test]
    fn sessions_line_format() {
        assert_eq!(sessions_line(0), "AQT_SESSIONS=0\n");
        assert_eq!(sessions_line(12), "AQT_SESSIONS=12\n");
    }

    #[test]
    fn daemon_info_alive_pid_is_printed() {
        let content = "AQT_PORT=42041\nAQT_PUBKEY=x\nAQT_VERSION=v\nAQT_PID=1234\n";
        assert_eq!(
            daemon_info_if_alive(content, |pid| pid == 1234),
            Some(content.to_string()),
        );
    }

    #[test]
    fn daemon_info_dead_pid_returns_none() {
        let content = "AQT_PORT=42041\nAQT_PUBKEY=x\nAQT_VERSION=v\nAQT_PID=1756160\n";
        assert_eq!(daemon_info_if_alive(content, |_| false), None);
    }

    #[test]
    fn daemon_info_missing_pid_line_is_trusted() {
        // Legacy file without AQT_PID: keep old trust-it behavior.
        let content = "AQT_PORT=42041\nAQT_PUBKEY=x\nAQT_VERSION=v\n";
        assert_eq!(
            daemon_info_if_alive(content, |_| false),
            Some(content.to_string()),
        );
    }

    #[test]
    fn format_contains_required_keys() {
        let info = BootstrapInfo {
            version: 1,
            port: 51232,
            spki_base64: "MFowDQXYZ",
            token: &[0xAA; 32],
        };
        let s = info.format();
        assert!(s.contains("AQT_VER=1\n"), "missing AQT_VER");
        assert!(s.contains("AQT_PORT=51232\n"), "missing AQT_PORT");
        assert!(s.contains("AQT_PUBKEY=MFowDQXYZ\n"), "missing AQT_PUBKEY");
        assert!(s.contains("AQT_TOKEN="), "missing AQT_TOKEN");
        // All lines must be KEY=VALUE format
        for line in s.lines() {
            assert!(line.contains('='), "line missing '=': {line}");
            assert!(line.starts_with("AQT_"), "line missing AQT_ prefix: {line}");
        }
    }
}
