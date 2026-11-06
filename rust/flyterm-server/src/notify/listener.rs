// SPDX-License-Identifier: GPL-3.0-or-later
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use tokio::io::AsyncReadExt;
use tokio::net::UnixListener;
use tokio::sync::Semaphore;

/// socket 相对 state_dir 的文件名。
pub const NOTIFY_SOCK_NAME: &str = "notify.sock";

/// 单条投递最多读这么多字节，多的丢弃。消毒阶段还会再截到 512。
const MAX_LINE_BYTES: usize = 8192;

/// 单个连接的读超时。一行消息应该是瞬时的；连了不发数据的连接大概率是
/// 恶意/异常客户端，用超时踢掉它，防止 fd/内存无限增长。
const READ_TIMEOUT: Duration = Duration::from_secs(5);

/// 同时处理的连接上限。同机任意用户都能无限 connect() 又不发数据，靠这个
/// permit 数硬顶住而不是无限 spawn——这个 daemon 同时扛着用户的 QUIC 会话，
/// notify 功能不该有能力把它拖垮。
const MAX_CONCURRENT_CONNECTIONS: usize = 64;

/// accept() 持续失败（例如触发 EMFILE/ENFILE）时的退避间隔，避免忙等把
/// CPU 打满。
const ACCEPT_ERROR_BACKOFF: Duration = Duration::from_millis(100);

/// 解析一行投递：可选 `tab=<n> ` 前缀 + 正文。
///
/// 刻意宽容：前缀解析失败时整行当正文，而不是报错丢掉事件。用户执行了
/// `flyterm notify` 就是想收到通知，因为格式问题静默吞掉是最坏的结果。
pub fn parse_notify_line(line: &str) -> (Option<u32>, String) {
    if let Some(rest) = line.strip_prefix("tab=") {
        if let Some((num, text)) = rest.split_once(' ') {
            if let Ok(id) = num.parse::<u32>() {
                return (Some(id), text.to_string());
            }
        }
    }
    (None, line.to_string())
}

pub fn sock_path(state_dir: &Path) -> PathBuf {
    state_dir.join(NOTIFY_SOCK_NAME)
}

/// 绑定 unix socket。已存在的残留 socket 文件先删掉（daemon 崩溃会留下）。
///
/// 权限设 0600（纵深防御，成本为零）。真正挡住其它用户的是目录本身：
/// `connect()` 到 `<dir>/notify.sock` 需要对 `<dir>` 有搜索(执行)权限，
/// 所以把 state_dir 锁到 0700 就让其他用户根本穿不过来。
///
/// 没有用「bind 之后 chmod socket」当唯一防线，是因为 `UnixListener::bind`
/// 创建文件用的是 `0777 & ~umask`，chmod(0600) 是紧随其后的第二个
/// syscall——中间有一个窗口，实际权限取决于运行 daemon 时的 umask。umask
/// 002 时窗口内是 0775，同组用户能在 chmod 生效前 connect 上，而已建立的
/// 连接不会被后续 chmod 踢掉。目录方案把这个窗口彻底消除：目录权限在
/// bind() 之前就设好，且不需要 unsafe（这个 crate 是 `forbid(unsafe_code)`，
/// 用 `libc::umask` 包 unsafe 换不来足够的收益）。
pub fn bind(state_dir: &Path) -> Result<UnixListener> {
    std::fs::create_dir_all(state_dir)
        .with_context(|| format!("create state dir {}", state_dir.display()))?;
    std::fs::set_permissions(state_dir, std::fs::Permissions::from_mode(0o700))
        .with_context(|| format!("chmod 0700 {}", state_dir.display()))?;

    let path = sock_path(state_dir);
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)
        .with_context(|| format!("bind notify socket at {}", path.display()))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .with_context(|| format!("chmod 0600 {}", path.display()))?;
    Ok(listener)
}

/// 接受投递并交给 `on_event`。每个连接读一行就关。
///
/// 三道纵深防御针对同一个 DoS 面：同机任意用户（不需要 root）能无限
/// `connect()` 又不发数据，这个 daemon 同时扛着用户的 QUIC 会话，notify
/// 功能没有资格把它拖垮：
/// - peer uid 校验：目录已经是 0700，正常情况下只有自己能连上；但目录权限
///   将来可能被别的代码路径放宽，peer uid 校验是唯一能在事后（连接已建立）
///   挡住的手段，一次 syscall 成本可忽略。
/// - 并发上限（Semaphore）：拿不到 permit 直接丢连接，不排队等——通知丢
///   一条远好过把 daemon 拖垮。
/// - 读超时：一行消息应该是瞬时的，连了不发数据的连接 5 秒后强制丢弃。
pub async fn serve<F>(listener: UnixListener, on_event: Arc<F>) -> Result<()>
where
    F: Fn(Option<u32>, String) + Send + Sync + 'static,
{
    let own_uid = nix::unistd::Uid::current().as_raw();
    let permits = Arc::new(Semaphore::new(MAX_CONCURRENT_CONNECTIONS));

    loop {
        let (stream, _) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                log::warn!("notify socket accept failed: {e:#}");
                // 避免 EMFILE/ENFILE 这类持续性错误下的忙等热循环。
                tokio::time::sleep(ACCEPT_ERROR_BACKOFF).await;
                continue;
            }
        };

        match stream.peer_cred() {
            Ok(cred) if cred.uid() == own_uid => {}
            Ok(cred) => {
                log::warn!(
                    "notify socket rejected: peer uid {} != {own_uid}",
                    cred.uid()
                );
                continue;
            }
            Err(e) => {
                log::warn!("notify socket peer_cred failed: {e:#}");
                continue;
            }
        }

        let permit = match Arc::clone(&permits).try_acquire_owned() {
            Ok(p) => p,
            Err(_) => {
                log::warn!(
                    "notify socket at capacity ({MAX_CONCURRENT_CONNECTIONS}), dropping connection"
                );
                continue;
            }
        };

        let cb = Arc::clone(&on_event);
        tokio::spawn(async move {
            let _permit = permit;
            let mut stream = stream;
            let mut buf = Vec::with_capacity(256);
            let mut chunk = [0u8; 1024];
            // 内层 async 块用 Result 显式区分「读完/截断」vs「读错误」——
            // 不能用裸 `return`，因为那只会退出内层块（让 timeout 看到
            // Ok(())），外层还会照常把半截/空 buf 当成功处理下去。
            let read_result: Result<Result<(), ()>, tokio::time::error::Elapsed> =
                tokio::time::timeout(READ_TIMEOUT, async {
                    loop {
                        match stream.read(&mut chunk).await {
                            Ok(0) => return Ok(()),
                            Ok(n) => {
                                buf.extend_from_slice(&chunk[..n]);
                                if buf.len() >= MAX_LINE_BYTES {
                                    buf.truncate(MAX_LINE_BYTES);
                                    return Ok(());
                                }
                            }
                            Err(e) => {
                                log::warn!("notify socket read failed: {e:#}");
                                return Err(());
                            }
                        }
                    }
                })
                .await;
            match read_result {
                Ok(Ok(())) => {}
                Ok(Err(())) => return, // 读错误已经在上面 log 过了
                Err(_) => {
                    log::warn!("notify socket read timed out after {READ_TIMEOUT:?}");
                    return;
                }
            }
            let line = String::from_utf8_lossy(&buf).to_string();
            let (tab_id, text) = parse_notify_line(line.trim_end_matches('\n'));
            log::info!("notify received tab={tab_id:?} len={}", text.len());
            cb(tab_id, text);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// bind() 目前零测试。锁定权限位，防止以后重构悄悄删掉「目录 0700 +
    /// socket 0600」这两步——尤其是目录权限，那才是真正挡住其他用户的
    /// 防线（socket 权限只是纵深防御）。用 `std::env::temp_dir()` +
    /// 进程号/纳秒时间戳拼一个大概率不冲突的子目录名，不引入 `tempfile`
    /// crate；测试结束手动 `remove_dir_all` 清理。
    #[tokio::test]
    async fn bind_locks_down_directory_and_socket_permissions() {
        let dir = std::env::temp_dir().join(format!(
            "flyterm-notify-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));

        let _listener = bind(&dir).expect("bind should succeed against a fresh temp dir");

        let dir_mode = std::fs::metadata(&dir)
            .expect("state dir should exist after bind()")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(dir_mode, 0o700, "state dir should be locked to 0700");

        let sock_mode = std::fs::metadata(sock_path(&dir))
            .expect("socket file should exist after bind()")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(sock_mode, 0o600, "socket file should be locked to 0600");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn parses_tab_id_prefixed_line() {
        let (tab, text) = parse_notify_line("tab=7 构建完成");
        assert_eq!(tab, Some(7));
        assert_eq!(text, "构建完成");
    }

    #[test]
    fn parses_line_without_tab_prefix() {
        let (tab, text) = parse_notify_line("构建完成");
        assert_eq!(tab, None);
        assert_eq!(text, "构建完成");
    }

    #[test]
    fn malformed_tab_prefix_is_treated_as_text() {
        // 用户真的发了 "tab=abc 什么的"，不该报错丢事件——降级成正文。
        let (tab, text) = parse_notify_line("tab=abc hello");
        assert_eq!(tab, None);
        assert_eq!(text, "tab=abc hello");
    }

    #[test]
    fn text_containing_equals_is_not_mangled() {
        let (tab, text) = parse_notify_line("FOO=bar done");
        assert_eq!(tab, None);
        assert_eq!(text, "FOO=bar done");
    }

    #[test]
    fn tab_prefix_with_empty_text() {
        let (tab, text) = parse_notify_line("tab=3 ");
        assert_eq!(tab, Some(3));
        assert_eq!(text, "");
    }
}
