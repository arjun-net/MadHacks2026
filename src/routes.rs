use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::json;

use crate::buffer::WriteBuffer;
use crate::buildings::BuildingIndex;
use crate::models::{Accepted, BBox, BatchIn, HeatmapOut, LatLng, LocationIn};
use crate::store::{Dataset, Store};

#[derive(Clone)]
pub struct AppState {
    pub store: Arc<Store>,
    pub buffer: Arc<WriteBuffer>,
    pub buildings: Arc<BuildingIndex>,
}

fn unprocessable(msg: impl Into<String>) -> Response {
    (StatusCode::UNPROCESSABLE_ENTITY, Json(json!({ "detail": msg.into() })))
        .into_response()
}

pub fn router(state: AppState) -> Router {
    let v1 = Router::new()
        .route("/locations", post(ingest_one))
        .route("/locations/batch", post(ingest_batch))
        .route("/heatmap", get(heatmap))
        .route("/heatmap/broad", get(heatmap_broad))
        .route("/buildings/counts", get(building_counts))
        .route("/health", get(health))
        .route("/buildings/{building}/story", get(crate::story::story_handler))
        .route("/buildings/{building}/prediction", get(crate::prediction::prediction_handler));
    Router::new().nest("/api/v1", v1).with_state(state)
}

async fn ingest_one(State(s): State<AppState>, Json(body): Json<LocationIn>) -> Response {
    match body.validate(&s.buildings) {
        Ok(p) => {
            s.buffer.add(vec![p]);
            (StatusCode::ACCEPTED, Json(Accepted { accepted: 1 })).into_response()
        }
        Err(e) => unprocessable(e),
    }
}

async fn ingest_batch(State(s): State<AppState>, Json(body): Json<BatchIn>) -> Response {
    if body.points.is_empty() || body.points.len() > 500 {
        return unprocessable("points must contain between 1 and 500 items");
    }
    let mut points = Vec::with_capacity(body.points.len());
    for p in body.points {
        match p.validate(&s.buildings) {
            Ok(p) => points.push(p),
            Err(e) => return unprocessable(e),
        }
    }
    let n = points.len();
    s.buffer.add(points);
    (StatusCode::ACCEPTED, Json(Accepted { accepted: n })).into_response()
}

fn parse_ts(params: &HashMap<String, String>, key: &str) -> Result<DateTime<Utc>, Response> {
    let raw = params.get(key)
        .ok_or_else(|| unprocessable(format!("{key} is required")))?;
    DateTime::parse_from_rfc3339(raw)
        .map(|d| d.with_timezone(&Utc))
        .map_err(|_| unprocessable(format!(
            "{key} must be an ISO-8601 timestamp with a timezone (e.g. trailing 'Z')"
        )))
}

fn iso(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339_opts(SecondsFormat::Secs, true)
}

async fn heatmap(
    State(s): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    heatmap_for(s, params, Dataset::Raw).await
}

async fn heatmap_broad(
    State(s): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    heatmap_for(s, params, Dataset::Broad).await
}

async fn heatmap_for(
    s: AppState,
    params: HashMap<String, String>,
    dataset: Dataset,
) -> Response {
    let (start, end) = match (parse_ts(&params, "start"), parse_ts(&params, "end")) {
        (Ok(a), Ok(b)) => (a, b),
        (Err(e), _) | (_, Err(e)) => return e,
    };
    if end <= start {
        return unprocessable("end must be after start");
    }
    let bbox: Option<BBox> = match params.get("bbox") {
        None => None,
        Some(raw) => {
            let parts: Result<Vec<f64>, _> = raw.split(',')
                .map(|x| x.trim().parse::<f64>())
                .collect();
            match parts {
                Ok(v) if v.len() == 4
                    && v.iter().all(|x| x.is_finite())
                    && (-180.0..=180.0).contains(&v[0])
                    && (-90.0..=90.0).contains(&v[1])
                    && (-180.0..=180.0).contains(&v[2])
                    && (-90.0..=90.0).contains(&v[3])
                    && v[0] <= v[2] && v[1] <= v[3] =>
                {
                    Some((v[0], v[1], v[2], v[3]))
                }
                _ => return unprocessable("bbox must be minLng,minLat,maxLng,maxLat with valid bounds"),
            }
        }
    };
    let limit: i64 = match params.get("limit") {
        None => 50_000,
        Some(raw) => match raw.parse::<i64>() {
            Ok(n) if (1..=200_000).contains(&n) => n,
            _ => return unprocessable("limit must be between 1 and 200000"),
        },
    };

    let rows = match s.store.query_dataset(dataset, start, end, bbox, limit).await {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("heatmap {:?} query failed: {e}", dataset);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "detail": "database error" })),
            ).into_response();
        }
    };
    let count = rows.len();
    let mut data: BTreeMap<String, Vec<LatLng>> = BTreeMap::new();
    for (t, lat, lng, building) in rows {
        data.entry(iso(t)).or_default().push(LatLng { lat, lng, building });
    }
    Json(HeatmapOut { start: iso(start), end: iso(end), count, data }).into_response()
}

/// People per building. Every device reports on the even minute, so each point in the
/// last 2 minutes is one person.
async fn building_counts(State(s): State<AppState>) -> Response {
    let window = 2;
    let since = Utc::now() - chrono::Duration::minutes(window);
    let rows = match s.store.building_counts(since).await {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("building counts query failed: {e}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "detail": "database error" })),
            ).into_response();
        }
    };
    let mut counts: BTreeMap<&str, i64> = s.buildings.meta().buildings.iter().map(|b| (b.key.as_str(), 0)).collect();
    for (name, n) in &rows {
        if let Some(slot) = counts.get_mut(name.as_str()) {
            *slot = *n;
        }
    }
    let total: i64 = counts.values().sum();
    Json(json!({ "window_minutes": window, "total": total, "counts": counts })).into_response()
}

async fn health(State(s): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({ "status": "ok", "store_ok": s.store.ping().await }))
}
