//! Dev-only ingest sink: accepts batched device pings and keeps counters.
//! Not part of the pipeline — exists so the sender has a local FastAPI-shaped
//! target to post to during development.

use axum::{extract::Json, routing::post, Router};
use serde::Deserialize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

#[derive(Deserialize)]
struct Ping {
    #[serde(default)]
    agent_id: u32,
    timestamp: String,
    #[allow(dead_code)]
    minute_of_day: u16,
    #[allow(dead_code)]
    state: String,
    #[allow(dead_code)]
    building_id: String,
    lat: f64,
    lng: f64,
}

async fn health() -> &'static str {
    "ok"
}

async fn ingest(Json(pings): Json<Vec<Ping>>) -> String {
    let n = pings.len();
    TOTAL.fetch_add(n as u64, Ordering::Relaxed);
    BATCHES.fetch_add(1, Ordering::Relaxed);
    format!("{{\"accepted\":{}}}", n)
}

async fn stats() -> String {
    format!(
        "{{\"batches\":{},\"pings\":{}}}",
        BATCHES.load(Ordering::Relaxed),
        TOTAL.load(Ordering::Relaxed)
    )
}

static TOTAL: AtomicU64 = AtomicU64::new(0);
static BATCHES: AtomicU64 = AtomicU64::new(0);

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/health", post(health))
        .route("/ingest", post(ingest))
        .route("/stats", post(stats))
        .route("/stats", axum::routing::get(stats));
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8000);
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .expect("bind");
    println!("ingest sink listening on http://127.0.0.1:{port}/ingest");
    axum::serve(listener, app).await.unwrap();
}
