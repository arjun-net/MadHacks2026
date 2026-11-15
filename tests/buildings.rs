//! The building grid built from the real assets/buildings.json, checked against a plain
//! brute-force point-in-polygon search, and the full ping → stored row flow.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use madhacks_backend::buffer::WriteBuffer;
use madhacks_backend::buildings::{checksum, BuildingIndex, BuildingsConfig, GridMeta};
use madhacks_backend::routes::{router, AppState};
use madhacks_backend::models::Row;
use madhacks_backend::store::{Dataset, Store};
use serde_json::{json, Value};
use tower::ServiceExt;

fn source() -> Value {
    serde_json::from_slice(&std::fs::read(BuildingsConfig::default().source).unwrap()).unwrap()
}

/// The committed grid, loaded without rebuilding: fails if it's stale against buildings.json.
fn committed_index() -> BuildingIndex {
    let config = BuildingsConfig::default();
    let bytes = std::fs::read(&config.source).unwrap();
    BuildingIndex::load(&config, &bytes).expect("assets/building_grid.* is out of date: run `cargo run --release --bin build_building_grid`")
}

/// Independent reference: every polygon containing the point, smallest area wins, ties to the
/// earlier building (the documented overlap rule). Same flat projection as the grid.
fn brute_force(meta: &GridMeta, json: &Value, lat: f64, lng: f64) -> Option<String> {
    let project = |la: f64, ln: f64| ((ln - meta.min_lng) * meta.meters_per_deg_lng, (meta.max_lat - la) * meta.meters_per_deg_lat);
    let (px, py) = project(lat, lng);
    let mut best: Option<(f64, usize, String)> = None;
    for (i, b) in json["buildings"].as_array().unwrap().iter().enumerate() {
        let points: Vec<(f64, f64)> = b["perimeter_polygon"].as_array().unwrap().iter()
            .map(|v| project(v[0].as_f64().unwrap(), v[1].as_f64().unwrap()))
            .collect();
        let mut inside = false;
        let mut j = points.len() - 1;
        for k in 0..points.len() {
            let ((xi, yi), (xj, yj)) = (points[k], points[j]);
            if (yi > py) != (yj > py) && px < (xj - xi) * (py - yi) / (yj - yi) + xi {
                inside = !inside;
            }
            j = k;
        }
        if !inside {
            continue;
        }
        let area = meta.buildings.iter().find(|e| e.key == b["id"].as_str().unwrap()).unwrap().area_m2;
        if best.as_ref().is_none_or(|(a, idx, _)| area < *a || (area == *a && i < *idx)) {
            best = Some((area, i, b["name"].as_str().unwrap().to_string()));
        }
    }
    best.map(|(_, _, name)| name)
}

#[test]
fn committed_grid_matches_buildings_json_and_loads_every_building() {
    let index = committed_index();
    let json = source();
    let meta = index.meta();
    let buildings = json["buildings"].as_array().unwrap();
    assert_eq!(meta.source_checksum, checksum(&std::fs::read(BuildingsConfig::default().source).unwrap()));
    assert!(meta.skipped.is_empty(), "{:?}", meta.skipped);
    assert_eq!(meta.buildings.len(), buildings.len());
    // Ids follow the file order and map to the exact names.
    for (i, b) in buildings.iter().enumerate() {
        let id = (i + 1) as u16;
        assert_eq!(meta.buildings[i].key, b["id"].as_str().unwrap());
        assert_eq!(index.name_for_id(id).map(|n| n.as_ref()), b["name"].as_str());
    }
    assert_eq!(index.name_for_id(0), None);
    assert_eq!(index.name_for_id(meta.buildings.len() as u16 + 1), None);
    // ~2 m cells sized to the buildings, not a fixed square.
    assert_eq!(meta.resolution_m, 2.0);
    assert!(meta.cols > 1000 && meta.rows > 500 && meta.cols != meta.rows);
}

#[test]
fn building_centers_find_their_building() {
    let index = committed_index();
    let json = source();
    let mut checked = 0;
    for b in json["buildings"].as_array().unwrap() {
        let (lat, lng) = (b["center"][0].as_f64().unwrap(), b["center"][1].as_f64().unwrap());
        let expected = brute_force(index.meta(), &json, lat, lng);
        // Centers that aren't inside any outline are skipped (the grid answers by outline).
        if expected.is_none() {
            continue;
        }
        assert_eq!(index.building_name(lat, lng).map(|n| n.to_string()), expected, "{}", b["id"]);
        checked += 1;
    }
    assert!(checked >= 80, "only {checked} centers were inside their outlines");
    assert_eq!(index.building_name(43.07657169472751, -89.39983343128407).map(|n| n.as_ref()), Some("Memorial Union"));
}

#[test]
fn grid_agrees_with_brute_force_at_every_sampled_cell() {
    let index = committed_index();
    let json = source();
    let meta = index.meta().clone();
    let mut seed = 42u64;
    let mut next = |n: usize| {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((seed >> 33) as usize) % n
    };
    let mut on_building = 0;
    for _ in 0..20_000 {
        let (row, col) = (next(meta.rows), next(meta.cols));
        let lat = meta.max_lat - (row as f64 + 0.5) * meta.resolution_m / meta.meters_per_deg_lat;
        let lng = meta.min_lng + (col as f64 + 0.5) * meta.resolution_m / meta.meters_per_deg_lng;
        let expected = brute_force(&meta, &json, lat, lng);
        on_building += expected.is_some() as usize;
        assert_eq!(index.building_name(lat, lng).map(|n| n.to_string()), expected, "cell {row},{col}");
    }
    assert!(on_building > 500, "sample should hit buildings ({on_building})");
}

#[test]
fn outdoors_and_off_campus_are_null() {
    let index = committed_index();
    let json = source();
    // Open ground between buildings (checked against the outlines, not assumed).
    assert_eq!(brute_force(index.meta(), &json, 43.074, -89.390), None);
    assert_eq!(index.building_name(43.074, -89.390), None);
    // Lake Mendota, the Capitol, another continent.
    assert_eq!(index.building_name(43.0900, -89.4000), None);
    assert_eq!(index.building_name(43.0747, -89.3841), None);
    assert_eq!(index.building_name(48.8584, 2.2945), None);
}

// MARK: Ping → stored row

fn app() -> (axum::Router, Arc<WriteBuffer>, Arc<Store>) {
    let store = Arc::new(Store::memory());
    let buffer = WriteBuffer::new(store.clone(), 100);
    let buildings = Arc::new(committed_index());
    (router(AppState { store: store.clone(), buffer: buffer.clone(), buildings }), buffer, store)
}

async fn post(app: &axum::Router, path: &str, body: Value) -> StatusCode {
    let request = Request::post(path).header("content-type", "application/json").body(Body::from(body.to_string())).unwrap();
    app.clone().oneshot(request).await.unwrap().status()
}

async fn rows(store: &Store, dataset: Dataset) -> Vec<Row> {
    let start = "2026-11-14T00:00:00Z".parse().unwrap();
    let end = "2026-11-15T00:00:00Z".parse().unwrap();
    store.query_dataset(dataset, start, end, None, 1000).await.unwrap()
}

#[tokio::test]
async fn each_ping_is_stored_once_with_its_building_or_null() {
    let (app, buffer, store) = app();
    let inside = json!({"lat": 43.07657169472751, "lng": -89.39983343128407, "timestamp": "2026-11-14T20:40:00Z", "device_id": "ios-a"});
    let outside = json!({"lat": 43.074, "lng": -89.390, "timestamp": "2026-11-14T20:42:00Z", "device_id": "ios-b"});
    assert_eq!(post(&app, "/api/v1/locations", inside).await, StatusCode::ACCEPTED);
    assert_eq!(post(&app, "/api/v1/locations", outside).await, StatusCode::ACCEPTED);
    buffer.flush().await;

    let raw = rows(&store, Dataset::Raw).await;
    assert_eq!(raw.len(), 2, "one row per ping");
    assert_eq!(raw[0].3.as_deref(), Some("Memorial Union"));
    assert_eq!(raw[1].3, None, "unmapped is a real null, not a string");
    // Existing fields are untouched.
    assert_eq!((raw[0].1, raw[0].2), (43.07657169472751, -89.39983343128407));
    assert_eq!(raw[0].0.to_rfc3339(), "2026-11-14T20:40:00+00:00");
    assert_eq!((raw[1].1, raw[1].2), (43.074, -89.390));
}

#[tokio::test]
async fn batches_hourly_copies_accuracy_and_client_names() {
    let (app, buffer, store) = app();
    let points = json!({ "points": [
        // On the hour, so it's also copied to the hourly table, building included.
        {"lat": 43.07657169472751, "lng": -89.39983343128407, "timestamp": "2026-11-14T21:00:10Z", "device_id": "a", "accuracy": 8.0},
        // Too vague to name a building.
        {"lat": 43.07657169472751, "lng": -89.39983343128407, "timestamp": "2026-11-14T21:02:00Z", "device_id": "a", "horizontal_accuracy": 120.0},
        // Old clients send no accuracy at all.
        {"lat": 43.07657169472751, "lng": -89.39983343128407, "timestamp": "2026-11-14T21:04:00Z", "device_id": "b"},
        // The grid's answer wins over the client's.
        {"lat": 43.07657169472751, "lng": -89.39983343128407, "timestamp": "2026-11-14T21:06:00Z", "device_id": "c", "building": "College Library"},
        // The client's name is kept where the grid has none.
        {"lat": 43.074, "lng": -89.390, "timestamp": "2026-11-14T21:08:00Z", "device_id": "c", "building": "Somewhere"},
    ]});
    assert_eq!(post(&app, "/api/v1/locations/batch", points).await, StatusCode::ACCEPTED);
    buffer.flush().await;

    let raw = rows(&store, Dataset::Raw).await;
    let names: Vec<Option<&str>> = raw.iter().map(|r| r.3.as_deref()).collect();
    assert_eq!(names, [Some("Memorial Union"), None, Some("Memorial Union"), Some("Memorial Union"), Some("Somewhere")]);
    let broad = rows(&store, Dataset::Broad).await;
    assert_eq!(broad.len(), 1);
    assert_eq!(broad[0].3.as_deref(), Some("Memorial Union"));
}
