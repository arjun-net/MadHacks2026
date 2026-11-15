use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::Router;
use http_body_util::BodyExt;
use madhacks_backend::buffer::WriteBuffer;
use madhacks_backend::buildings::{BuildingIndex, BuildingsConfig};
use madhacks_backend::routes::{router, AppState};
use madhacks_backend::store::Store;
use serde_json::{json, Value};
use tower::ServiceExt;

// Tests always use the in-memory store and never touch the real database.
fn app() -> (Router, Arc<WriteBuffer>) {
    let store = Arc::new(Store::memory());
    let buffer = WriteBuffer::new(store.clone(), 100);
    let buildings = Arc::new(BuildingIndex::load_or_build(&BuildingsConfig::default()).unwrap());
    (router(AppState { store, buffer: buffer.clone(), buildings }), buffer)
}

async fn send(app: &Router, req: Request<Body>) -> (StatusCode, Value) {
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

fn post(path: &str, body: Value) -> Request<Body> {
    Request::post(path).header("content-type", "application/json").body(Body::from(body.to_string())).unwrap()
}

fn get(path: &str) -> Request<Body> {
    Request::get(path).body(Body::empty()).unwrap()
}

fn p() -> Value {
    json!({"lat": 43.07, "lng": -89.40, "timestamp": "2026-11-14T22:34:00Z", "device_id": "a"})
}

#[tokio::test]
async fn ingest_and_heatmap_grouped() {
    let (app, buf) = app();
    assert_eq!(send(&app, post("/api/v1/locations", p())).await.0, StatusCode::ACCEPTED);
    let mut b = p();
    b["lat"] = json!(43.08);
    let mut c = p();
    c["timestamp"] = json!("2026-11-14T22:36:00Z");
    let (st, body) = send(&app, post("/api/v1/locations/batch", json!({"points": [b, c]}))).await;
    assert_eq!((st, body), (StatusCode::ACCEPTED, json!({"accepted": 2})));
    buf.flush().await;

    let (st, body) = send(&app, get("/api/v1/heatmap?start=2026-11-14T22:00:00Z&end=2026-11-14T23:00:00Z")).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(body["count"], 3);
    let keys: Vec<&String> = body["data"].as_object().unwrap().keys().collect();
    assert_eq!(keys, ["2026-11-14T22:34:00Z", "2026-11-14T22:36:00Z"]);
    assert_eq!(body["data"]["2026-11-14T22:34:00Z"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn range_and_bbox() {
    let (app, buf) = app();
    send(&app, post("/api/v1/locations", p())).await;
    buf.flush().await;
    let q = |bbox: &str| format!("/api/v1/heatmap?start=2026-11-14T22:34:00Z&end=2026-11-14T22:36:00Z&bbox={bbox}");
    assert_eq!(send(&app, get(&q("-90,43,-89,44"))).await.1["count"], 1);
    assert_eq!(send(&app, get(&q("0,0,1,1"))).await.1["count"], 0);
    // end is exclusive
    let (_, body) = send(&app, get("/api/v1/heatmap?start=2026-11-14T22:30:00Z&end=2026-11-14T22:34:00Z")).await;
    assert_eq!(body["count"], 0);
}

#[tokio::test]
async fn validation() {
    let (app, _) = app();
    let mut bad = vec![];
    for (k, v) in [("lat", json!(91)), ("lng", json!(-181)), ("timestamp", json!("2026-11-14T22:34:00"))] {
        let mut x = p();
        x[k] = v;
        bad.push(x);
    }
    bad.push(json!({"lat": 1}));
    for b in bad {
        assert_eq!(send(&app, post("/api/v1/locations", b.clone())).await.0, StatusCode::UNPROCESSABLE_ENTITY, "{b}");
    }
}

#[tokio::test]
async fn batch_limit_and_heatmap_args() {
    let (app, _) = app();
    let too_many = json!({"points": vec![p(); 501]});
    assert_eq!(send(&app, post("/api/v1/locations/batch", too_many)).await.0, StatusCode::UNPROCESSABLE_ENTITY);
    for q in [
        "start=2026-11-14T23:00:00Z&end=2026-11-14T22:00:00Z",
        "start=2026-11-14T22:00:00Z",
        "start=2026-11-14T22:00:00Z&end=2026-11-14T23:00:00Z&bbox=1,2,3",
        "start=2026-11-14T22:00:00Z&end=2026-11-14T23:00:00Z&limit=0",
    ] {
        assert_eq!(send(&app, get(&format!("/api/v1/heatmap?{q}"))).await.0, StatusCode::UNPROCESSABLE_ENTITY, "{q}");
    }
}

#[tokio::test]
async fn health() {
    let (app, _) = app();
    assert_eq!(send(&app, get("/api/v1/health")).await.1, json!({"status": "ok", "store_ok": true}));
}
