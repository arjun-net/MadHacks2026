use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::Notify;

use crate::models::Point;
use crate::store::Store;

const MAX_PER_INSERT: usize = 500;

/// Accepts points instantly; flushes to the store in batches in the background.
pub struct WriteBuffer {
    store: Arc<Store>,
    pending: Mutex<Vec<Point>>,
    wake: Notify,
    batch_size: usize,
}

impl WriteBuffer {
    pub fn new(store: Arc<Store>, batch_size: usize) -> Arc<Self> {
        Arc::new(Self { store, pending: Mutex::new(Vec::new()), wake: Notify::new(), batch_size })
    }

    pub fn add(&self, points: Vec<Point>) {
        let mut pending = self.pending.lock().unwrap();
        pending.extend(points);
        if pending.len() >= self.batch_size {
            self.wake.notify_one();
        }
    }

    pub async fn flush(&self) {
        loop {
            let batch: Vec<Point> = {
                let mut pending = self.pending.lock().unwrap();
                let n = pending.len().min(MAX_PER_INSERT);
                pending.drain(..n).collect()
            };
            if batch.is_empty() {
                return;
            }
            if let Err(e) = self.store.add_many(&batch).await {
                tracing::error!("flush failed; re-queueing {} points: {e}", batch.len());
                let mut pending = self.pending.lock().unwrap();
                pending.splice(0..0, batch);
                return;
            }
        }
    }

    pub fn start(self: &Arc<Self>, interval: Duration) {
        let this = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                let _ = tokio::time::timeout(interval, this.wake.notified()).await;
                this.flush().await;
            }
        });
    }
}
