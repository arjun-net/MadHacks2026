use std::sync::Arc;
use std::time::Duration;

use madhacks_backend::buffer::WriteBuffer;
use madhacks_backend::config::Settings;
use madhacks_backend::routes::{router, AppState};
use madhacks_backend::store::Store;
use tower_http::cors::CorsLayer;

#[tokio::main]
async fn main() {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into())).init();
    let s = Settings::from_env();

    let store = Arc::new(match s.store_backend.as_str() {
        "postgres" => Store::postgres(&s),
        _ => Store::memory(),
    });
    let buffer = WriteBuffer::new(store.clone(), s.flush_batch_size);
    buffer.start(Duration::from_secs(s.flush_interval_s));

    let app = router(AppState { store, buffer: buffer.clone() }).layer(CorsLayer::permissive());
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", s.port)).await.expect("bind failed");
    tracing::info!("listening on :{} (store={})", s.port, s.store_backend);
    axum::serve(listener, app)
        .with_graceful_shutdown(async { tokio::signal::ctrl_c().await.ok(); })
        .await
        .unwrap();
    buffer.flush().await; // don't lose buffered points on shutdown
}
