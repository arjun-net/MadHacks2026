use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use madhacks_backend::buffer::WriteBuffer;
use madhacks_backend::routes::{router, AppState};
use madhacks_backend::store::Store;
use serde_json::{json, Value};
use tower::ServiceExt;

#[tokio::test]
async fn existing_ingest_appends_all_zero_minute_locations() {
    let store = Arc::new(Store::memory());
    let buffer = WriteBuffer::new(store.clone(), 100);
    let app = router(AppState { store, buffer: buffer.clone() });

    let body = json!({ "points": [
        { "device_id": "a", "lat": 43.0, "lng": -89.0, "timestamp": "2026-11-14T07:00:10Z" },
        { "device_id": "a", "lat": 43.1, "lng": -89.1, "timestamp": "2026-11-14T07:00:15Z" },
        { "device_id": "a", "lat": 43.2, "lng": -89.2, "timestamp": "2026-11-14T07:05:00Z" },
        { "device_id": "b", "lat": 43.3, "lng": -89.3, "timestamp": "2026-11-14T07:00:55Z" }
    ] });

    let req = Request::builder()
        .method("POST")
        .uri("/api/v1/locations/batch")
        .header("content-type", "application/json")
        .body(Body::from(body.to_string())).unwrap();
    let response = app.clone().oneshot(req).await.unwrap();
    assert_eq!(response.status(), StatusCode::ACCEPTED);

    // Flush manually so the asynchronous buffer does not affect test determinism.
    buffer.flush().await;

    for (path, expected_count) in [
        ("/api/v1/heatmap", 4),
        ("/api/v1/heatmap/broad", 3),
    ] {
        let uri = format!("{path}?start=2026-11-14T07:00:00Z&end=2026-11-14T08:00:00Z");
        let req = Request::builder().uri(uri).body(Body::empty()).unwrap();
        let response = app.clone().oneshot(req).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = to_bytes(response.into_body(), 1_000_000).await.unwrap();
        let json: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(json["count"], expected_count);
    }
}
