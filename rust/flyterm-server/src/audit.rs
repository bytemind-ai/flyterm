// SPDX-License-Identifier: GPL-3.0-or-later
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::sync::Mutex;

#[derive(Clone)]
pub struct AuditLog {
    inner: Arc<Mutex<Option<tokio::fs::File>>>,
}

pub enum AuditEvent<'a> {
    SessionCreated {
        token_short: &'a str,
        remote: &'a str,
    },
    SessionClosed {
        token_short: &'a str,
    },
    TabOpened {
        token_short: &'a str,
        tab_id: u32,
    },
    TabClosed {
        token_short: &'a str,
        tab_id: u32,
    },
    FileUploadStart {
        token_short: &'a str,
        request_id: u32,
        path: &'a str,
        size: u64,
    },
    FileUploadEnd {
        token_short: &'a str,
        request_id: u32,
        status: &'a str,
        bytes: u64,
    },
    FileDownloadStart {
        token_short: &'a str,
        request_id: u32,
        path: &'a str,
    },
    FileDownloadEnd {
        token_short: &'a str,
        request_id: u32,
        status: &'a str,
        bytes: u64,
    },
}

impl AuditEvent<'_> {
    fn to_json(&self) -> String {
        match self {
            Self::SessionCreated {
                token_short,
                remote,
            } => format!(
                r#"{{"event":"session_created","token_short":{token_short:?},"remote":{remote:?}}}"#
            ),
            Self::SessionClosed { token_short } => {
                format!(r#"{{"event":"session_closed","token_short":{token_short:?}}}"#)
            }
            Self::TabOpened {
                token_short,
                tab_id,
            } => format!(
                r#"{{"event":"tab_opened","token_short":{token_short:?},"tab_id":{tab_id}}}"#
            ),
            Self::TabClosed {
                token_short,
                tab_id,
            } => format!(
                r#"{{"event":"tab_closed","token_short":{token_short:?},"tab_id":{tab_id}}}"#
            ),
            Self::FileUploadStart {
                token_short,
                request_id,
                path,
                size,
            } => format!(
                r#"{{"event":"file_upload_start","token_short":{token_short:?},"request_id":{request_id},"path":{path:?},"size":{size}}}"#
            ),
            Self::FileUploadEnd {
                token_short,
                request_id,
                status,
                bytes,
            } => format!(
                r#"{{"event":"file_upload_end","token_short":{token_short:?},"request_id":{request_id},"status":{status:?},"bytes":{bytes}}}"#
            ),
            Self::FileDownloadStart {
                token_short,
                request_id,
                path,
            } => format!(
                r#"{{"event":"file_download_start","token_short":{token_short:?},"request_id":{request_id},"path":{path:?}}}"#
            ),
            Self::FileDownloadEnd {
                token_short,
                request_id,
                status,
                bytes,
            } => format!(
                r#"{{"event":"file_download_end","token_short":{token_short:?},"request_id":{request_id},"status":{status:?},"bytes":{bytes}}}"#
            ),
        }
    }
}

impl AuditLog {
    pub async fn new(path: Option<PathBuf>) -> std::io::Result<Self> {
        let f = match path {
            Some(p) => {
                if let Some(parent) = p.parent() {
                    tokio::fs::create_dir_all(parent).await.ok();
                }
                Some(
                    tokio::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(p)
                        .await?,
                )
            }
            None => None,
        };
        Ok(Self {
            inner: Arc::new(Mutex::new(f)),
        })
    }

    pub async fn write(&self, event: AuditEvent<'_>) {
        let line = event.to_json();
        let mut inner = self.inner.lock().await;
        if let Some(f) = inner.as_mut() {
            let _ = f.write_all(line.as_bytes()).await;
            let _ = f.write_all(b"\n").await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn writes_jsonl() {
        let tmp = TempDir::new().unwrap();
        let log_path = tmp.path().join("audit.log");
        let log = AuditLog::new(Some(log_path.clone())).await.unwrap();
        log.write(AuditEvent::SessionCreated {
            token_short: "abcd1234",
            remote: "127.0.0.1:1234",
        })
        .await;
        log.write(AuditEvent::TabOpened {
            token_short: "abcd1234",
            tab_id: 1,
        })
        .await;
        let content = tokio::fs::read_to_string(&log_path).await.unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("session_created"));
        assert!(lines[1].contains("tab_opened"));
    }
}
