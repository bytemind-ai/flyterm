// SPDX-License-Identifier: GPL-3.0-or-later
#![forbid(unsafe_code)]
use anyhow::Result;
use env_logger;
use flyterm_server::{
    bootstrap::BootstrapInfo,
    cli::{Cli, RunMode},
    connection::ConnectionConfig,
    endpoint, session, tls,
};

/// Cheap liveness probe: a PID is alive iff `/proc/<pid>/exe` resolves.
/// Mirrors the check in `installer::find_old_daemon`. Linux-only (the daemon
/// only ever runs on Linux hosts), so no `kill(0)` / non-Unix fallback needed.
fn pid_alive(pid: i32) -> bool {
    std::path::Path::new(&format!("/proc/{pid}/exe")).exists()
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    // Resolve state_dir early — needed for both --status and daemon mode.
    let state_dir = cli.state_dir.clone().unwrap_or_else(|| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
        std::path::PathBuf::from(home).join(".flyterm-server")
    });

    // --status: print daemon.info if it describes a LIVE daemon, then exit.
    // A dead daemon can leave a stale daemon.info behind (SIGKILL/OOM/crash/
    // reboot); printing it verbatim would send the App to a dead QUIC port and
    // make it time out after 5s. Verify AQT_PID liveness and clean up if dead.
    if cli.status {
        let info_path = state_dir.join("daemon.info");
        if let Ok(content) = std::fs::read_to_string(&info_path) {
            let sessions = std::fs::read_to_string(state_dir.join("daemon.sessions")).ok();
            match flyterm_server::bootstrap::status_output(&content, sessions.as_deref(), pid_alive)
            {
                Some(s) => print!("{s}"),
                None => {
                    // Stale: remove so future probes (and find_old_daemon) agree
                    // it's gone. Best-effort — a failed unlink is non-fatal.
                    let _ = std::fs::remove_file(&info_path);
                }
            }
        }
        // Exit silently (no output) if daemon is not running.
        return Ok(());
    }

    // --install: self-install subcommand. The binary on disk (always the
    // new version being installed) does the full kill-old → atomic-replace
    // → spawn-new sequence, then prints INSTALL_OK / INSTALL_ERR on stdout.
    // Must run before the daemon-init code path; doesn't write daemon.info
    // itself (the spawned child does that).
    if cli.install {
        // 不带 --listen 时沿用随机口（0），与不认识端口段的旧版 App 行为一致。
        let ports = cli.listen.unwrap_or(flyterm_server::cli::PortSpec::ANY);
        return match flyterm_server::installer::run(cli.congestion, ports) {
            Ok(()) => Ok(()),
            Err(e) => {
                println!("INSTALL_ERR reason={e}");
                std::process::exit(1);
            }
        };
    }

    // notify 子命令：投一行到本机 socket 然后退出。
    //
    // 退出码恒为 0。这条命令会被写进 `make && flyterm notify "done"`，
    // 用非零退出码污染用户的命令链是不可接受的——通知是附加品，没有
    // 资格让主命令失败。失败只往 stderr 打一行。
    if let Some(text) = cli.notify.clone() {
        let sock = std::env::var("FLYTERM_NOTIFY_SOCK").unwrap_or_else(|_| {
            flyterm_server::notify::listener::sock_path(&state_dir)
                .to_string_lossy()
                .into_owned()
        });
        let tab = std::env::var("FLYTERM_TAB_ID").ok();
        let line = match tab {
            Some(t) => format!("tab={t} {text}"),
            None => text,
        };
        match std::os::unix::net::UnixStream::connect(&sock) {
            Ok(mut s) => {
                use std::io::Write;
                if let Err(e) = s.write_all(line.as_bytes()) {
                    eprintln!("flyterm notify: write failed: {e}");
                }
            }
            Err(e) => eprintln!("flyterm notify: daemon not reachable at {sock}: {e}"),
        }
        std::process::exit(0);
    }

    // Self-identifying banner for ps / journalctl audit.
    // Placed after --status fast-path so daemon.info parser is unaffected.
    let pkg_version = concat!(env!("CARGO_PKG_VERSION"), "-", env!("GIT_SHA"));
    eprintln!(
        "[flyterm-server v{} PID {}] managed by FlyTerm; uninstall: rm -rf ~/.flyterm-server",
        pkg_version,
        std::process::id()
    );

    init_tracing(&cli);

    // 启动自检：数一下同一个二进制还有几个实例在跑。
    //
    // 位置必须在 init_tracing 之后 —— logger 未初始化时 log::warn! 会被静默
    // 丢弃，那会造出一条"看着接好了但永远不打印"的假线。
    //
    // 不自动杀 —— 那是 --install 的职责，在启动路径上杀会让「手动起第二个
    // 实例做对比测试」这种正当用法变得不可能。只记日志，让孤儿在日志里可见。
    {
        let self_pid = std::process::id() as i32;
        let siblings = flyterm_server::installer::count_sibling_daemons(self_pid);
        if siblings > 0 {
            log::warn!(
                "startup: {siblings} other instance(s) of this binary already running \
                 — each holds its own UDP port, SessionStore and PTY children. \
                 Run `flyterm-server --install` to reap them."
            );
        }
    }

    let mode = cli.mode();

    // Use persistent keypair for daemon mode so SPKI stays stable across restarts.
    // Once mode uses an ephemeral keypair (process dies with SSH session anyway).
    let tls_material = match mode {
        RunMode::Daemon { .. } => tls::load_or_generate_persistent(&state_dir)?,
        RunMode::Once => tls::generate_ephemeral()?,
    };

    let ports = match mode {
        RunMode::Once => cli.once_port.unwrap_or(flyterm_server::cli::PortSpec::ANY),
        RunMode::Daemon { ports } => ports,
    };
    let ep = endpoint::build_endpoint_in(&cli.bind, ports, &tls_material, cli.congestion)?;
    let local = ep.local_addr;

    let store = session::SessionStore::new(cli.max_sessions, session::DEFAULT_SESSION_TTL);

    #[cfg(feature = "history")]
    let history_root = match flyterm_server::history::root::HistoryRoot::open(
        flyterm_server::history::root::HistoryRoot::default_path(),
    ) {
        Ok(r) => Some(r),
        Err(e) => {
            log::warn!("history disabled: {}", e);
            None
        }
    };
    #[cfg(not(feature = "history"))]
    let history_root: Option<flyterm_server::connection::HistoryRootPlaceholder> = None;

    // Compression master switch: feature must be compiled in AND user must
    // not have passed --no-compression at startup. The runtime flag is the
    // intended diagnostic knob — the cargo feature stays on so the LZ4 code
    // path is present and we can flip back instantly without rebuilding.
    let allow_compression = cfg!(feature = "compression") && !cli.no_compression;
    if cli.no_compression {
        log::info!("LZ4 compression disabled by --no-compression flag");
    }
    // Once 模式不 bind 监听器（见下面 match 里的注释），所以这里不能无条件
    // 塞一个路径进去——那样 PTY 里会看到一个指向死 socket 的
    // FLYTERM_NOTIFY_SOCK，用户/脚本会误以为 `flyterm notify` 能用，实际
    // 永远静默失败。None 时 pty_task.rs 干脆不注入这两个环境变量，让
    // `flyterm notify` 回落到默认路径（如果这台机器上恰好有个 daemon 在跑，
    // 反而能送达）。
    let notify_sock = match mode {
        RunMode::Daemon { .. } => Some(flyterm_server::notify::listener::sock_path(&state_dir)),
        RunMode::Once => None,
    };
    let conn_cfg = ConnectionConfig {
        ring_size_bytes: cli.ring_size_bytes(),
        parser_scrollback_rows: cli.scrollback_lines_cap(),
        max_tabs_per_session: cli.max_tabs_per_session,
        term: cli.term.clone(),
        allow_compression,
        history_root,
        notify_sock,
    };

    match mode {
        RunMode::Once => {
            // Print AQT_* bootstrap lines to stdout so the SSH exec channel
            // carries them back to the App.
            let token = store
                .create()
                .await
                .ok_or_else(|| anyhow::anyhow!("internal: failed to create initial session"))?;
            BootstrapInfo {
                version: aqt_protocol::PROTOCOL_VERSION,
                port: local.port(),
                spki_base64: &tls_material.spki_base64,
                token: &token,
            }
            .print_to_stdout()?;
        }
        RunMode::Daemon { .. } => {
            // Write daemon.info so the App can bootstrap without starting a
            // new server process: SSH → exec `flyterm-server --status`.
            // AQT_VERSION is the running process's cargo version — used by the
            // client to verify the live process version (not just disk version).
            let info_content = format!(
                "AQT_PORT={}\nAQT_PUBKEY={}\nAQT_VERSION={}-{}\nAQT_PID={}\n",
                local.port(),
                tls_material.spki_base64,
                env!("CARGO_PKG_VERSION"),
                env!("GIT_SHA"),
                std::process::id(),
            );
            let info_path = state_dir.join("daemon.info");
            std::fs::write(&info_path, &info_content)
                .unwrap_or_else(|e| log::warn!("failed to write daemon.info: {e}"));
            log::info!("daemon.info written to {}", info_path.display());

            // 活跃会话数，供 `--status` 报给 App（改端口要重启 daemon 时，
            // 提示用户会中断几个会话）。先写临时文件再 rename，`--status`
            // 不会读到写了一半的内容；最多滞后一个周期。
            {
                let store = store.clone();
                let path = state_dir.join("daemon.sessions");
                let tmp = state_dir.join("daemon.sessions.tmp");
                tokio::spawn(async move {
                    let mut tick = tokio::time::interval(std::time::Duration::from_secs(5));
                    loop {
                        tick.tick().await;
                        let line = flyterm_server::bootstrap::sessions_line(store.count().await);
                        if std::fs::write(&tmp, line).is_ok() {
                            let _ = std::fs::rename(&tmp, &path);
                        }
                    }
                });
            }

            // 本地通知投递入口。绑定失败只记警告不致命——通知是附加功能，
            // 不该让整个 daemon 起不来。只在 daemon 模式绑定：once 模式是
            // 跟 SSH exec channel 同生共死的短命进程，没有长期监听的意义，
            // 并发多个 once 进程抢同一个 socket 路径也没有价值。
            match flyterm_server::notify::listener::bind(&state_dir) {
                Ok(l) => {
                    let store_n = store.clone();
                    tokio::spawn(async move {
                        let cb = std::sync::Arc::new(move |tab: Option<u32>, text: String| {
                            let store = store_n.clone();
                            let now = std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .map(|d| d.as_millis() as u64)
                                .unwrap_or(0);
                            tokio::spawn(async move {
                                store.broadcast_notify(tab, text, now).await;
                            });
                        });
                        if let Err(e) = flyterm_server::notify::listener::serve(l, cb).await {
                            log::warn!("notify listener stopped: {e:#}");
                        }
                    });
                }
                Err(e) => log::warn!("notify socket unavailable: {e:#}"),
            }
        }
    }

    log::info!("listening on {local}");
    let shutdown = ep.shutdown.clone();
    // Clone the underlying quinn::Endpoint for the main thread so we can
    // explicitly close it on graceful shutdown (SIGTERM from installer.rs).
    // quinn::Endpoint is internally Arc — clone is cheap.
    let endpoint_for_shutdown = ep.endpoint.clone();
    let store_c = store.clone();
    let cfg_c = conn_cfg.clone();
    let accept = tokio::spawn(endpoint::accept_loop(ep, store_c, cfg_c));

    // Once mode: also exit on SIGHUP (fired when SSH exec channel closes).
    // Without this, the process accumulates as SSH sessions open/close.
    // Daemon mode ignores SIGHUP — it must run indefinitely.
    #[cfg(unix)]
    let mut sighup = {
        use tokio::signal::unix::{signal, SignalKind};
        if matches!(mode, RunMode::Once) {
            signal(SignalKind::hangup()).ok()
        } else {
            None
        }
    };

    // SIGTERM listener (Unix only). installer.rs sends SIGTERM to old daemon
    // during in-place upgrade; without this branch Rust's default handler
    // aborts the process, leaving QUIC clients to wait keep_alive_interval
    // × N (~15s × ~3) before they detect the dead path.
    #[cfg(unix)]
    let mut sigterm = {
        use tokio::signal::unix::{signal, SignalKind};
        signal(SignalKind::terminate()).ok()
    };

    tokio::select! {
        _ = tokio::signal::ctrl_c() => { log::info!("ctrl_c (SIGINT) received"); }
        _ = async {
            #[cfg(unix)]
            match sigterm.as_mut() {
                Some(s) => { s.recv().await; }
                None => { std::future::pending::<()>().await; }
            }
            #[cfg(not(unix))]
            std::future::pending::<()>().await;
        } => { log::info!("SIGTERM received — graceful shutdown"); }
        _ = async {
            #[cfg(unix)]
            match sighup.as_mut() {
                Some(s) => { s.recv().await; }
                // Daemon mode: sighup is None — never resolve this branch.
                None => { std::future::pending::<()>().await; }
            }
            #[cfg(not(unix))]
            std::future::pending::<()>().await;
        } => { log::info!("SIGHUP received — SSH session closed, shutting down"); }
        r = accept => { log::warn!("accept loop exited: {r:?}"); }
    }
    // Notify all live QUIC connections of graceful shutdown so clients can
    // react within ~1 RTT instead of waiting keep_alive_interval × N
    // (~15s × 3 = up to 45s). Application error code 0 = normal shutdown.
    //
    // 200ms covers typical mobile latency for the CONNECTION_CLOSE packet
    // to leave the host; the in-flight close happens before installer.rs's
    // 2s SIGTERM→SIGKILL budget elapses. We do this BEFORE notify_one so
    // the accept_loop's own endpoint.close() in its select branch is just
    // a redundant idempotent call.
    endpoint_for_shutdown.close(0u32.into(), b"server shutdown");
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    shutdown.notify_one();

    // Clean up daemon.info on orderly exit so stale port/spki don't confuse
    // future --status probes. Best-effort: failure is non-fatal.
    if matches!(mode, RunMode::Daemon { .. }) {
        let _ = std::fs::remove_file(state_dir.join("daemon.sessions"));
        let info_path = state_dir.join("daemon.info");
        if let Err(e) = std::fs::remove_file(&info_path) {
            log::warn!("failed to remove daemon.info on exit: {e}");
        } else {
            log::info!("daemon.info removed on exit");
        }
    }

    Ok(())
}

fn init_tracing(_cli: &Cli) {
    let level = std::env::var("FLYTERM_SERVER_LOG").unwrap_or_else(|_| "info".into());
    env_logger::Builder::from_default_env()
        .parse_filters(&level)
        .target(env_logger::Target::Stderr)
        .init();
}
