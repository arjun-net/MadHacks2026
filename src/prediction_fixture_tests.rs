use super::*;
use axum::extract::{Path, Query, State};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::TimeZone;
use std::sync::{Arc, Mutex};

fn now() -> DateTime<Utc> { Utc.with_ymd_and_hms(2026, 11, 15, 9, 0, 0).unwrap() }

fn constructed() -> Selection {
    select_history(
        &PredictionQuery {
            date: Some("2026-11-21".into()),
            time: Some("14:30".into()),
            weeks: Some(8),
            ..Default::default()
        },
        chrono_tz::America::Chicago,
        now(),
    ).unwrap()
}

fn fake_rows(selection: &Selection, fixture: &str) -> Vec<Vec<Value>> {
    let spike = [
        (Some(42), "available", true),
        (Some(14), "available", false),
        (Some(16), "available", false),
        (Some(14), "available", false),
        (Some(12), "available", false),
        (None, "suppressed", false),
        (None, "no_data", false),
        (None, "no_data", false),
    ];
    let steady = [
        (Some(14), "available", false),
        (Some(15), "available", false),
        (Some(13), "available", false),
        (Some(14), "available", false),
        (Some(15), "available", false),
        (Some(14), "available", false),
        (Some(13), "available", false),
        (Some(14), "available", false),
    ];
    let sparse = [
        (Some(14), "available", false),
        (Some(16), "available", false),
        (None, "suppressed", false),
        (None, "no_data", false),
        (None, "no_data", false),
        (None, "no_data", false),
        (None, "no_data", false),
        (None, "no_data", false),
    ];
    selection.historical.iter().enumerate().map(|(i, sample)| {
        let (count, status, outlier, expected, p25, p75, stddev, used, excluded) =
            match fixture {
                "spike" => {
                    let (n, status, outlier) = spike[i];
                    (n, status, outlier, Some(14.0), Some(12.0), Some(14.0), Some(1.633), 4, 1)
                }
                "steady" => {
                    let (n, status, outlier) = steady[i];
                    (n, status, outlier, Some(14.0), Some(13.0), Some(15.0), Some(0.7559), 8, 0)
                }
                "sparse" => {
                    let (n, status, outlier) = sparse[i];
                    (n, status, outlier, Some(15.0), Some(14.0), Some(16.0), Some(1.4142), 2, 0)
                }
                _ => panic!("unknown fixture"),
            };
        vec![
            json!(sample.day.to_string()),
            count.map(|v| json!(v.to_string())).unwrap_or(Value::Null),
            json!(status),
            json!(if outlier { "1" } else { "0" }),
            expected.map(|v| json!(v.to_string())).unwrap_or(Value::Null),
            p25.map(|v| json!(v.to_string())).unwrap_or(Value::Null),
            p75.map(|v| json!(v.to_string())).unwrap_or(Value::Null),
            stddev.map(|v| json!(v.to_string())).unwrap_or(Value::Null),
            json!(used.to_string()),
            json!(excluded.to_string()),
        ]
    }).collect()
}

fn assert_mobile_prediction_summary(message: &str) {
    assert!(message.chars().count() <= 96, "too long: {message}");
    assert_eq!(message.chars().filter(|&ch| ch == '.').count(), 1, "not one sentence: {message}");
    assert!(message.ends_with('.'));
}

#[test]
fn historical_prediction_selects_completed_saturdays_with_constructed_date() {
    let s = constructed();
    assert_eq!(s.day.to_string(), "2026-11-21");
    assert_eq!(s.historical.len(), 8);
    assert_eq!(s.historical[0].day.to_string(), "2026-11-14");
    assert_eq!(s.historical[7].day.to_string(), "2026-09-26");
    // Oct 31 was daylight time; Nov 7 was standard time.
    let oct31 = s.historical.iter().find(|r| r.day.to_string() == "2026-10-31").unwrap();
    let nov7 = s.historical.iter().find(|r| r.day.to_string() == "2026-11-07").unwrap();
    assert_eq!(nov7.target_epoch - oct31.target_epoch, 169 * 3600);
}

#[test]
fn historical_prediction_never_uses_unobserved_future_weeks() {
    let s = select_history(
        &PredictionQuery {
            date: Some("2026-12-05".into()),
            time: Some("14:30".into()),
            weeks: Some(8),
            ..Default::default()
        },
        chrono_tz::America::Chicago, now()
    ).unwrap();
    assert_eq!(s.historical[0].day.to_string(), "2026-11-14");
    assert!(!s.historical.iter().any(|d| d.day.to_string() == "2026-11-28"));
}

#[test]
fn historical_prediction_builds_parameterized_databricks_sql() {
    let name = "Morgridge Hall (College of Computing & AI)'; DROP TABLE x; --";
    let (sql, parameters) = prediction_sql("campus_lakebase", &constructed(), name, 5);
    assert!(!sql.contains(name));
    assert!(sql.contains("`campus_lakebase`.`public`.`location_events`"));
    assert!(sql.contains("percentile_approx"));
    assert!(sql.contains("ROW_NUMBER()"));
    assert!(sql.contains("is_outlier = 0"));
    // SqlParameter fields are intentionally private. Inspect its serialized
    // Statement Execution API representation instead of bypassing privacy.
    let params = serde_json::to_value(&parameters).unwrap();
    let params = params.as_array().unwrap();
    assert!(params.iter().any(|p| p["name"] == "building" && p["value"] == name));
    assert!(params.iter().any(|p| p["value"] == "2026-11-14"));
}

#[test]
fn historical_prediction_excludes_spike_and_reports_typical_activity() {
    let s = constructed();
    let prediction = build_response(
        "__DEMO__ Forecast Hall".into(),
        &s,
        parse_prediction(&fake_rows(&s, "spike")).unwrap(),
    );
    assert_eq!(prediction.target_date, "2026-11-21");
    assert_eq!(prediction.prediction.expected_reporting_devices, Some(14.0));
    assert_eq!(prediction.prediction.rounded_reporting_devices, Some(14));
    assert_eq!(prediction.samples_used, 4);
    assert_eq!(prediction.outliers_excluded, 1);
    assert!(prediction.historical_samples[0].excluded_as_outlier);
    assert!(!prediction.historical_samples[0].used_for_prediction);
    assert_eq!(prediction.prediction.reliability, "moderate");
    assert_eq!(prediction.summary, "__DEMO__ Forecast Hall typically has ~14 reporting devices.");
    assert_mobile_prediction_summary(&prediction.summary);
}

#[test]
fn historical_prediction_uses_short_official_building_name() {
    let selection = constructed();
    let forecast = build_response(
        "Morgridge Hall (College of Computing & AI)".to_owned(),
        &selection,
        parse_prediction(&fake_rows(&selection, "spike")).unwrap(),
    );
    assert_eq!(forecast.building, "Morgridge Hall (College of Computing & AI)");
    assert_eq!(forecast.summary, "Morgridge Hall typically has ~14 reporting devices.");
    assert_mobile_prediction_summary(&forecast.summary);
}

#[test]
fn historical_prediction_stable_regular_data_is_high_reliability() {
    let s = constructed();
    let prediction = build_response("__DEMO__ Forecast Hall".into(), &s, parse_prediction(&fake_rows(&s, "steady")).unwrap());
    assert_eq!(prediction.samples_used, 8);
    assert_eq!(prediction.outliers_excluded, 0);
    assert_eq!(prediction.prediction.reliability, "high");
    assert_eq!(prediction.prediction.status, "available");
    assert_mobile_prediction_summary(&prediction.summary);
}

#[test]
fn historical_prediction_sparse_data_does_not_invent_a_forecast() {
    let s = constructed();
    let prediction = build_response("__DEMO__ Forecast Hall".into(), &s, parse_prediction(&fake_rows(&s, "sparse")).unwrap());
    assert_eq!(prediction.prediction.status, "insufficient_history");
    assert_eq!(prediction.prediction.expected_reporting_devices, None);
    assert_eq!(prediction.prediction.typical_p25, None);
    assert_eq!(prediction.samples_used, 2);
    assert_mobile_prediction_summary(&prediction.summary);
}

struct MockWarehouse {
    fixture: &'static str,
    requests: Mutex<Vec<Value>>,
}

async fn mock_statement(State(s): State<Arc<MockWarehouse>>, Json(request): Json<Value>) -> Json<Value> {
    assert_eq!(request["warehouse_id"], "synthetic-warehouse");
    assert!(request["statement"].as_str().unwrap().contains("percentile_approx"));
    assert!(request["parameters"].as_array().unwrap().iter()
        .any(|p| p["name"] == "building" && p["value"] == "__DEMO__ Forecast Hall"));
    s.requests.lock().unwrap().push(request);
    Json(json!({
        "statement_id": "fake-forecast-001",
        "status": {"state": "SUCCEEDED"},
        "result": {"data_array": fake_rows(&constructed(), s.fixture)}
    }))
}

async fn call_mock_prediction(fixture: &'static str) -> (StatusCode, Value, Arc<MockWarehouse>) {
    let warehouse = Arc::new(MockWarehouse { fixture, requests: Mutex::new(vec![]) });
    let app = Router::new()
        .route("/api/2.0/sql/statements", post(mock_statement))
        .with_state(Arc::clone(&warehouse));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });

    let client = Arc::new(DbClient::new(Config {
        host: format!("http://{address}"),
        token: "synthetic-token".into(),
        warehouse_id: "synthetic-warehouse".into(),
        catalog: "campus_lakebase".into(),
        ai_endpoint: None,
        timezone: chrono_tz::America::Chicago,
        min_devices: 5,
    }).unwrap());
    let api = Router::new().route(
        "/api/v1/buildings/{building}/prediction",
        get(move |Path(building): Path<String>, Query(query): Query<PredictionQuery>| {
            let client = Arc::clone(&client);
            async move { prediction_with_client(building, query, now(), &client).await }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let api_address = listener.local_addr().unwrap();
    let api_server = tokio::spawn(async move { axum::serve(listener, api).await.unwrap(); });
    let response = reqwest::Client::new().get(format!(
        "http://{api_address}/api/v1/buildings/__DEMO__%20Forecast%20Hall/prediction?date=2026-11-21&time=14:30&weeks=8"
    )).send().await.unwrap();
    let status = response.status();
    let json: Value = response.json().await.unwrap();
    api_server.abort();
    server.abort();
    (status, json, warehouse)
}

#[tokio::test]
async fn historical_prediction_http_endpoint_uses_databricks_sql_mock() {
    let (status, body, warehouse) = call_mock_prediction("spike").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["target_date"], "2026-11-21");
    assert_eq!(body["prediction"]["rounded_reporting_devices"], 14);
    assert_eq!(body["outliers_excluded"], 1);
    assert_mobile_prediction_summary(body["summary"].as_str().unwrap());
    assert_eq!(body["source"], "databricks_sql");
    assert_eq!(warehouse.requests.lock().unwrap().len(), 1);
    println!("\n=== HISTORICAL FORECAST, CONSTRUCTED NOV 21 ===\n{}", serde_json::to_string_pretty(&body).unwrap());
}

#[tokio::test]
async fn historical_prediction_http_endpoint_handles_no_baseline() {
    let (status, body, warehouse) = call_mock_prediction("sparse").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["prediction"]["status"], "insufficient_history");
    assert!(body["prediction"]["rounded_reporting_devices"].is_null());
    assert_mobile_prediction_summary(body["summary"].as_str().unwrap());
    assert_eq!(warehouse.requests.lock().unwrap().len(), 1);
}
