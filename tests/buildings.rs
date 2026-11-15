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

const MORGRIDGE: &str = "Morgridge Hall (College of Computing & AI)";

fn source() -> Value {
    serde_json::from_slice(&std::fs::read(BuildingsConfig::default().source).unwrap()).unwrap()
}

/// The committed grid, loaded without rebuilding: fails if it's stale against buildings.json.
fn committed_index() -> BuildingIndex {
    let config = BuildingsConfig::default();
    let bytes = std::fs::read(&config.source).unwrap();
    BuildingIndex::load(&config, &bytes).expect("assets/building_grid.* is out of date: run `cargo run --release --bin build_building_grid`")
}

/// Independent reference for the documented rules, in the same flat projection as the grid:
/// inside outlines, the smallest area wins (ties: earlier building); outside every outline,
/// the building with the nearest edge within the buffer (ties: earlier building).
/// Returns `None` when the point is too close to a boundary or a tie to call (float noise).
fn reference(meta: &GridMeta, json: &Value, lat: f64, lng: f64) -> Option<Option<String>> {
    let project = |la: f64, ln: f64| ((ln - meta.min_lng) * meta.meters_per_deg_lng, (meta.max_lat - la) * meta.meters_per_deg_lat);
    let (px, py) = project(lat, lng);
    let mut inside_best: Option<(f64, usize, String)> = None;
    let mut near: Vec<(f64, usize, String)> = Vec::new();
    for (i, b) in json["buildings"].as_array().unwrap().iter().enumerate() {
        let points: Vec<(f64, f64)> = b["perimeter_polygon"].as_array().unwrap().iter()
            .map(|v| project(v[0].as_f64().unwrap(), v[1].as_f64().unwrap()))
            .collect();
        let name = b["name"].as_str().unwrap().to_string();
        let mut inside = false;
        let mut distance = f64::MAX;
        let mut j = points.len() - 1;
        for k in 0..points.len() {
            let ((xi, yi), (xj, yj)) = (points[k], points[j]);
            if (yi > py) != (yj > py) && px < (xj - xi) * (py - yi) / (yj - yi) + xi {
                inside = !inside;
            }
            let (dx, dy) = (xi - xj, yi - yj);
            let t = (((px - xj) * dx + (py - yj) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
            distance = distance.min((px - xj - t * dx).hypot(py - yj - t * dy));
            j = k;
        }
        if distance < 1e-6 {
            return None; // on an edge
        }
        if inside {
            let area = meta.buildings.iter().find(|e| e.key == b["id"].as_str().unwrap()).unwrap().area_m2;
            if inside_best.as_ref().is_none_or(|(a, idx, _)| area < *a || (area == *a && i < *idx)) {
                inside_best = Some((area, i, name));
            }
        } else if distance <= meta.buffer_m + 1e-6 {
            if (distance - meta.buffer_m).abs() < 1e-6 {
                return None;
            }
            near.push((distance, i, name));
        }
    }
    if let Some((_, _, name)) = inside_best {
        return Some(Some(name));
    }
    near.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.cmp(&b.1)));
    if near.len() > 1 && (near[1].0 - near[0].0).abs() < 1e-6 {
        return None;
    }
    Some(near.into_iter().next().map(|(_, _, name)| name))
}

fn brute_force(meta: &GridMeta, json: &Value, lat: f64, lng: f64) -> Option<String> {
    reference(meta, json, lat, lng).expect("point is on a boundary")
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
    // A square N × N grid of ~2 m cells sized to the buildings.
    assert!(meta.cols > 500 && meta.cols == meta.rows);
    assert_eq!(meta.buffer_m, 15.0);
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
    assert!(checked >= json["buildings"].as_array().unwrap().len() - 3, "only {checked} centers were inside their outlines");
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
    for _ in 0..40_000 {
        let (row, col) = (next(meta.rows), next(meta.cols));
        let lat = meta.max_lat - (row as f64 + 0.5) * meta.resolution_m / meta.meters_per_deg_lat;
        let lng = meta.min_lng + (col as f64 + 0.5) * meta.resolution_m / meta.meters_per_deg_lng;
        let Some(expected) = reference(&meta, &json, lat, lng) else { continue };
        on_building += expected.is_some() as usize;
        assert_eq!(index.building_name(lat, lng).map(|n| n.to_string()), expected, "cell {row},{col}");
    }
    assert!(on_building > 500, "sample should hit buildings ({on_building})");
}

/// Real pings from inside Morgridge Hall (2026-11-15) that were stored with no building, and
/// spots just outside its walls, where indoor GPS often lands.
#[test]
fn morgridge_hall_pings_and_a_little_outside_find_it() {
    let index = committed_index();
    let name = |lat: f64, lng: f64| index.building_name(lat, lng).map(|n| n.to_string());
    let hall = Some("Morgridge Hall (College of Computing & AI)".to_string());
    for (lat, lng) in [(43.073091, -89.406866), (43.073141, -89.407074), (43.073145, -89.407038), (43.072922, -89.407105)] {
        assert_eq!(name(lat, lng), hall, "{lat},{lng}");
    }
    // ~10 m north of the north wall and ~10 m east of the east wall: still the hall.
    assert_eq!(name(43.07328, -89.40690), hall);
    assert_eq!(name(43.07302, -89.40597), hall);
    // ~40 m north: not the hall.
    assert_ne!(name(43.07355, -89.40690), hall);
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
    let inside = json!({"lat": 43.073141, "lng": -89.407074, "timestamp": "2026-11-14T20:40:00Z", "device_id": "ios-a"});
    let outside = json!({"lat": 43.074, "lng": -89.390, "timestamp": "2026-11-14T20:42:00Z", "device_id": "ios-b"});
    assert_eq!(post(&app, "/api/v1/locations", inside).await, StatusCode::ACCEPTED);
    assert_eq!(post(&app, "/api/v1/locations", outside).await, StatusCode::ACCEPTED);
    buffer.flush().await;

    let raw = rows(&store, Dataset::Raw).await;
    assert_eq!(raw.len(), 2, "one row per ping");
    assert_eq!(raw[0].3.as_deref(), Some(MORGRIDGE));
    assert_eq!(raw[1].3, None, "unmapped is a real null, not a string");
    // Existing fields are untouched.
    assert_eq!((raw[0].1, raw[0].2), (43.073141, -89.407074));
    assert_eq!(raw[0].0.to_rfc3339(), "2026-11-14T20:40:00+00:00");
    assert_eq!((raw[1].1, raw[1].2), (43.074, -89.390));
}

#[tokio::test]
async fn batches_accuracy_and_client_names() {
    let (app, buffer, store) = app();
    let points = json!({ "points": [
        {"lat": 43.073141, "lng": -89.407074, "timestamp": "2026-11-14T21:00:10Z", "device_id": "a", "accuracy": 8.0},
        // Too vague to name a building.
        {"lat": 43.073141, "lng": -89.407074, "timestamp": "2026-11-14T21:02:00Z", "device_id": "a", "horizontal_accuracy": 120.0},
        // Old clients send no accuracy at all.
        {"lat": 43.073141, "lng": -89.407074, "timestamp": "2026-11-14T21:04:00Z", "device_id": "b"},
        // The grid's answer wins over the client's.
        {"lat": 43.073141, "lng": -89.407074, "timestamp": "2026-11-14T21:06:00Z", "device_id": "c", "building": "College Library"},
        // The client's name is kept where the grid has none.
        {"lat": 43.074, "lng": -89.390, "timestamp": "2026-11-14T21:08:00Z", "device_id": "c", "building": "Somewhere"},
    ]});
    assert_eq!(post(&app, "/api/v1/locations/batch", points).await, StatusCode::ACCEPTED);
    buffer.flush().await;

    let raw = rows(&store, Dataset::Raw).await;
    let names: Vec<Option<&str>> = raw.iter().map(|r| r.3.as_deref()).collect();
    assert_eq!(names, [Some(MORGRIDGE), None, Some(MORGRIDGE), Some(MORGRIDGE), Some("Somewhere")]);
}
