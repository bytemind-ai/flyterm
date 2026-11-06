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

#[cfg(test)]
mod tests {
    use super::*;

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
