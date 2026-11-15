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
use crate::models::{Accepted, BBox, BatchIn, HeatmapOut, LatLng, LocationIn};
use crate::store::Store;

#[derive(Clone)]
pub struct AppState {
    pub store: Arc<Store>,
    pub buffer: Arc<WriteBuffer>,
}

fn unprocessable(msg: impl Into<String>) -> Response {
    (StatusCode::UNPROCESSABLE_ENTITY, Json(json!({ "detail": msg.into() }))).into_response()
}

pub fn router(state: AppState) -> Router {
    let v1 = Router::new()
        .route("/locations", post(ingest_one))
        .route("/locations/batch", post(ingest_batch))
        .route("/heatmap", get(heatmap))
        .route("/health", get(health));
    Router::new().nest("/api/v1", v1).with_state(state)
}

async fn ingest_one(State(s): State<AppState>, Json(body): Json<LocationIn>) -> Response {
    match body.validate() {
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
        match p.validate() {
            Ok(p) => points.push(p),
            Err(e) => return unprocessable(e),
        }
    }
    let n = points.len();
    s.buffer.add(points);
    (StatusCode::ACCEPTED, Json(Accepted { accepted: n })).into_response()
}

fn parse_ts(params: &HashMap<String, String>, key: &str) -> Result<DateTime<Utc>, Response> {
    let raw = params.get(key).ok_or_else(|| unprocessable(format!("{key} is required")))?;
    DateTime::parse_from_rfc3339(raw)
        .map(|d| d.with_timezone(&Utc))
        .map_err(|_| unprocessable(format!("{key} must be an ISO-8601 timestamp with a timezone (e.g. trailing 'Z')")))
}

fn iso(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339_opts(SecondsFormat::Secs, true)
}

async fn heatmap(State(s): State<AppState>, Query(params): Query<HashMap<String, String>>) -> Response {
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
            let parts: Result<Vec<f64>, _> = raw.split(',').map(|x| x.trim().parse::<f64>()).collect();
            match parts {
                Ok(v) if v.len() == 4 => Some((v[0], v[1], v[2], v[3])),
                _ => return unprocessable("bbox must be minLng,minLat,maxLng,maxLat"),
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

    let rows = match s.store.query(start, end, bbox, limit).await {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("heatmap query failed: {e}");
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "detail": "database error" }))).into_response();
        }
    };
    let count = rows.len();
    let mut data: BTreeMap<String, Vec<LatLng>> = BTreeMap::new();
    for (t, lat, lng) in rows {
        data.entry(iso(t)).or_default().push(LatLng { lat, lng });
    }
    Json(HeatmapOut { start: iso(start), end: iso(end), count, data }).into_response()
}

async fn health(State(s): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({ "status": "ok", "store_ok": s.store.ping().await }))
}
