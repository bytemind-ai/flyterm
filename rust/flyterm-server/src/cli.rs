// SPDX-License-Identifier: GPL-3.0-or-later
use std::path::PathBuf;

/// 拥塞控制算法。发送端才生效 —— RESUME 的 prelude 是 server→client，所以
/// 这个选择只装在服务端的 `TransportConfig` 上，客户端不需要对应开关。
///
/// 为什么值得有这个开关：CUBIC 这类 loss-based 算法的吞吐上限约等于
/// `MSS / (RTT × √p)`。真机现场 RTT 82 ms、丢包 1.1%、MTU 1200 B，代入得
/// ≈139 KB/s，而实测恢复快照 267993 B 用了 1827 ms ≈ 147 KB/s —— 差 5% 以内。
/// 也就是说恢复慢不是路径带宽不够，是 CUBIC 把移动网络的**随机**丢包当成了
/// 拥塞信号在砍窗（现场 cwnd 只有 8 KB）。BBR 按「带宽 × RTT」建模、不把丢包
/// 当拥塞信号，正好绕开这个上限。
///
/// 但它不是免费的，所以默认仍是 CUBIC，得显式 `--congestion bbr` 才启用：
///   * quinn-proto 0.10.6 的 BBR 实现自己标着 `Experimental! Use at your own
///     risk.`，是 Chromium quiche 的 **BBRv1** 移植，不是 v2/v3。
///   * BBRv1 的 ProbeRTT 每约 10 s 把 cwnd 压到 4 个包、持续 200 ms。跑大流量
///     无所谓，但这是**交互式终端**，可能表现成周期性的小顿挫。
///   * 恢复恰好是 BBR 最不占便宜的场景：连接刚建立、没有历史带宽样本，前 2-3
///     个 RTT 走 STARTUP 指数爬升，与慢启动没区别，收益从第 3-5 个 RTT 才出来。
///
/// 换句话说这是个待验证的假设，不是已知的改进。开关的意义就是让真机 A/B 能
/// 一条命令切换，而不是靠重新编译。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CongestionKind {
    Cubic,
    Bbr,
}

impl CongestionKind {
    /// 未知值返回 None —— 由调用方决定是报错退出还是回退默认。
    pub fn parse(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "cubic" => Some(Self::Cubic),
            "bbr" => Some(Self::Bbr),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cubic => "cubic",
            Self::Bbr => "bbr",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Cli {
    pub once: bool,
    pub listen: Option<u16>,
    pub bind: String,
    pub max_sessions: u32,
    pub max_tabs_per_session: u32,
    pub max_concurrent_files: u32,
    pub ring_size_mb: u32,
    /// vt100 parser 保留多少行 primary scrollback —— 也就是「用户恢复后能往上
    /// 翻多远」。
    ///
    /// 默认从 20000 降到 3000，因为存储介质换了：这个值以前给的是按字节存原始
    /// 流的 `LineRing`（每行只占它自己那么多字节），现在给的是 vt100 的 cell
    /// 网格，每行恒定 `cols × size_of::<Cell>()` = 80 × 36 B ≈ 2.8 KB。
    /// 20000 行会是 **57 MB/tab**，16 tab 直接 900 MB。
    ///
    /// 3000 与客户端 `Terminal(maxLines: 3000)` 对齐 —— 再多客户端也显示不了。
    /// 上界夹到 20000（≈57 MB/tab），够任何合理用法，又挡住手滑打成 200000。
    pub scrollback_max_lines: u32,
    pub allow_anywhere: bool,
    pub log_file: Option<PathBuf>,
    pub state_dir: Option<PathBuf>,
    pub term: String,
    pub grace_seconds: u64,
    pub once_port: Option<u16>,
    pub status: bool,
    /// Runtime kill switch for LZ4 compression. Even when the `compression`
    /// cargo feature is compiled in, this flag forces `allow_compression=false`
    /// at connection-config time, so HELLO_ACK never advertises CAP_LZ4 and
    /// the client falls back to the raw byte path. Used to isolate compression
    /// from other rendering / byte-loss issues during diagnosis.
    pub no_compression: bool,
    /// 拥塞控制算法，默认 CUBIC。见 [`CongestionKind`] 上关于为什么需要这个
    /// 开关、以及 BBR 的代价的说明。
    pub congestion: CongestionKind,
    /// `--install` subcommand: this binary installs itself as the
    /// daemon. Kills the running daemon (if any), atomically replaces
    /// the binary at the canonical path, spawns the new daemon, and
    /// prints `INSTALL_OK port=N pid=N version=V` or `INSTALL_ERR
    /// reason=...` on stdout. Exits 0 on success, 1 on error, 2 if
    /// another --install is in progress (flock held).
    pub install: bool,
    /// `notify <text>` 子命令：把一条消息投给本机 daemon 的 unix socket
    /// 然后退出。裸子命令而非 flag，因为它是用户手打进
    /// `make && flyterm notify "done"` 这类命令链的。
    pub notify: Option<String>,
}

impl Cli {
    pub fn parse() -> Self {
        let raw: Vec<String> = std::env::args().collect();
        let args: Vec<&str> = raw.iter().map(String::as_str).collect();
        Self::parse_from(&args)
    }

    pub fn parse_from(args: &[&str]) -> Self {
        // 裸子命令必须最先识别，早于 --help/--version 这些用 contains() 扫
        // 整个 argv 的检查。否则 `flyterm notify "见 --help"` 会打印用法并
        // 退出，通知被静默吞掉——而正文里出现 --help 完全是合理的。
        if args.get(1) == Some(&"notify") {
            let text = args[2..].join(" ");
            let mut cli = Self::defaults();
            cli.notify = Some(text);
            return cli;
        }

        if args.contains(&"--help") || args.contains(&"-h") {
            print!("{}", Self::usage());
            std::process::exit(0);
        }

        // --version / -V: emit version then exit. Used by AqtServerInstaller's
        // verifyInstall() — without this, --version falls through to default
        // once-mode startup, which can segfault under mixed musl/glibc linkage
        // and trip persistDeclined=true in the install flow.
        if args.contains(&"--version") || args.contains(&"-V") {
            println!("{}-{}", env!("CARGO_PKG_VERSION"), env!("GIT_SHA"));
            std::process::exit(0);
        }

        let flag = |name: &str| -> bool { args.contains(&name) };

        let val =
            |name: &str| -> Option<&str> { args.windows(2).find(|w| w[0] == name).map(|w| w[1]) };

        let parse_u16 = |name: &str| -> Option<u16> { val(name).and_then(|v| v.parse().ok()) };
        let parse_u32 = |name: &str, default: u32| -> u32 {
            val(name).and_then(|v| v.parse().ok()).unwrap_or(default)
        };
        let parse_u64 = |name: &str, default: u64| -> u64 {
            val(name).and_then(|v| v.parse().ok()).unwrap_or(default)
        };

        let once = flag("--once");
        let listen = parse_u16("--listen");

        if once && listen.is_some() {
            eprintln!("error: --once and --listen are mutually exclusive");
            std::process::exit(1);
        }

        // 拼错的值直接退出，不静默回退到默认。
        //
        // 这个 flag 存在的唯一目的就是 A/B 对拍，而「以为开了 BBR、其实跑的是
        // CUBIC」会让整轮实验的结论反过来 —— 这种失效必须响。
        let congestion = match val("--congestion") {
            None => CongestionKind::Cubic,
            Some(v) => match CongestionKind::parse(v) {
                Some(k) => k,
                None => {
                    eprintln!("error: --congestion expects `cubic` or `bbr`, got `{v}`");
                    std::process::exit(1);
                }
            },
        };

        Cli {
            once,
            listen,
            bind: val("--bind").unwrap_or("0.0.0.0").to_owned(),
            max_sessions: parse_u32("--max-sessions", 100),
            max_tabs_per_session: parse_u32("--max-tabs-per-session", 16),
            max_concurrent_files: parse_u32("--max-concurrent-files", 4),
            ring_size_mb: parse_u32("--ring-size-mb", 8),
            scrollback_max_lines: parse_u32("--scrollback-max-lines", 3_000),
            allow_anywhere: flag("--allow-anywhere"),
            log_file: val("--log-file").map(PathBuf::from),
            state_dir: val("--state-dir").map(PathBuf::from),
            term: val("--term").unwrap_or("xterm-256color").to_owned(),
            grace_seconds: parse_u64("--grace-seconds", 7 * 24 * 60 * 60),
            once_port: parse_u16("--once-port"),
            status: flag("--status"),
            no_compression: flag("--no-compression"),
            congestion,
            install: flag("--install"),
            notify: None,
        }
    }

    /// 全默认值的 Cli。notify 子命令走早退分支，不需要解析其余 flag。
    ///
    /// 传入的 argv 里 args.get(1) 是 None，不会再次进入 notify 分支，
    /// 因此不会无限递归。
    fn defaults() -> Self {
        Self::parse_from(&["flyterm-server"])
    }

    fn usage() -> &'static str {
        "flyterm-server [OPTIONS]\n\
         \n\
         Options:\n\
           --once                Run in once mode (default)\n\
           --listen PORT         Run as daemon on PORT\n\
           --bind ADDR           Bind address [default: 0.0.0.0]\n\
           --max-sessions N      [default: 100]\n\
           --max-tabs-per-session N  [default: 16]\n\
           --max-concurrent-files N  [default: 4]\n\
           --ring-size-mb N      PTY startup-race buffer size MB [default: 8]\n\
           --scrollback-max-lines N  Scrollback rows kept per tab [default: 3000]\n\
           --allow-anywhere      Allow paths outside home\n\
           --log-file PATH       Audit log path\n\
           --state-dir PATH      State directory\n\
           --term TERM           [default: xterm-256color]\n\
           --grace-seconds N     [default: 604800]\n\
           --once-port PORT      Fixed UDP port for once mode\n\
           --status              Print daemon status and exit\n\
           --no-compression      Disable LZ4 compression at runtime\n\
           --congestion ALGO     Congestion control: cubic|bbr [default: cubic]\n\
                                 bbr is experimental (quinn BBRv1); see --help notes\n\
           --install             Install/upgrade self as daemon (replaces running daemon)\n\
           -h, --help            Show this help\n"
    }

    pub fn mode(&self) -> RunMode {
        match self.listen {
            Some(port) => RunMode::Daemon { port },
            None => RunMode::Once,
        }
    }

    pub fn ring_size_bytes(&self) -> usize {
        self.ring_size_mb.clamp(1, 64) as usize * 1024 * 1024
    }

    /// 下界是 0（干脆不留历史，只发可见屏），不是 100 —— 内存紧张的机器该有
    /// 这个选项，而「至少留 100 行」在 cell 网格下要 280 KB/tab，不是免费的。
    pub fn scrollback_lines_cap(&self) -> usize {
        self.scrollback_max_lines.min(20_000) as usize
    }
}

#[derive(Debug, Clone)]
pub enum RunMode {
    Once,
    Daemon { port: u16 },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Cli {
        // Build a Cli directly from a slice for testing (bypass std::env)
        let raw: Vec<&str> = args.to_vec();
        let flag = |name: &str| raw.contains(&name);
        let val =
            |name: &str| -> Option<&str> { raw.windows(2).find(|w| w[0] == name).map(|w| w[1]) };
        let pu16 = |n: &str| val(n).and_then(|v| v.parse().ok());
        let pu32 = |n: &str, d: u32| val(n).and_then(|v| v.parse().ok()).unwrap_or(d);
        let pu64 = |n: &str, d: u64| val(n).and_then(|v| v.parse().ok()).unwrap_or(d);
        Cli {
            once: flag("--once"),
            listen: pu16("--listen"),
            bind: val("--bind").unwrap_or("0.0.0.0").to_owned(),
            max_sessions: pu32("--max-sessions", 100),
            max_tabs_per_session: pu32("--max-tabs-per-session", 16),
            max_concurrent_files: pu32("--max-concurrent-files", 4),
            ring_size_mb: pu32("--ring-size-mb", 8),
            scrollback_max_lines: pu32("--scrollback-max-lines", 3_000),
            allow_anywhere: flag("--allow-anywhere"),
            log_file: val("--log-file").map(PathBuf::from),
            state_dir: val("--state-dir").map(PathBuf::from),
            term: val("--term").unwrap_or("xterm-256color").to_owned(),
            grace_seconds: pu64("--grace-seconds", 7 * 24 * 60 * 60),
            once_port: pu16("--once-port"),
            status: flag("--status"),
            no_compression: flag("--no-compression"),
            // 这个帮手是解析逻辑的副本，新 flag 一律另写用 `Cli::parse_from`
            // 的用例（见下面那几条），别再往副本里加分支 —— 副本与真实实现
            // 漂移的时候，测试会站在副本那边。
            congestion: CongestionKind::Cubic,
            install: flag("--install"),
            notify: None,
        }
    }

    // 这几条走 `Cli::parse_from`（真实解析路径）而不是上面那个 `parse` 帮手
    // —— 后者是解析逻辑的**副本**，只测它等于没测新加的 flag 有没有接进去。
    #[test]
    fn congestion_defaults_to_cubic() {
        assert_eq!(
            Cli::parse_from(&["flyterm-server"]).congestion,
            CongestionKind::Cubic
        );
    }

    #[test]
    fn congestion_flag_selects_bbr() {
        assert_eq!(
            Cli::parse_from(&["flyterm-server", "--congestion", "bbr"]).congestion,
            CongestionKind::Bbr
        );
        assert_eq!(
            Cli::parse_from(&["flyterm-server", "--congestion", "cubic"]).congestion,
            CongestionKind::Cubic
        );
    }

    /// 大小写不敏感，未知值返回 None。
    ///
    /// 未知值让 `parse_from` 直接退出进程（见那里的注释），所以这条只能测
    /// 纯函数 —— 进程退出没法在单测里断言。
    #[test]
    fn congestion_kind_parses_case_insensitively() {
        assert_eq!(CongestionKind::parse("BBR"), Some(CongestionKind::Bbr));
        assert_eq!(CongestionKind::parse("Cubic"), Some(CongestionKind::Cubic));
        assert_eq!(CongestionKind::parse("reno"), None);
        assert_eq!(CongestionKind::parse(""), None);
    }

    #[test]
    fn install_flag_parses() {
        let c = parse(&["--install"]);
        assert!(c.install);
        assert!(!c.status);
        assert!(!c.once);
        assert!(c.listen.is_none());
    }

    #[test]
    fn install_flag_default_false() {
        let c = parse(&[]);
        assert!(!c.install);
    }

    #[test]
    fn default_is_once_mode() {
        assert!(matches!(parse(&[]).mode(), RunMode::Once));
    }
    #[test]
    fn listen_implies_daemon() {
        assert!(matches!(
            parse(&["--listen", "9876"]).mode(),
            RunMode::Daemon { port: 9876 }
        ));
    }
    #[test]
    fn ring_size_clamp_low() {
        assert_eq!(
            parse(&["--ring-size-mb", "0"]).ring_size_bytes(),
            1 * 1024 * 1024
        );
    }
    #[test]
    fn ring_size_clamp_high() {
        assert_eq!(
            parse(&["--ring-size-mb", "999"]).ring_size_bytes(),
            64 * 1024 * 1024
        );
    }

    #[test]
    fn notify_subcommand_captures_text() {
        let c = Cli::parse_from(&["flyterm-server", "notify", "构建完成"]);
        assert_eq!(c.notify.as_deref(), Some("构建完成"));
    }

    #[test]
    fn notify_joins_multiple_words() {
        // 用户不加引号时 shell 会拆成多个 argv。
        let c = Cli::parse_from(&["flyterm-server", "notify", "build", "done"]);
        assert_eq!(c.notify.as_deref(), Some("build done"));
    }

    #[test]
    fn notify_absent_by_default() {
        let c = Cli::parse_from(&["flyterm-server", "--once"]);
        assert!(c.notify.is_none());
    }

    #[test]
    fn notify_with_no_text_is_empty_string_not_none() {
        // `flyterm notify` 空调用：仍算 notify 模式（投一条空消息并退出 0），
        // 而不是掉回 once 模式去启动一个服务器。
        let c = Cli::parse_from(&["flyterm-server", "notify"]);
        assert_eq!(c.notify.as_deref(), Some(""));
    }

    #[test]
    fn notify_text_containing_help_flag_is_not_swallowed() {
        // --help/-h/--version 的检查用 contains() 扫整个 argv，如果它们排在
        // 子命令识别之前，通知正文里出现 --help 就会被当成帮助请求，通知
        // 静默丢失。子命令必须最先识别。
        let c = Cli::parse_from(&[
            "flyterm-server",
            "notify",
            "see",
            "--help",
            "for",
            "details",
        ]);
        assert_eq!(c.notify.as_deref(), Some("see --help for details"));
    }

    #[test]
    fn notify_text_containing_version_flag_is_not_swallowed() {
        let c = Cli::parse_from(&["flyterm-server", "notify", "bumped", "-V", "2.0"]);
        assert_eq!(c.notify.as_deref(), Some("bumped -V 2.0"));
    }
}
