// SPDX-License-Identifier: GPL-3.0-or-later
use anyhow::{anyhow, Result};
use aqt_protocol::{
    encode_frame, FileDone, FileDoneStatus, FileMode, FileProgress, FramePayload, OpenFile,
    OpenFileAck, OpenFileStatus,
};
use bytes::BytesMut;
use quinn::{Connection, RecvStream, SendStream};
use ring::digest as ring_digest;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::sync::Mutex;

pub struct FileHandlerCfg {
    pub allow_anywhere: bool,
}

pub fn resolve_safe_path(p: &str, allow_anywhere: bool) -> Result<PathBuf> {
    let pb = PathBuf::from(p);
    let abs = if pb.is_absolute() {
        pb
    } else {
        std::env::current_dir()?.join(pb)
    };
    let canonical = abs.canonicalize().unwrap_or_else(|_| abs.clone());
    if allow_anywhere {
        return Ok(canonical);
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("HOME not set"))?;
    let home_c = home.canonicalize().unwrap_or(home);
    if !canonical.starts_with(&home_c) {
        return Err(anyhow!("path escapes $HOME: {canonical:?}"));
    }
    Ok(canonical)
}

pub async fn handle_open_file(
    req: OpenFile,
    conn: &Connection,
    ctrl_tx: Arc<Mutex<SendStream>>,
    cfg: &FileHandlerCfg,
) -> Result<()> {
    let resolved = match resolve_safe_path(&req.path, cfg.allow_anywhere) {
        Ok(p) => p,
        Err(e) => {
            log::warn!("path rejected: {e:#}");
            send_ack(
                &ctrl_tx,
                req.request_id,
                0,
                OpenFileStatus::PathInvalid,
                0,
                [0; 32],
            )
            .await?;
            return Ok(());
        }
    };

    let (mut file_send, mut file_recv) = conn
        .open_bi()
        .await
        .map_err(|e| anyhow!("open file bidi: {e}"))?;
    let file_stream_id = u64::from(file_send.id());

    let existing_size = tokio::fs::metadata(&resolved)
        .await
        .map(|m| m.len())
        .unwrap_or(0);
    send_ack(
        &ctrl_tx,
        req.request_id,
        file_stream_id,
        OpenFileStatus::Ok,
        existing_size,
        [0; 32],
    )
    .await?;

    let ctrl_c = Arc::clone(&ctrl_tx);
    let request_id = req.request_id;
    match req.mode {
        FileMode::Upload | FileMode::UploadResume => {
            tokio::spawn(async move {
                if let Err(e) = do_upload(
                    request_id,
                    &req.sha256_full,
                    resolved,
                    &mut file_recv,
                    &ctrl_c,
                )
                .await
                {
                    log::warn!("upload {request_id} failed: {e:#}");
                }
            });
        }
        FileMode::Download | FileMode::DownloadResume => {
            tokio::spawn(async move {
                if let Err(e) = do_download(
                    request_id,
                    req.resume_offset,
                    resolved,
                    &mut file_send,
                    &ctrl_c,
                )
                .await
                {
                    log::warn!("download {request_id} failed: {e:#}");
                }
            });
        }
    }
    Ok(())
}

async fn send_ack(
    ctrl_tx: &Arc<Mutex<SendStream>>,
    request_id: u32,
    file_stream_id: u64,
    status: OpenFileStatus,
    existing_size: u64,
    existing_sha256: [u8; 32],
) -> Result<()> {
    let ack = OpenFileAck {
        request_id,
        file_stream_id,
        status,
        existing_size,
        existing_sha256,
    };
    let mut buf = BytesMut::new();
    encode_frame(&ack, &mut buf)?;
    ctrl_tx.lock().await.write_all(&buf).await?;
    Ok(())
}

async fn send_progress(
    ctrl_tx: &Arc<Mutex<SendStream>>,
    request_id: u32,
    bytes_done: u64,
    throughput: u32,
) {
    let p = FileProgress {
        request_id,
        bytes_done,
        throughput_bps: throughput,
    };
    let mut buf = BytesMut::new();
    if encode_frame(&p, &mut buf).is_ok() {
        let _ = ctrl_tx.lock().await.write_all(&buf).await;
    }
}

async fn send_done(
    ctrl_tx: &Arc<Mutex<SendStream>>,
    request_id: u32,
    sha256: [u8; 32],
    status: FileDoneStatus,
) -> Result<()> {
    let done = FileDone {
        request_id,
        sha256,
        status,
    };
    let mut buf = BytesMut::new();
    encode_frame(&done, &mut buf)?;
    ctrl_tx.lock().await.write_all(&buf).await?;
    Ok(())
}

async fn do_upload(
    request_id: u32,
    expected_sha256: &[u8; 32],
    path: PathBuf,
    recv: &mut RecvStream,
    ctrl_tx: &Arc<Mutex<SendStream>>,
) -> Result<FileDoneStatus> {
    let mut file = File::create(&path)
        .await
        .map_err(|e| anyhow!("create: {e}"))?;
    let mut ctx = ring_digest::Context::new(&ring_digest::SHA256);
    let mut bytes_done = 0u64;
    let mut last_prog = Instant::now();
    let mut last_bytes = 0u64;
    let mut tmp = [0u8; 8192];
    loop {
        match recv.read(&mut tmp).await {
            Ok(Some(n)) => {
                file.write_all(&tmp[..n]).await?;
                ctx.update(&tmp[..n]);
                bytes_done += n as u64;
                let now = Instant::now();
                if bytes_done - last_bytes >= 256 * 1024
                    || now.duration_since(last_prog) >= Duration::from_millis(200)
                {
                    let tp = ((bytes_done - last_bytes) as f64
                        / now.duration_since(last_prog).as_secs_f64().max(0.001))
                        as u32;
                    send_progress(ctrl_tx, request_id, bytes_done, tp).await;
                    last_prog = now;
                    last_bytes = bytes_done;
                }
            }
            Ok(None) => break,
            Err(e) => return Err(anyhow!("recv: {e}")),
        }
    }
    file.flush().await?;
    let final_hash: [u8; 32] = ctx.finish().as_ref().try_into().unwrap();
    let status = if &final_hash == expected_sha256 {
        FileDoneStatus::Ok
    } else {
        FileDoneStatus::HashMismatch
    };
    send_done(ctrl_tx, request_id, final_hash, status).await?;
    Ok(status)
}

async fn do_download(
    request_id: u32,
    resume_offset: u64,
    path: PathBuf,
    send: &mut SendStream,
    ctrl_tx: &Arc<Mutex<SendStream>>,
) -> Result<FileDoneStatus> {
    let mut file = File::open(&path).await.map_err(|e| anyhow!("open: {e}"))?;
    if resume_offset > 0 {
        file.seek(std::io::SeekFrom::Start(resume_offset)).await?;
    }
    let mut ctx = ring_digest::Context::new(&ring_digest::SHA256);
    let mut bytes_done = resume_offset;
    let mut last_prog = Instant::now();
    let mut last_bytes = resume_offset;
    let mut tmp = [0u8; 8192];
    loop {
        let n = file.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        send.write_all(&tmp[..n])
            .await
            .map_err(|e| anyhow!("send: {e}"))?;
        ctx.update(&tmp[..n]);
        bytes_done += n as u64;
        let now = Instant::now();
        if bytes_done - last_bytes >= 256 * 1024
            || now.duration_since(last_prog) >= Duration::from_millis(200)
        {
            let tp = ((bytes_done - last_bytes) as f64
                / now.duration_since(last_prog).as_secs_f64().max(0.001))
                as u32;
            send_progress(ctrl_tx, request_id, bytes_done, tp).await;
            last_prog = now;
            last_bytes = bytes_done;
        }
    }
    // finish() only queues the FIN; wait (bounded) until the client has
    // read everything, so FileDone on the control stream can't overtake the
    // tail of the file data. (handle_open_file is not dispatched from
    // connection.rs today — the App transfers files over SFTP.)
    send.finish().ok();
    if tokio::time::timeout(Duration::from_secs(10), send.stopped())
        .await
        .is_err()
    {
        log::warn!("download {request_id}: peer did not confirm stream end within 10 s");
    }
    let final_hash: [u8; 32] = ctx.finish().as_ref().try_into().unwrap();
    send_done(ctrl_tx, request_id, final_hash, FileDoneStatus::Ok).await?;
    Ok(FileDoneStatus::Ok)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_path_inside_home() {
        std::env::set_var("HOME", "/tmp");
        let p = resolve_safe_path("/tmp/foo.txt", false).unwrap();
        assert!(p.starts_with("/tmp"));
    }

    #[test]
    fn safe_path_outside_home_rejected() {
        std::env::set_var("HOME", "/tmp");
        assert!(resolve_safe_path("/etc/shadow", false).is_err());
    }

    #[test]
    fn allow_anywhere_passes() {
        assert!(resolve_safe_path("/etc/hostname", true).is_ok());
    }
}
