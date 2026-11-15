use std::sync::Arc;
use std::time::Duration;

use madhacks_backend::buffer::WriteBuffer;
use madhacks_backend::buildings::{BuildingIndex, BuildingsConfig};
use madhacks_backend::config::Settings;
use madhacks_backend::routes::{router, AppState};
use madhacks_backend::store::Store;
use tower_http::cors::CorsLayer;

#[tokio::main]
async fn main() {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into())).init();
    let s = Settings::from_env();

    // Building lookup grid: load it (or rebuild it if buildings.json changed) before taking pings.
    let started = std::time::Instant::now();
    let buildings = match BuildingIndex::load_or_build(&BuildingsConfig::from_env()) {
        Ok(index) => Arc::new(index),
        Err(e) => {
            tracing::error!("can't start: {e}");
            std::process::exit(1);
        }
    };
    let meta = buildings.meta();
    tracing::info!(
        "building grid ready: {} buildings, {}×{} cells at {} m, {:.1} MB, {:?}",
        meta.buildings.len(), meta.cols, meta.rows, meta.resolution_m,
        buildings.memory_bytes() as f64 / 1_048_576.0, started.elapsed()
    );

    let store = Arc::new(match s.store_backend.as_str() {
        "postgres" => Store::postgres(&s),
        _ => Store::memory(),
    });
    let buffer = WriteBuffer::new(store.clone(), s.flush_batch_size);
    buffer.start(Duration::from_secs(s.flush_interval_s));

    let app = router(AppState { store, buffer: buffer.clone(), buildings }).layer(CorsLayer::permissive());
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", s.port)).await.expect("bind failed");
    tracing::info!("listening on :{} (store={})", s.port, s.store_backend);
    axum::serve(listener, app)
        .with_graceful_shutdown(async { tokio::signal::ctrl_c().await.ok(); })
        .await
        .unwrap();
    buffer.flush().await; // don't lose buffered points on shutdown
}
