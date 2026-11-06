// SPDX-License-Identifier: GPL-3.0-or-later
use once_cell::sync::Lazy;
use std::sync::Arc;
use std::thread;
use tokio::sync::mpsc;

pub type BoxedFn = Box<dyn FnOnce(&tokio::runtime::Handle) + Send + 'static>;

pub struct AsyncRuntime {
    tx: mpsc::UnboundedSender<BoxedFn>,
}

impl AsyncRuntime {
    fn new() -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel::<BoxedFn>();
        thread::Builder::new()
            .name("aqt-rt".into())
            .spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("aqt tokio runtime");
                let handle = rt.handle().clone();
                // Use .recv().await so the tokio event loop can run spawned
                // tasks between dispatch calls. std::sync::mpsc::recv() blocks
                // the thread and prevents spawned async tasks from executing.
                rt.block_on(async move {
                    while let Some(f) = rx.recv().await {
                        f(&handle);
                    }
                });
            })
            .expect("spawn aqt-rt");
        Self { tx }
    }

    pub fn dispatch<F>(&self, f: F)
    where
        F: FnOnce(&tokio::runtime::Handle) + Send + 'static,
    {
        let _ = self.tx.send(Box::new(f));
    }
}

pub static RUNTIME: Lazy<Arc<AsyncRuntime>> = Lazy::new(|| Arc::new(AsyncRuntime::new()));

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[test]
    fn dispatch_runs_closure() {
        let done = Arc::new(AtomicBool::new(false));
        let d = done.clone();
        RUNTIME.dispatch(move |_| d.store(true, Ordering::SeqCst));
        std::thread::sleep(std::time::Duration::from_millis(200));
        assert!(done.load(Ordering::SeqCst));
    }

    #[test]
    fn spawned_async_task_executes() {
        // Verify that tokio::spawn inside a dispatch closure actually runs.
        // This would FAIL with std::sync::mpsc::recv() because it blocks
        // the event loop, preventing spawned tasks from executing.
        let (tx, rx) = std::sync::mpsc::channel::<i32>();
        RUNTIME.dispatch(move |rt| {
            let tx = tx.clone();
            rt.spawn(async move {
                tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
                tx.send(42).ok();
            });
        });
        let val = rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("async task never ran");
        assert_eq!(val, 42);
    }
}
