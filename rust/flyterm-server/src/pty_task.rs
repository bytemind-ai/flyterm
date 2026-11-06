// SPDX-License-Identifier: GPL-3.0-or-later
use aqt_protocol::ScrollbackRing;
use bytes::Bytes;
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::io::{Read, Write};
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex, RwLock};

/// Bounded PTY output channel capacity.
/// 256 × ~4 KB ≈ 1 MB max in-flight; when the channel is full,
/// `blocking_send` in the spawn_blocking reader stalls PTY reads,
/// letting the kernel PTY buffer fill and naturally flow-controlling
/// the shell process. Prevents OOM on heavy output (e.g. `cat huge.log`).
pub const OUTPUT_CHANNEL_CAPACITY: usize = 256;

/// CWD-poll interval. 5 s is fine for SFTP: users cd then wait >5s
/// before clicking the SFTP panel; automatic refresh is always available.
/// Was 500ms — 10x reduction cuts readlink syscalls from ~32/s to ~3.2/s
/// at 16 tabs.
pub const CWD_POLL_INTERVAL_MS: u64 = 5000;

/// Tracks the last (cols, rows) sent to the OS PTY so we can skip redundant
/// ioctl(TIOCSWINSZ) calls. A repeated identical resize still delivers a
/// SIGWINCH to the child shell — bash/zsh react by writing `\r\x1b[K<prompt>`,
/// which accumulates in the scrollback ring and amplifies the visual artifact
/// after multiple weak-network RESUMEs (h.jpg).
pub struct ResizeDedupState {
    last_size: Mutex<(u16, u16)>,
}

impl ResizeDedupState {
    pub fn new(cols: u16, rows: u16) -> Self {
        Self {
            last_size: Mutex::new((cols, rows)),
        }
    }

    /// Returns true if (cols, rows) differs from the stored value and
    /// updates the state to the new value. Returns false on duplicate,
    /// in which case the caller MUST NOT touch the underlying PTY.
    pub async fn should_resize(&self, cols: u16, rows: u16) -> bool {
        let mut last = self.last_size.lock().await;
        if *last == (cols, rows) {
            return false;
        }
        *last = (cols, rows);
        true
    }
}

pub struct PtyHandles {
    pub input_tx: mpsc::Sender<Bytes>,
    pub output_forwarder: Arc<Mutex<Option<mpsc::Sender<Bytes>>>>,
    pub exit_rx: tokio::sync::watch::Receiver<Option<i32>>,
    /// 兜住「PTY 起来了但 forwarder 还没装上」这个启动竞态：那几毫秒里 shell
    /// 打印的 prompt 没有接收者，靠 `snapshot_all()` 在 OPEN_TAB 里补发一次。
    ///
    /// **不是 scrollback**。历史回放走 `parser` 的 scrollback —— 这个 ring 存的
    /// 是原始字节流，用它当历史正是「回放内容重复」那一整类 bug 的根因
    /// （详见 `snapshot.rs` 头部）。
    pub ring: Arc<Mutex<ScrollbackRing>>,
    /// 屏幕状态的唯一权威：既是 RESUME 负载的可见屏来源，也是**历史**的来源
    /// （`primary_scrollback_rows_formatted`）。由 PTY 读循环写入。
    pub parser: Arc<RwLock<vt100::Parser>>,
    pty_master: Arc<Mutex<Box<dyn portable_pty::MasterPty + Send>>>,
    /// Caches last (cols, rows) so identical resizes skip ioctl + SIGWINCH.
    pub dedup: Arc<ResizeDedupState>,
}

impl PtyHandles {
    pub async fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<()> {
        if !self.dedup.should_resize(cols, rows).await {
            // Identical size — child shell already at this geometry. Skipping
            // ioctl avoids a spurious SIGWINCH that the shell would answer
            // with a `\r\x1b[K<prompt>` redraw, accumulating in the ring.
            return Ok(());
        }
        let master = self.pty_master.lock().await;
        master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        drop(master);
        // Keep parser dimensions in sync so state_formatted() reflects the
        // current viewport. Without this, RESUME after a client-driven
        // resize (keyboard show/hide) would emit a snapshot sized to stale
        // dimensions, producing wrong wrapping on the client.
        //
        // 这把写锁与 PTY 读循环（本文件 `blocking_write`）是同一把，所以它排在
        // ioctl **之后**意味着：SIGWINCH 已经发出、应用的重绘字节正在涌入，
        // 而转发线程此刻抢不到锁。查「QUIC resize 闪屏」时这看着像根因，
        // 但量过了 —— scrollback 灌满 3000 行时 set_size 只要 ~0.21 ms
        // （shrink 209 µs / grow 218 µs，vt100 0.15.2）。相对 16.7 ms 一帧
        // 不可感知，不是闪屏的原因。别再往这个方向查。
        self.parser.write().await.set_size(rows, cols);
        Ok(())
    }

    /// Read the PTY's current rows/cols, used by RESUME to wiggle the size
    /// by 1 row and back to deliver a SIGWINCH to the running app and force
    /// a full redraw.
    pub async fn get_size(&self) -> anyhow::Result<PtySize> {
        let master = self.pty_master.lock().await;
        master.get_size().map_err(|e| anyhow::anyhow!("{e}"))
    }
}

pub struct PtySpawnConfig {
    pub cols: u16,
    pub rows: u16,
    pub term: String,
    pub cwd: Option<String>,
    pub ring_size_bytes: usize,
    /// vt100 parser 保留多少行 primary scrollback。RESUME 负载的历史段就是从
    /// 这里读的，所以它同时决定了「用户恢复后能往上翻多远」。
    ///
    /// 内存代价是实打实的：`size_of::<vt100::Cell>()` 实测 36 B，3000 行 × 80 列
    /// ≈ 8 MB/tab。调小它省内存，代价是历史短。
    pub parser_scrollback_rows: usize,
    /// 供 `flyterm notify` CLI 自报家门用：写进子进程环境的 FLYTERM_TAB_ID /
    /// FLYTERM_NOTIFY_SOCK。见 spawn_pty 里的注入点。`notify_sock` 为 None
    /// 时（Once 模式，没有监听器）两个环境变量都不注入，见那里的注释。
    pub tab_id: u32,
    pub notify_sock: Option<std::path::PathBuf>,
    #[cfg(feature = "history")]
    pub history_logger: Option<Arc<std::sync::Mutex<crate::history::logger::HistoryLogger>>>,
    #[cfg(not(feature = "history"))]
    pub history_logger: Option<HistoryLoggerHandle>,
}

/// Zero-size placeholder for HistoryLogger when the `history` feature is off.
#[cfg(not(feature = "history"))]
#[derive(Clone)]
pub struct HistoryLoggerHandle;

/// Assembles the login-shell command + environment for a PTY.
///
/// Split out of [`spawn_pty`] so the env policy can be asserted without
/// allocating a real PTY — the `spawn_pty` tests are `#[ignore]`d for exactly
/// that reason, which is how `env_remove("COLORTERM")` (see below) survived
/// unnoticed until a user reported a glaring blue background.
fn build_shell_command(cfg: &PtySpawnConfig) -> CommandBuilder {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
    let mut cmd = CommandBuilder::new(&shell);
    // Run as a LOGIN shell -- matches what sshd does for SSH sessions.
    // Without this, only ~/.bashrc is sourced; with it, the shell also
    // loads /etc/profile -> /etc/profile.d/* -> ~/.bash_profile (or
    // ~/.profile), which is where users typically export COLORTERM,
    // COLORFGBG, locale, and other Claude-Code-detected terminal hints.
    // QUIC and SSH PTYs end up with identical environments and therefore
    // identical rendering.
    cmd.arg("-l");
    cmd.env("TERM", &cfg.term);
    // 让 `flyterm notify` 知道自己来自哪个 tab、往哪个 socket 投。只在有
    // 监听器可连时才注入（notify_sock: Some）——Once 模式没有监听器，注入
    // 一个死路径只会让用户以为 notify 能用，实际永远静默失败；不注入的话
    // `flyterm notify` 会回落到默认的 sock_path(&state_dir)，如果这台机器上
    // 恰好有一个 daemon 在跑，反而真能送达。
    //
    // tmux 下有坑：pane 继承的是创建时的环境，跨会话可能拿到过期的 tab_id。
    // 客户端侧对未知 tab_id 降级为"深链到服务器"，所以这里不做额外校验。
    if let Some(sock) = &cfg.notify_sock {
        cmd.env("FLYTERM_TAB_ID", cfg.tab_id.to_string());
        cmd.env("FLYTERM_NOTIFY_SOCK", sock.to_string_lossy().as_ref());
    }
    // Strip inherited tmux/multiplexer markers. If the daemon was launched
    // from a user shell that auto-attaches tmux (common in dotfiles —
    // `~/.bashrc` runs `tmux attach -t main || tmux new`), the daemon
    // process inherits `TMUX`, `TMUX_PANE`, `TERM_PROGRAM=tmux`, etc.
    // Subshells then inherit them too, and Claude CLI / other TUIs that
    // sniff `TMUX` switch into a tmux-compat rendering path — producing
    // duplicate cursor rectangles and reflow artifacts even though no
    // tmux is actually wrapping this PTY. Forcibly removing the env
    // guarantees the spawned shell is a clean direct PTY regardless of
    // how the daemon itself was started.
    cmd.env_remove("TMUX");
    cmd.env_remove("TMUX_PANE");
    cmd.env_remove("TERM_PROGRAM");
    cmd.env_remove("TERM_PROGRAM_VERSION");
    // Declare 24-bit color. This used to be `env_remove("COLORTERM")`, on the
    // theory that QUIC should match SSH (sshd only honors AcceptEnv, so a
    // fresh SSH login arrives with COLORTERM unset). That parity was real but
    // it leveled DOWN: with COLORTERM unset, apps (Claude / delta / bat /
    // nvim) fall back to the 256-color palette, and palette quantization maps
    // a dark indigo code-block background onto color-cube index 21 — pure
    // #0000FF. That is the glaring blue block in the 2026-09-22 device
    // screenshot. It is NOT the client's terminal theme: cube/RGB colors
    // bypass `TerminalTheme.blue` entirely, so no palette change can fix it.
    //
    // We own this PTY end to end, so we level UP instead and declare the
    // capability the client actually has (xterm.dart implements
    // `setBackgroundColorRgb`, i.e. real 24-bit SGR). Parity is restored on
    // the Dart side by injecting the same COLORTERM into tmux (`-e`) and the
    // local PTY — see lib/ssh/terminal_env.dart, which also documents why
    // mosh is deliberately left out (mosh only gained 24-bit color in 1.4.0).
    //
    // Set BEFORE the login shell runs, so a user's `export COLORTERM=...` in
    // ~/.profile still wins — this is a default, not an override.
    cmd.env("COLORTERM", "truecolor");
    // Server keeps the PTY env clean — terminal-protocol filtering lives
    // on the client side (see lib/ssh/transport/tmux_passthrough_unwrapper.dart
    // and friends). Sane defaults only for LANG when the daemon was
    // started with a bare env (boot / nohup outside any shell profile).
    if std::env::var_os("LANG").is_none() {
        cmd.env("LANG", "C.UTF-8");
    }
    if let Some(cwd) = &cfg.cwd {
        if std::path::Path::new(cwd).is_dir() {
            cmd.cwd(cwd);
        }
    }
    cmd
}

pub fn spawn_pty(cfg: PtySpawnConfig) -> anyhow::Result<PtyHandles> {
    let pty_system = native_pty_system();
    let pair = pty_system.openpty(PtySize {
        rows: cfg.rows,
        cols: cfg.cols,
        pixel_width: 0,
        pixel_height: 0,
    })?;

    let cmd = build_shell_command(&cfg);
    let mut child = pair.slave.spawn_command(cmd)?;
    let child_pid = child.process_id();

    let (input_tx, mut input_rx) = mpsc::channel::<Bytes>(64);
    let output_forwarder: Arc<Mutex<Option<mpsc::Sender<Bytes>>>> = Arc::new(Mutex::new(None));
    let (exit_tx, exit_rx) = tokio::sync::watch::channel::<Option<i32>>(None);
    let ring = Arc::new(Mutex::new(ScrollbackRing::new(cfg.ring_size_bytes)));
    // vt100 parser sized to the initial PTY dimensions，并带上 scrollback ——
    // RESUME 负载的历史段直接从这里读。
    //
    // 这里曾经硬编码 `0`，注释写「RESUME scrollback recovery uses the ring's
    // raw bytes」。那条路是错的：ring 存的是原始字节流（逻辑行），屏幕是求值
    // 后的状态（物理行），两者之间用行数做算术不可能对。详见 `snapshot.rs` 头部。
    let parser = Arc::new(RwLock::new(vt100::Parser::new(
        cfg.rows,
        cfg.cols,
        cfg.parser_scrollback_rows,
    )));

    // 预先在 ring 里写入一条 OSC-7 序列，把初始 CWD 告诉客户端。
    // 这样客户端 SFTP 入口能立即拿到 tab.cwd（而不必等 shell 的 PROMPT_COMMAND
    // 或 vte.sh 集成发 OSC-7 —— bash 默认不发，zsh 才发）。
    // 即使用户登录后立即进入 TUI (claude/vim) 也至少有初始目录。
    // OSC-7 是不显示的控制序列（终端解析为 URL/CWD 提示），无副作用。
    let initial_cwd = cfg
        .cwd
        .clone()
        .or_else(|| std::env::var("HOME").ok())
        .unwrap_or_else(|| "/".into());
    let osc7 = format!("\x1b]7;file://localhost{}\x07", initial_cwd);
    let osc7_bytes = Bytes::from(osc7.into_bytes());
    ring.blocking_lock().append(&osc7_bytes);

    // take_writer consumes the write half -- only valid to call once
    let master_writer = pair.master.take_writer()?;
    tokio::task::spawn_blocking({
        let mut w = master_writer;
        move || {
            while let Some(bytes) = input_rx.blocking_recv() {
                if w.write_all(&bytes).is_err() {
                    break;
                }
            }
        }
    });

    // Tracks ring.tail_off() captured just BEFORE the chunk that flipped
    // the parser into alt mode was appended. Cold-RESUME uses this to
    // slice only the pre-alt portion of the ring (avoiding double-text
    // because eviction log already covers the alt portion).

    let mut reader = pair.master.try_clone_reader()?;
    let ring_r = Arc::clone(&ring);
    let fwd_r = Arc::clone(&output_forwarder);
    let parser_r = Arc::clone(&parser);
    #[cfg(feature = "history")]
    let history_logger_r = cfg.history_logger.clone();
    tokio::task::spawn_blocking(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let chunk = Bytes::copy_from_slice(&buf[..n]);
                    ring_r.blocking_lock().append(&chunk);

                    // parser 是"屏幕现在长什么样"的权威来源：alt 屏重建时
                    // connection.rs 直接取它的 state_formatted()。
                    {
                        let mut parser_w = parser_r.blocking_write();
                        parser_w.process(&buf[..n]);
                    }
                    // Tee to history logger; errors are silently ignored so
                    // history failure never affects the live terminal.
                    #[cfg(feature = "history")]
                    if let Some(logger) = &history_logger_r {
                        if let Ok(mut g) = logger.lock() {
                            let _ = g.append(&buf[..n]);
                        }
                    }
                    let fwd = fwd_r.blocking_lock();
                    if let Some(tx) = &*fwd {
                        // blocking_send blocks this spawn_blocking thread when the
                        // channel is full, creating backpressure (intended).
                        //
                        // Err means the receiver was dropped — typically during a
                        // RESUME's channel swap, NOT a permanent failure: the
                        // output_forwarder is about to be replaced with a new tx.
                        // Previously this `break`ed the reader loop, permanently
                        // killing PTY output forwarding even though the session
                        // would soon get a fresh forwarder. Subsequent RESUMEs
                        // saw a connected QUIC stream but no PTY data → client
                        // detected "dead" via isDead/phantom → triggered another
                        // RESUME → loop. (Observed as rc:14 / 2-3s reconnect cycle.)
                        //
                        // Fix: drop this chunk and continue. Next iteration sees
                        // the freshly-installed tx and resumes normal flow.
                        // Worst case: 1 chunk (~4KB) lost during RESUME swap.
                        let _ = tx.blocking_send(chunk);
                    }
                }
                Err(_) => break,
            }
        }
    });

    std::thread::spawn(move || {
        let status = child.wait().ok();
        let code = status.map(|s| s.exit_code() as i32).unwrap_or(-1);
        let _ = exit_tx.send(Some(code));
    });

    // 周期 readlink /proc/<shell_pid>/cwd，CWD 变化时通过 OSC-7 推给客户端。
    // 这是 bash（默认不发 OSC-7）/ 用户已进 TUI 等场景的兜底：客户端 SFTP
    // 入口能拿到真实的当前目录，无需依赖 shell 配置。
    // 500ms 间隔：cd 后用户立即点 SFTP 通常 > 500ms，足够追上；CPU 开销
    // 仅一次 readlink syscall，可忽略。
    if let Some(pid) = child_pid {
        log::info!("CWD-poll task spawned for shell pid={}", pid);
        let fwd_for_poll = Arc::clone(&output_forwarder);
        let ring_for_poll = Arc::clone(&ring);
        let mut exit_rx_for_poll = exit_rx.clone();
        tokio::spawn(async move {
            let cwd_link = format!("/proc/{}/cwd", pid);
            let mut last_cwd = String::new();
            let mut first = true;
            loop {
                if !first {
                    tokio::select! {
                        biased;
                        _ = exit_rx_for_poll.changed() => {
                            if exit_rx_for_poll.borrow().is_some() { break; }
                        }
                        _ = tokio::time::sleep(std::time::Duration::from_millis(CWD_POLL_INTERVAL_MS)) => {}
                    }
                } else {
                    // 第一次立即跑：客户端 OPEN_TAB 完成后能立刻拿到准确 CWD
                    // （不等 500ms 第一个周期）。
                    first = false;
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                }
                let cwd = match tokio::fs::read_link(&cwd_link).await {
                    Ok(p) => p.to_string_lossy().into_owned(),
                    Err(e) => {
                        log::debug!("CWD-poll readlink failed pid={}: {}", pid, e);
                        continue;
                    }
                };
                if cwd.is_empty() || cwd == last_cwd {
                    continue;
                }
                log::info!("CWD-poll pid={} change: {} -> {}", pid, last_cwd, cwd);
                last_cwd = cwd.clone();
                let osc7 = format!("\x1b]7;file://localhost{}\x07", cwd);
                let bytes = Bytes::from(osc7.into_bytes());
                ring_for_poll.lock().await.append(&bytes);
                let fwd = fwd_for_poll.lock().await;
                if let Some(tx) = &*fwd {
                    let _ = tx.send(bytes);
                }
            }
            log::info!("CWD-poll task exiting pid={}", pid);
        });
    } else {
        log::warn!("CWD-poll: child.process_id() returned None — no PID, polling skipped");
    }

    Ok(PtyHandles {
        input_tx,
        output_forwarder,
        exit_rx,
        ring,
        parser,
        pty_master: Arc::new(Mutex::new(pair.master)),
        dedup: Arc::new(ResizeDedupState::new(cfg.cols, cfg.rows)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn test_cfg() -> PtySpawnConfig {
        PtySpawnConfig {
            cols: 80,
            rows: 24,
            term: "xterm-256color".into(),
            cwd: None,
            ring_size_bytes: 64 * 1024,
            parser_scrollback_rows: 1000,
            tab_id: 1,
            notify_sock: None,
            history_logger: None,
        }
    }

    /// Regression guard for the pure-blue background (2026-09-22 screenshot).
    ///
    /// Without COLORTERM the remote TUI degrades to the 256-color palette and
    /// quantizes its dark indigo code-block background onto color-cube index
    /// 21 — pure #0000FF. The client's terminal theme cannot fix that: cube
    /// and RGB colors bypass the palette entirely.
    #[test]
    fn shell_env_declares_truecolor() {
        let cmd = build_shell_command(&test_cfg());
        assert_eq!(
            cmd.get_env("COLORTERM"),
            Some(std::ffi::OsStr::new("truecolor")),
            "COLORTERM must be declared — see lib/ssh/terminal_env.dart",
        );
        assert_eq!(
            cmd.get_env("TERM"),
            Some(std::ffi::OsStr::new("xterm-256color"))
        );
    }

    /// The truecolor change must not undo the tmux-marker stripping that sits
    /// immediately above it — both edit the same env block.
    #[test]
    fn shell_env_still_strips_multiplexer_markers() {
        let cmd = build_shell_command(&test_cfg());
        for key in ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"] {
            assert_eq!(cmd.get_env(key), None, "{key} must not reach the PTY");
        }
    }

    /// Guards the refactor: the notify vars still track `notify_sock`.
    ///
    /// Only the `Some` branch is asserted. The `None` branch cannot be pinned
    /// here — `CommandBuilder::new` seeds from the process env, so a daemon
    /// (or test runner) that is itself running inside a FlyTerm PTY inherits
    /// FLYTERM_TAB_ID and passes it straight through. That leak predates this
    /// change and is deliberately left alone; see the comment in
    /// `build_shell_command` about stale tab_ids.
    #[test]
    fn shell_env_injects_notify_vars_when_a_listener_exists() {
        let cfg = PtySpawnConfig {
            tab_id: 7,
            notify_sock: Some(std::path::PathBuf::from("/tmp/flyterm-test.sock")),
            ..test_cfg()
        };
        let cmd = build_shell_command(&cfg);
        assert_eq!(
            cmd.get_env("FLYTERM_TAB_ID"),
            Some(std::ffi::OsStr::new("7"))
        );
        assert_eq!(
            cmd.get_env("FLYTERM_NOTIFY_SOCK"),
            Some(std::ffi::OsStr::new("/tmp/flyterm-test.sock")),
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires allocatable PTY; run locally"]
    async fn parser_size_tracks_resize() -> anyhow::Result<()> {
        let h = spawn_pty(PtySpawnConfig {
            cols: 80,
            rows: 24,
            term: "xterm-256color".into(),
            cwd: None,
            ring_size_bytes: 64 * 1024,
            parser_scrollback_rows: 1000,
            tab_id: 1,
            notify_sock: Some(std::path::PathBuf::from("/tmp/flyterm-test-notify.sock")),
            history_logger: None,
        })?;
        assert_eq!(h.parser.read().await.screen().size(), (24, 80));
        h.resize(100, 30).await?;
        assert_eq!(h.parser.read().await.screen().size(), (30, 100));
        Ok(())
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires allocatable PTY; run locally"]
    async fn spawn_echo_and_read() -> anyhow::Result<()> {
        let h = spawn_pty(PtySpawnConfig {
            cols: 80,
            rows: 24,
            term: "xterm-256color".into(),
            cwd: None,
            ring_size_bytes: 64 * 1024,
            parser_scrollback_rows: 1000,
            tab_id: 1,
            notify_sock: Some(std::path::PathBuf::from("/tmp/flyterm-test-notify.sock")),
            history_logger: None,
        })?;
        h.input_tx
            .send(Bytes::from_static(b"echo hello-aqt\n"))
            .await?;
        tokio::time::sleep(Duration::from_millis(500)).await;
        let ring = h.ring.lock().await;
        assert!(ring.tail_off() > 0, "ring should have PTY output");
        let d = ring.snapshot_all();
        assert!(!d.is_empty(), "ring is empty");
        assert!(String::from_utf8_lossy(&d).contains("hello-aqt"));
        Ok(())
    }
}

#[cfg(test)]
mod resize_dedup_tests {
    use super::ResizeDedupState;

    #[tokio::test]
    async fn first_call_returns_true() {
        let state = ResizeDedupState::new(80, 24);
        assert!(state.should_resize(80, 25).await, "size change must resize");
    }

    #[tokio::test]
    async fn duplicate_call_returns_false() {
        let state = ResizeDedupState::new(80, 24);
        assert!(!state.should_resize(80, 24).await, "same size must skip");
    }

    #[tokio::test]
    async fn alternating_sizes_each_resize() {
        let state = ResizeDedupState::new(80, 24);
        assert!(state.should_resize(80, 50).await);
        assert!(!state.should_resize(80, 50).await);
        assert!(state.should_resize(80, 88).await);
        assert!(!state.should_resize(80, 88).await);
        assert!(state.should_resize(80, 50).await);
    }

    #[tokio::test]
    async fn cols_change_only() {
        let state = ResizeDedupState::new(80, 24);
        assert!(state.should_resize(120, 24).await);
        assert!(!state.should_resize(120, 24).await);
    }
}
