// SPDX-License-Identifier: GPL-3.0-or-later
//! `flyterm-server --install` subcommand.
//!
//! Self-install primitive: the binary on disk (always the *new* version
//! being installed) does the full kill-old → atomic-replace → spawn-new
//! → poll-daemon.info sequence, then prints one structured line:
//!
//!   INSTALL_OK port=<n> pid=<n> version=<v>
//!   INSTALL_ERR reason=<details>

use anyhow::{anyhow, Result};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const KILL_WAIT_MS: u64 = 2000;
const DAEMON_INFO_POLL_MS: u64 = 5000;
const DAEMON_INFO_POLL_INTERVAL_MS: u64 = 100;

/// Resolved paths the installer operates on. Computed once at start.
struct Paths {
    state_dir: PathBuf,
    bin_dir: PathBuf,
    canonical_bin: PathBuf,
    daemon_info: PathBuf,
    daemon_log: PathBuf,
    install_log: PathBuf,
    lock_path: PathBuf,
    self_exe: PathBuf,
}

impl Paths {
    fn resolve() -> Result<Self> {
        let home = std::env::var("HOME").map_err(|_| anyhow!("HOME env not set"))?;
        let state_dir = PathBuf::from(&home).join(".flyterm-server");
        let bin_dir = state_dir.join("bin");
        let self_exe = std::env::current_exe().map_err(|e| anyhow!("current_exe: {e}"))?;
        Ok(Self {
            canonical_bin: bin_dir.join("flyterm-server"),
            daemon_info: state_dir.join("daemon.info"),
            daemon_log: state_dir.join("state").join("daemon.log"),
            install_log: state_dir.join("install.log"),
            lock_path: state_dir.join(".install.lock"),
            bin_dir,
            state_dir,
            self_exe,
        })
    }
}

/// Result of locating the previously-running daemon.
struct OldDaemon {
    pid: i32,
    version: String,
}

/// Public entry point. Returns Ok(()) on INSTALL_OK (after printing the
/// structured line), Err(reason) on INSTALL_ERR (caller prints + exits 1).
///
/// [congestion] 取自本次 `--install` 的命令行，透传给新拉起的 daemon ——
/// 见 [`spawn_daemon`] 上的说明。
pub fn run(congestion: crate::cli::CongestionKind) -> Result<()> {
    let paths = Paths::resolve()?;
    std::fs::create_dir_all(&paths.bin_dir).ok();
    std::fs::create_dir_all(paths.daemon_log.parent().unwrap()).ok();

    // Take exclusive non-blocking flock. Holder of the lock = the
    // currently-running --install. Concurrent attempt fails fast.
    let lock_file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(&paths.lock_path)
        .map_err(|e| anyhow!("open lock_path: {e}"))?;
    nix::fcntl::flock(
        lock_file.as_raw_fd(),
        nix::fcntl::FlockArg::LockExclusiveNonblock,
    )
    .map_err(|_| anyhow!("lock_held"))?;

    let self_version = format!("{}-{}", env!("CARGO_PKG_VERSION"), env!("GIT_SHA"));

    // ── Locate old daemon（daemon.info 快速路径，仅用于 install.log 的版本记录）──
    let old = find_old_daemon(&paths);

    // ── Stop ALL of them ──
    //
    // 不能只杀一个：find_old_daemon 返回 Option<OldDaemon>，无论走 daemon.info
    // 还是它已有的 /proc cmdline 兜底都只给一个（兜底还是第一个匹配就 return），
    // 于是多出来的孤儿永久留存 —— 实测一台机器上 3 个孤儿，最久活了 14h43m，
    // 各自占一个 UDP 端口、一份 SessionStore 和下面全部 PTY 子 shell。
    let killed = reap_all_daemons(&paths);
    if !killed.is_empty() {
        log::info!("reaped {} old daemon(s): {:?}", killed.len(), killed);
    }
    // 把 daemon.info 记的那个 pid 也打出来，好和实际收割的列表对照 ——
    // 两者不一致正是「孤儿是怎么漏掉的」的直接证据：daemon.info 只认识一个。
    //
    // 这一行同时让 `OldDaemon.pid` 保持被读取。收割改走 reap_all_daemons 之后
    // 它不再喂给 kill_daemon，若不用就是死字段；而用 #[allow(dead_code)] 掩掉
    // 只是把「我们丢了一条本来有用的信息」藏起来。
    if let Some(ref od) = old {
        log::info!(
            "daemon.info recorded pid={} version={} (reaped: {:?})",
            od.pid,
            od.version,
            killed
        );
    }
    // daemon.info is removed by the dying daemon's exit handler; clean up
    // just in case (orphan files from --kill-9 etc).
    let _ = std::fs::remove_file(&paths.daemon_info);

    // ── Atomic install: rename self into canonical path if not already there ──
    if paths.self_exe != paths.canonical_bin {
        std::fs::rename(&paths.self_exe, &paths.canonical_bin).map_err(|e| {
            anyhow!(
                "rename_failed errno={} src={} dst={}",
                e.raw_os_error().unwrap_or(0),
                paths.self_exe.display(),
                paths.canonical_bin.display()
            )
        })?;
    }

    append_install_log(&paths.install_log, &self_version, old.as_ref());

    // Wrapper is a convenience, not a requirement — a failure here must
    // never fail the install (the daemon itself is already in place).
    if let Err(e) = write_wrapper(&paths.bin_dir) {
        log::warn!("failed to write flyterm wrapper script: {e}");
    }

    // ── Spawn new daemon via setsid (avoids fork() unsafe) ──
    spawn_daemon(&paths, congestion).map_err(|e| anyhow!("spawn_failed err={e}"))?;

    // ── Wait for daemon.info ──
    let (port, pid) = wait_for_daemon_info(&paths).map_err(|e| {
        anyhow!(
            "daemon_info_timeout err={e} log_tail={}",
            tail_log(&paths.daemon_log, 5)
        )
    })?;

    println!("INSTALL_OK port={port} pid={pid} version={self_version}");
    Ok(())
}

/// 从一组 `(pid, exe_path)` 里挑出该收割的 pid。
///
/// 纯函数，不碰 `/proc` —— 扫描在后续任务的 `scan_proc_exes` 里做，这样判据
/// 本身可测。
///
/// 判据：exe 指向 canonical bin（含原子替换后 readlink 会带的 `" (deleted)"`
/// 后缀），且不是自己。读不到 exe 的（`None`）一律跳过 —— 不认识就不杀，宁可
/// 留孤儿也不能误杀别人家的进程。
pub fn reapable_pids(
    entries: &[(i32, Option<std::path::PathBuf>)],
    canonical_bin: &std::path::Path,
    self_pid: i32,
) -> Vec<i32> {
    let want = canonical_bin.to_string_lossy().to_string();
    entries
        .iter()
        .filter(|(pid, _)| *pid != self_pid)
        .filter_map(|(pid, exe)| {
            let exe = exe.as_ref()?;
            let s = exe.to_string_lossy();
            // rename 之后 readlink 是 "<原路径> (deleted)"
            let base = s.strip_suffix(" (deleted)").unwrap_or(&s);
            (base == want).then_some(*pid)
        })
        .collect()
}

/// 扫 `/proc`，返回本用户所有进程的 `(pid, exe_path)`。
///
/// 只看自己 uid 的进程：`/proc/<pid>/exe` 对别人家的进程读不到，readlink 会
/// 失败并落成 `None`，被 [`reapable_pids`] 跳过。这里显式过滤 uid 是为了少做
/// 无用的 syscall，不是安全边界。
fn scan_proc_exes() -> Vec<(i32, std::path::PathBuf)> {
    let my_uid = nix::unistd::getuid();
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir("/proc") else {
        return out;
    };
    for ent in rd.flatten() {
        let name = ent.file_name();
        let Some(pid) = name.to_str().and_then(|s| s.parse::<i32>().ok()) else {
            continue;
        };
        // uid 过滤：读 /proc/<pid> 目录自身的 owner
        match ent.metadata() {
            Ok(md) => {
                use std::os::unix::fs::MetadataExt;
                if md.uid() != my_uid.as_raw() {
                    continue;
                }
            }
            Err(_) => continue,
        }
        if let Ok(exe) = std::fs::read_link(format!("/proc/{pid}/exe")) {
            out.push((pid, exe));
        }
    }
    out
}

/// 数一下同一个 canonical bin 还有几个实例在跑（不含自己）。
///
/// 供 daemon 启动自检用：**只报数、不杀**。杀是 `--install` 的职责 —— 在启动
/// 路径上杀会让「手动起第二个实例做对比测试」这种正当用法不可能。
pub fn count_sibling_daemons(self_pid: i32) -> usize {
    let Ok(paths) = Paths::resolve() else {
        return 0;
    };
    let entries: Vec<(i32, Option<std::path::PathBuf>)> = scan_proc_exes()
        .into_iter()
        .map(|(p, e)| (p, Some(e)))
        .collect();
    reapable_pids(&entries, &paths.canonical_bin, self_pid).len()
}

/// 收割所有旧 daemon。返回实际杀掉的 pid 列表。
///
/// 这取代了"最多杀一个"：`find_old_daemon` 返回 `Option<OldDaemon>`，无论走
/// `daemon.info` 还是它已有的 `/proc` cmdline 兜底都只给一个，于是多出来的
/// 孤儿永久留存（实测最久 14h43m）。
fn reap_all_daemons(paths: &Paths) -> Vec<i32> {
    let self_pid = std::process::id() as i32;
    let entries: Vec<(i32, Option<std::path::PathBuf>)> = scan_proc_exes()
        .into_iter()
        .map(|(p, e)| (p, Some(e)))
        .collect();
    let targets = reapable_pids(&entries, &paths.canonical_bin, self_pid);
    let mut killed = Vec::new();
    for pid in targets {
        match kill_daemon(pid) {
            Ok(()) => killed.push(pid),
            // 单个杀不掉不该让整次安装失败 —— 它可能刚好自己退了，或是
            // 权限问题。记下来继续，让安装完成。
            Err(e) => log::warn!("reap pid={pid} failed: {e:#}"),
        }
    }
    killed
}

/// Try to find the running daemon by parsing daemon.info. If AQT_PID line
/// is absent (older daemon predating that feature), fall back to /proc
/// scanning for cmdline containing "flyterm-server --listen", owned by us.
fn find_old_daemon(paths: &Paths) -> Option<OldDaemon> {
    if let Ok(s) = std::fs::read_to_string(&paths.daemon_info) {
        let mut pid: Option<i32> = None;
        let mut ver: Option<String> = None;
        for line in s.lines() {
            if let Some(v) = line.strip_prefix("AQT_PID=") {
                pid = v.trim().parse().ok();
            } else if let Some(v) = line.strip_prefix("AQT_VERSION=") {
                ver = Some(v.trim().to_string());
            }
        }
        if let Some(pid) = pid {
            // Verify pid is alive and is our binary (cheap sanity check).
            if Path::new(&format!("/proc/{pid}/exe")).exists() {
                return Some(OldDaemon {
                    pid,
                    version: ver.unwrap_or_default(),
                });
            }
        }
    }
    // Fallback: /proc scan
    if let Ok(entries) = std::fs::read_dir("/proc") {
        for e in entries.flatten() {
            let name = e.file_name();
            let s = name.to_string_lossy();
            let pid: i32 = match s.parse() {
                Ok(p) => p,
                Err(_) => continue,
            };
            let cmdline = match std::fs::read(e.path().join("cmdline")) {
                Ok(b) => b,
                Err(_) => continue,
            };
            // cmdline is NUL-separated; rebuild with spaces
            let joined: String = cmdline
                .split(|b| *b == 0)
                .map(|p| String::from_utf8_lossy(p).into_owned())
                .collect::<Vec<_>>()
                .join(" ");
            if joined.contains("flyterm-server") && joined.contains("--listen") {
                return Some(OldDaemon {
                    pid,
                    version: String::new(),
                });
            }
        }
    }
    None
}

/// SIGTERM → wait up to KILL_WAIT_MS → SIGKILL if still alive.
fn kill_daemon(pid: i32) -> Result<()> {
    use nix::sys::signal::{kill, Signal};
    use nix::unistd::Pid;
    let p = Pid::from_raw(pid);
    let _ = kill(p, Signal::SIGTERM); // ignore "no such process"

    let deadline = Instant::now() + Duration::from_millis(KILL_WAIT_MS);
    while Instant::now() < deadline {
        if !Path::new(&format!("/proc/{pid}")).exists() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = kill(p, Signal::SIGKILL);
    std::thread::sleep(Duration::from_millis(200));
    if Path::new(&format!("/proc/{pid}")).exists() {
        return Err(anyhow!("daemon still alive after SIGKILL"));
    }
    Ok(())
}

/// 拼出重启 daemon 的那条命令（`setsid <bin> --listen 0 --congestion X`）。
///
/// 返回 `Command` 而不是参数数组，是为了让测试能断言**真正会被 exec 的东西**
/// —— `Command::get_args()` 拿到的就是 spawn 时用的那份。抽成「参数数组 +
/// 调用方自己拼」的话，测试只能守住数组的内容，守不住 `spawn_daemon` 有没有
/// 用它；而这一类「flag 在某条路径上悄悄丢掉」正是这个函数存在的原因。
///
/// stdio 与 env 由 [`spawn_daemon`] 补 —— 那两样没法在不落地文件的情况下测。
fn build_daemon_command(bin: &Path, congestion: crate::cli::CongestionKind) -> Command {
    let mut cmd = Command::new("setsid");
    cmd.arg(bin)
        .arg("--listen")
        .arg("0")
        .arg("--congestion")
        .arg(congestion.as_str());
    cmd
}

/// Spawn new daemon via /usr/bin/setsid which forks + setsid()s + exec's
/// our binary. Using setsid the binary avoids needing fork() (which is
/// unsafe-marked in nix and forbidden by our crate-level forbid lint).
///
/// [congestion] 来自本次 `--install` 的命令行 —— 「装的时候要求什么配置，起
/// 起来就是什么配置」。硬编码在这里的话，App 侧在 bootstrap 命令上加的 flag
/// 会被这条路径悄悄绕过：升级流程是二进制自安装、由它自己拉起 daemon，App
/// 随后只是复用已经在跑的那个。
fn spawn_daemon(paths: &Paths, congestion: crate::cli::CongestionKind) -> Result<()> {
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&paths.daemon_log)
        .map_err(|e| anyhow!("open daemon.log: {e}"))?;
    let log_dup = log
        .try_clone()
        .map_err(|e| anyhow!("dup daemon.log: {e}"))?;

    let mut cmd = build_daemon_command(&paths.canonical_bin, congestion);
    cmd.stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_dup));

    // Strip multiplexer env leakage that would otherwise reach child PTYs.
    for k in ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"] {
        cmd.env_remove(k);
    }

    let child = cmd.spawn().map_err(|e| {
        anyhow!(
            "setsid+spawn failed: {e}; \
            hint: setsid binary (util-linux) must be in PATH"
        )
    })?;
    // We don't wait on it — setsid daemonises and the child is now
    // re-parented to init. Drop our handle.
    drop(child);
    Ok(())
}

fn wait_for_daemon_info(paths: &Paths) -> Result<(u16, i32)> {
    let deadline = Instant::now() + Duration::from_millis(DAEMON_INFO_POLL_MS);
    while Instant::now() < deadline {
        if let Ok(s) = std::fs::read_to_string(&paths.daemon_info) {
            let mut port: Option<u16> = None;
            let mut pid: Option<i32> = None;
            for line in s.lines() {
                if let Some(v) = line.strip_prefix("AQT_PORT=") {
                    port = v.trim().parse().ok();
                } else if let Some(v) = line.strip_prefix("AQT_PID=") {
                    pid = v.trim().parse().ok();
                }
            }
            if let (Some(p), Some(i)) = (port, pid) {
                return Ok((p, i));
            }
        }
        std::thread::sleep(Duration::from_millis(DAEMON_INFO_POLL_INTERVAL_MS));
    }
    Err(anyhow!(
        "daemon.info not written within {}ms",
        DAEMON_INFO_POLL_MS
    ))
}

fn append_install_log(path: &Path, new_ver: &str, old: Option<&OldDaemon>) {
    let timestamp = chrono_lite_now();
    let prev = old.map(|o| o.version.as_str()).unwrap_or("(none)");
    let line = format!("[{timestamp}] installed {new_ver} (was {prev}) via --install\n");
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Tiny inline ISO-8601-ish timestamp. We don't depend on chrono in
/// flyterm-server, and rolling our own here avoids a new dep just for one
/// log line. Format: epoch=<unix_secs>.
fn chrono_lite_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // delegate to the kernel via /proc/driver/rtc? overkill — use the C
    // strftime approach via libc? also overkill. The line is for humans;
    // a Unix timestamp is fine and unambiguous.
    format!("epoch={secs}")
}

/// `~/.flyterm-server/bin/flyterm` 的内容。
///
/// `flyterm_server_bin` 是烘进脚本里的**绝对路径**，而不是靠 `$(dirname "$0")`
/// 在运行时反推。原因：
///
/// - 这个 wrapper 装完之后，用户最自然的"弄上 PATH"手法是
///   `ln -s ~/.flyterm-server/bin/flyterm /usr/local/bin/flyterm`（比改 shell rc
///   的 `export PATH=...` 更常见，且后者只对交互 shell 生效）。`$(dirname "$0")`
///   在这种软链接场景下拿到的是软链接自身所在目录，不是真实 bin 目录，会跑错。
/// - 修 `$(dirname "$0")` 的常见办法是 `readlink -f "$0"` 先解析软链接，但
///   `readlink -f` 不是 POSIX，musl/busybox 环境下行为不一致——用一个可移植性
///   问题去修另一个可移植性问题，得不偿失。
/// - 烘绝对路径的代价：如果用户手动搬动 `~/.flyterm-server/` 这个目录，wrapper
///   就会失效。这个代价可以接受——那个目录是 App 固定管理的位置，搬动它本来
///   就需要重装；而"软链接到 PATH"是装完就可能立刻发生的常规操作，两者概率
///   不是一个量级。
///
/// 透传全部参数而不是写死 `notify`：将来加子命令时不用改 wrapper，也不用让用户重装。
/// 用 exec 保证退出码原样透传——`flyterm notify` 恒返回 0 的语义依赖这一点。
/// 用 sh 而非 bash：musl 目标机可能没有 bash。
pub fn wrapper_script_contents(flyterm_server_bin: &Path) -> String {
    format!(
        "#!/bin/sh\nexec \"{}\" \"$@\"\n",
        flyterm_server_bin.display()
    )
}

/// 在二进制旁边写一个 `flyterm` wrapper 并置为可执行。
///
/// `bin_dir` 必须是绝对路径——它会被原样烘进 wrapper 脚本（见
/// `wrapper_script_contents`），传相对路径会做出一个只在特定 cwd 下才
/// 有效的 wrapper。调用方（`run()`）传入的 `paths.bin_dir` 源自
/// `$HOME`，天然是绝对路径。
///
/// 调用方必须把失败当作非致命警告处理——wrapper 只是命令行便利品，
/// 不应该因为它写失败就回滚整个 daemon 安装。
pub fn write_wrapper(bin_dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let path = bin_dir.join("flyterm");
    let target = bin_dir.join("flyterm-server");
    std::fs::write(&path, wrapper_script_contents(&target))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))
}

fn tail_log(path: &Path, n: usize) -> String {
    let s = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(_) => return String::from("(daemon.log unreadable)"),
    };
    let lines: Vec<&str> = s.lines().collect();
    let start = lines.len().saturating_sub(n);
    lines[start..].join(" || ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// 自安装重启出来的 daemon 必须带上安装时指定的拥塞控制算法。
    ///
    /// 漏掉它的后果特别隐蔽：装完一切正常、连接也正常，只是 daemon 悄悄回到
    /// 了默认的 CUBIC，而客户端那边看到的现象是「BBR 一点效果都没有」——
    /// 会被归因成「BBR 不管用」，而不是「BBR 压根没开」。
    fn argv_of(cmd: &Command) -> Vec<String> {
        cmd.get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn daemon_command_carries_congestion() {
        let cmd = build_daemon_command(
            Path::new("/x/flyterm-server"),
            crate::cli::CongestionKind::Bbr,
        );
        // 整条 argv 全等而不是「包含 --congestion」：这样多一个、少一个、顺序
        // 变了都会被抓到。端口 0 = 随机口，daemon 自己写进 daemon.info。
        assert_eq!(
            argv_of(&cmd),
            ["/x/flyterm-server", "--listen", "0", "--congestion", "bbr"]
        );
        assert_eq!(cmd.get_program(), "setsid");
    }

    #[test]
    fn daemon_command_passes_cubic_through() {
        let cmd = build_daemon_command(
            Path::new("/x/flyterm-server"),
            crate::cli::CongestionKind::Cubic,
        );
        assert_eq!(
            argv_of(&cmd),
            [
                "/x/flyterm-server",
                "--listen",
                "0",
                "--congestion",
                "cubic"
            ]
        );
    }

    #[test]
    fn daemon_info_parse_with_pid() {
        let tmp = TempDir::new().unwrap();
        let info = tmp.path().join("daemon.info");
        // Use PID 99999 — this PID is almost certainly dead. If find_old_daemon
        // returns Some, it came from either (a) /proc/99999/exe existing (rare),
        // or (b) the /proc fallback scan finding a real flyterm-server --listen
        // process. Either way, what we're verifying here is that a dead PID
        // from daemon.info is NOT returned directly from the pid-check branch.
        // We check this by reading version from the result: if found, the PID
        // must NOT be 99999 (it came from /proc fallback, which is correct
        // behaviour — there IS an flyterm-server running in that case).
        std::fs::write(
            &info,
            "AQT_PORT=12345\nAQT_PUBKEY=abc\nAQT_VERSION=0.2.0-test\nAQT_PID=99999\n",
        )
        .unwrap();
        let paths = Paths {
            state_dir: tmp.path().to_path_buf(),
            bin_dir: tmp.path().join("bin"),
            canonical_bin: tmp.path().join("bin/flyterm-server"),
            daemon_info: info,
            daemon_log: tmp.path().join("state/daemon.log"),
            install_log: tmp.path().join("install.log"),
            lock_path: tmp.path().join(".install.lock"),
            self_exe: tmp.path().join("self_exe_stub"),
        };
        // If PID 99999 is dead, the pid-check branch skips it. The /proc
        // fallback may or may not find a real daemon — either outcome is valid.
        // What must NOT happen: find_old_daemon returns Some with pid=99999
        // when /proc/99999/exe does not exist.
        let proc_99999_exists = std::path::Path::new("/proc/99999/exe").exists();
        let found = find_old_daemon(&paths);
        if !proc_99999_exists {
            // If there IS a result, it came from /proc scan (a real daemon) — pid != 99999.
            if let Some(ref od) = found {
                assert_ne!(
                    od.pid, 99999,
                    "dead PID 99999 must not be returned from pid-check branch"
                );
            }
            // found may be Some (real daemon) or None (no daemon) — both ok.
        }
        // If proc_99999_exists, a process really is at 99999, so Some is correct.
    }

    #[test]
    fn wait_for_daemon_info_picks_up_pid_and_port() {
        let tmp = TempDir::new().unwrap();
        let info = tmp.path().join("daemon.info");
        let paths = Paths {
            state_dir: tmp.path().to_path_buf(),
            bin_dir: tmp.path().join("bin"),
            canonical_bin: tmp.path().join("bin/flyterm-server"),
            daemon_info: info.clone(),
            daemon_log: tmp.path().join("state/daemon.log"),
            install_log: tmp.path().join("install.log"),
            lock_path: tmp.path().join(".install.lock"),
            self_exe: tmp.path().join("self_exe_stub"),
        };
        // Write daemon.info before calling — wait_for should return immediately.
        std::fs::write(
            &info,
            "AQT_PORT=7777\nAQT_PUBKEY=x\nAQT_VERSION=v\nAQT_PID=1\n",
        )
        .unwrap();
        let (port, pid) = wait_for_daemon_info(&paths).unwrap();
        assert_eq!(port, 7777);
        assert_eq!(pid, 1);
    }

    #[test]
    fn wrapper_script_passes_all_args_through() {
        let bin = Path::new("/home/u/.flyterm-server/bin/flyterm-server");
        let s = wrapper_script_contents(bin);
        assert!(s.contains("exec"), "必须 exec 而非 fork，保证退出码透传");
        assert!(
            s.contains("\"$@\""),
            "必须透传全部参数——写死 notify 会挡住未来的子命令"
        );
        assert!(
            s.starts_with("#!/bin/sh\n"),
            "用 sh 而非 bash：musl 目标机可能没有 bash"
        );
        assert!(
            s.contains("/home/u/.flyterm-server/bin/flyterm-server"),
            "必须烘入调用方传入的绝对路径，而不是靠 $(dirname \"$0\") 在运行时反推——\
             后者在软链接场景（如 ln -s 到 /usr/local/bin）下会解析到错误目录"
        );
        assert!(
            !s.contains("dirname"),
            "不应该再依赖 $(dirname \"$0\")：软链接调用时它会解析到软链接自身所在\
             目录而非真实 bin 目录"
        );
    }

    #[test]
    fn wait_for_daemon_info_times_out_when_file_missing() {
        let tmp = TempDir::new().unwrap();
        let paths = Paths {
            state_dir: tmp.path().to_path_buf(),
            bin_dir: tmp.path().join("bin"),
            canonical_bin: tmp.path().join("bin/flyterm-server"),
            daemon_info: tmp.path().join("nonexistent.info"),
            daemon_log: tmp.path().join("state/daemon.log"),
            install_log: tmp.path().join("install.log"),
            lock_path: tmp.path().join(".install.lock"),
            self_exe: tmp.path().join("self_exe_stub"),
        };
        // Constants are 5s + 100ms poll — this test runs the full timeout.
        // Acceptable: 5s in a unit suite. Could be parameterised in future.
        let r = wait_for_daemon_info(&paths);
        assert!(r.is_err());
        let msg = format!("{}", r.unwrap_err());
        assert!(msg.contains("not written within"), "got: {msg}");
    }
}
