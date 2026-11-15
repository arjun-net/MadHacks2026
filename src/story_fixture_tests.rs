//! Run `cargo test simulated_story -- --nocapture` to view example response JSON.
//! All data is synthetic. This exercises the Databricks JSON result parser and
//! Rust story fallback, not a live Databricks SQL warehouse or AI endpoint.

use super::*;

/// 2026-11-14, Saturday 14:35 in America/Chicago.
fn demo_now() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339("2026-11-14T20:35:00Z")
        .unwrap()
        .with_timezone(&Utc)
}

fn demo_selection() -> Selection {
    select_dates(
        &StoryQuery {
            date: Some("2026-11-14".into()),
            time: Some("14:30".into()),
            weeks: Some(8),
            window_minutes: Some(15),
            ..Default::default()
        },
        chrono_tz::America::Chicago,
        demo_now(),
    )
    .expect("valid synthetic comparison period")
}

/// Simulates a successful Databricks SQL Statement Execution API response.
///
/// Earlier Saturdays: 12, 16, 14, 14 devices -> average 14.0.
/// Monday-Friday of this week: `week_device_count` per day.
/// Selected Saturday: `saturday_device_count` devices.
///
/// Eight previous Saturdays are requested, but only four have data; the
/// unobserved Saturdays must remain `no_data` (not counted as zero).
fn fake_databricks_response(
    selection: &Selection,
    saturday_device_count: i64,
    week_device_count: i64,
) -> Value {
    let mut counts = BTreeMap::<NaiveDate, i64>::new();
    for (date, count) in [
        ("2026-11-07", 12),
        ("2026-10-31", 16),
        ("2026-10-24", 14),
        ("2026-10-17", 14),
    ] {
        counts.insert(NaiveDate::parse_from_str(date, "%Y-%m-%d").unwrap(), count);
    }
    for date in [
        "2026-11-09",
        "2026-11-10",
        "2026-11-11",
        "2026-11-12",
        "2026-11-13",
    ] {
        counts.insert(
            NaiveDate::parse_from_str(date, "%Y-%m-%d").unwrap(),
            week_device_count,
        );
    }
    counts.insert(selection.day, saturday_device_count);

    // Match the 10 columns returned by activity_sql() exactly.
    let rows: Vec<Value> = selection
        .samples
        .iter()
        .map(|sample| {
            let devices = counts.get(&sample.day).copied();
            let status = if devices.is_some() { "available" } else { "no_data" };
            let as_flag = |b: bool| if b { "1" } else { "0" };
            json!([
                sample.day.to_string(),
                devices.map(|n| Value::String(n.to_string())).unwrap_or(Value::Null),
                status,
                as_flag(sample.is_week),
                as_flag(sample.is_history),
                as_flag(sample.is_target),
                "14.0", // historical mean over four measured Saturdays
                "4",    // historical sample count
                week_device_count.to_string(), // mean over five other measured weekdays
                "5",    // this-week sample count
            ])
        })
        .collect();

    json!({
        "statement_id": "synthetic-not-real",
        "status": {"state": "SUCCEEDED"},
        "result": {"data_array": rows}
    })
}

fn demo_story(saturday_devices: i64, other_weekday_devices: i64) -> BuildingStory {
    let selection = demo_selection();
    let payload = fake_databricks_response(
        &selection,
        saturday_devices,
        other_weekday_devices,
    );
    let rows = read_rows(&payload).expect("valid synthetic Databricks result");
    let aggregates = parse_activity_rows(&rows).expect("valid synthetic aggregate rows");
    construct_story("Simulation Hall".into(), &selection, demo_now(), aggregates)
}


fn assert_mobile_sentence(message: &str) {
    assert!(message.chars().count() <= MAX_STORY_CHARS, "too long: {message}");
    assert_eq!(message.chars().filter(|&ch| ch == '.').count(), 1, "not one sentence: {message}");
    assert!(message.ends_with('.'));
}

#[test]
fn simulated_story_all_fallbacks_fit_mobile_cards() {
    for response in [demo_story(42, 20), demo_story(14, 14), demo_story(6, 20)] {
        assert_mobile_sentence(&response.story);
    }
    let mut no_data = demo_story(42, 20);
    no_data.current.observations = None;
    no_data.current.reporting_devices = None;
    no_data.story = fallback_story(&no_data.building, &no_data.current,
        NaiveTime::from_hms_opt(14, 30, 0).unwrap(),
        no_data.weekday_average, no_data.weekday_samples,
        no_data.other_days_this_week_average, no_data.other_days_this_week_samples);
    assert_mobile_sentence(&no_data.story);
}

#[test]
fn simulated_story_shortens_official_building_name() {
    let story = demo_story(42, 20);
    let message = fallback_story(
        "Morgridge Hall (College of Computing & AI)", &story.current,
        NaiveTime::from_hms_opt(14, 30, 0).unwrap(),
        story.weekday_average, story.weekday_samples,
        story.other_days_this_week_average, story.other_days_this_week_samples,
    );
    assert_eq!(message, "Morgridge Hall is 200% busier than usual.");
    assert_mobile_sentence(&message);
}

#[test]
fn simulated_story_rejects_long_and_multisentence_ai_text() {
    let s = demo_story(42, 20);
    assert!(accept_ai_annotation("Simulation Hall is 200% busier than usual. This is extra.", &s).is_none());
    assert!(accept_ai_annotation(&format!("Simulation Hall is 200% busier than usual {}.", "very ".repeat(40)), &s).is_none());
    assert!(accept_ai_annotation("Simulation Hall has 900 students because of a game.", &s).is_none());
    assert!(accept_ai_annotation("Simulation Hall is 200% less busy than usual.", &s).is_none());
    assert!(accept_ai_annotation("Simulation Hall is 110% busier than usual.", &s).is_none());
    assert_eq!(accept_ai_annotation("Simulation Hall is 200% busier than usual.", &s).as_deref(),
        Some("Simulation Hall is 200% busier than usual."));
}

#[test]
fn simulated_story_accepts_equivalent_ai_paraphrases_but_not_unverified_claims() {
    let s = demo_story(42, 20);
    for input in [
        "Simulation Hall is 200% busier than normal.",
        "\"Simulation Hall is 200% higher than average.\"",
        "Simulation Hall is 200% more active than usual.",
    ] {
        let output = validate_ai_annotation(input, &s).expect(input);
        assert_mobile_sentence(&output);
        assert!(output.contains("200%"));
    }
    for invalid in [
        "Simulation Hall has 200% more active devices than usual.",
        "Simulation Hall is 200% busier because of a lecture.",
        "Simulation Hall is 200% less busy than usual.",
        "Simulation Hall is 200% busier than yesterday.",
        "Simulation Hall is 200% busier than usual with 42 students.",
        "Simulation Hall is 20% busier than usual.",
    ] {
        assert!(validate_ai_annotation(invalid, &s).is_err(), "accepted: {invalid}");
    }
}

#[test]
fn simulated_story_accepts_demo_alias_and_restores_canonical_name() {
    let mut s = demo_story(42, 20);
    s.building = "__DEMO__ Story Lab".into();
    assert_eq!(
        accept_ai_annotation("Story Lab is 200% busier than usual.", &s).as_deref(),
        Some("__DEMO__ Story Lab is 200% busier than usual.")
    );
}

#[test]
fn simulated_story_detects_saturday_spike_and_returns_fallback_text() {
    let story = demo_story(42, 20);

    assert_eq!(story.date, "2026-11-14");
    assert_eq!(story.weekday, "Saturday");
    assert_eq!(story.time_local, "14:30");
    assert_eq!(story.current.observations, Some(42));
    assert_eq!(story.metric, "location_observations");
    assert_eq!(story.historical_same_weekday.len(), 8);
    assert_eq!(story.weekday_samples, 4); // 4 observed, not 8 requested
    assert_eq!(story.weekday_average, Some(14.0));
    assert_eq!(story.difference_vs_weekday_average_pct, Some(200.0));
    assert_eq!(story.other_days_this_week_samples, 5);
    assert_eq!(story.other_days_this_week_average, Some(20.0));
    assert!((story.difference_vs_other_days_pct.unwrap() - 110.0).abs() < 1e-9);
    assert_eq!(story.this_week.len(), 7);
    assert_eq!(story.this_week[6].status, "future"); // Sunday has not happened
    assert_eq!(story.story, "Simulation Hall is 200% busier than usual.");
    assert!(story.story.contains("200% busier"));
    assert!(!story.story.contains("110%")); // secondary comparison remains in structured fields
    assert!(story.story.starts_with("Simulation Hall"));
    assert_eq!(story.story_source, "databricks_sql"); // AI is intentionally not called

    println!("\n=== SYNTHETIC SPIKE (NO DATABRICKS OR AI CALL) ===\n{}",
        serde_json::to_string_pretty(&story).unwrap());
}

#[test]
fn simulated_story_normal_saturday_does_not_claim_an_anomaly() {
    let story = demo_story(14, 14);
    assert_eq!(story.current.observations, Some(14));
    assert_eq!(story.weekday_average, Some(14.0));
    assert_eq!(story.difference_vs_weekday_average_pct, Some(0.0));
    assert_eq!(story.difference_vs_other_days_pct, Some(0.0));
    assert!(!story.story.contains("busier"));
    assert!(!story.story.contains("less busy"));
    assert_eq!(story.story, "Simulation Hall is about as busy as usual.");

    println!("\n=== SYNTHETIC NORMAL DAY (NO DATABRICKS OR AI CALL) ===\n{}",
        serde_json::to_string_pretty(&story).unwrap());
}

#[test]
fn simulated_story_identifies_large_drop_without_claiming_significance() {
    let story = demo_story(6, 20);
    assert!(story.difference_vs_weekday_average_pct.unwrap() < -50.0);
    assert_eq!(story.story, "Simulation Hall is 57% less busy than usual.");
    assert!(!story.story.contains("statistically significant"));
}

// Exercise the same handler core as GET /api/v1/buildings/{building}/story, but
// against an ephemeral fake Databricks Statement Execution API. These tests
// use a constructed clock/date, never real Lakebase data, secrets, or model calls.
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};

#[derive(Clone, Copy)]
enum MockAi {
    Valid,
    Paraphrase,
    Failed,
    Ungrounded,
    Empty,
}

struct FakeWarehouse {
    ai_calls: AtomicUsize,
    sql_calls: AtomicUsize,
    prompts: Mutex<Vec<String>>,
    ai: MockAi,
}

async fn fake_statement(
    State(state): State<Arc<FakeWarehouse>>,
    Json(request): Json<Value>,
) -> (StatusCode, Json<Value>) {
    assert_eq!(request["warehouse_id"], "synthetic-warehouse");
    let statement = request["statement"].as_str().expect("statement text");
    if statement.contains("ai_query(") {
        state.ai_calls.fetch_add(1, Ordering::SeqCst);
        assert!(statement.contains("ai_query('synthetic-model', :prompt)"));
        let prompt = request["parameters"]
            .as_array().unwrap().iter()
            .find(|p| p["name"] == "prompt")
            .unwrap()["value"]
            .as_str().unwrap().to_owned();
        state.prompts.lock().unwrap().push(prompt);
        let reply = match state.ai {
            MockAi::Valid => json!({
                "statement_id": "fake-ai",
                "status": {"state": "SUCCEEDED"},
                "result": {"data_array": [["Simulation Hall is 200% busier than usual."]]}
            }),
            MockAi::Paraphrase => json!({
                "statement_id": "fake-ai-paraphrase",
                "status": {"state": "SUCCEEDED"},
                "result": {"data_array": [["Simulation Hall is 200% higher than normal."]]}
            }),
            MockAi::Failed => json!({
                "statement_id": "fake-ai",
                "status": {"state": "FAILED", "error": {"message": "Synthetic model unavailable"}}
            }),
            MockAi::Ungrounded => json!({
                "statement_id": "fake-ai",
                "status": {"state": "SUCCEEDED"},
                "result": {"data_array": [["A sports event caused 99 students to gather inside Simulation Hall."]]}
            }),
            MockAi::Empty => json!({
                "statement_id": "fake-ai",
                "status": {"state": "SUCCEEDED"},
                "result": {"data_array": [[""]]}
            }),
        };
        (StatusCode::OK, Json(reply))
    } else {
        state.sql_calls.fetch_add(1, Ordering::SeqCst);
        assert!(statement.contains("`public`.`location_events`"));
        assert!(statement.contains("COUNT(*) AS observations"));
        assert!(!statement.contains("device_id"));
        assert!(!statement.contains("ROW_NUMBER()"));
        let parameters = request["parameters"].as_array().unwrap();
        assert!(parameters.iter().any(|p| p["name"] == "building" && p["value"] == "Simulation Hall"));
        assert!(parameters.iter().any(|p| p["value"] == "2026-11-14"));
        // The SQL query uses constructed dates; this fixture returns the same
        // synthetic 42 vs. 14 (+200%) observations used by offline tests.
        (StatusCode::OK, Json(fake_databricks_response(&demo_selection(), 42, 20)))
    }
}

/// Runs a genuine HTTP request through an Axum route with the production
/// `story_with_client` implementation, using a local fake Databricks service.
async fn call_story_endpoint(ai: Option<MockAi>) -> (Value, Arc<FakeWarehouse>, StatusCode) {
    let state = Arc::new(FakeWarehouse {
        ai_calls: AtomicUsize::new(0),
        sql_calls: AtomicUsize::new(0),
        prompts: Mutex::new(vec![]),
        ai: ai.unwrap_or(MockAi::Valid),
    });
    let databricks = Router::new()
        .route("/api/2.0/sql/statements", post(fake_statement))
        .with_state(Arc::clone(&state));
    let db_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let db_addr = db_listener.local_addr().unwrap();
    let db_task = tokio::spawn(async move { axum::serve(db_listener, databricks).await.unwrap() });

    // This config deliberately points only to the local fake server. Production
    // Config::from_env() still requires an HTTPS Databricks workspace host.
    let client = Arc::new(DbClient::new(Config {
        host: format!("http://{db_addr}"),
        token: "synthetic-never-real".into(),
        warehouse_id: "synthetic-warehouse".into(),
        catalog: "synthetic_catalog".into(),
        ai_endpoint: ai.map(|_| "synthetic-model".to_string()),
        timezone: chrono_tz::America::Chicago,
        min_observations: 5,
    }).unwrap());
    let api = Router::new().route(
        "/api/v1/buildings/{building}/story",
        get(move |Path(building): Path<String>, Query(query): Query<StoryQuery>| {
            let client = Arc::clone(&client);
            async move { story_with_client(building, query, demo_now(), &client).await }
        }),
    );
    let api_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let api_addr = api_listener.local_addr().unwrap();
    let api_task = tokio::spawn(async move { axum::serve(api_listener, api).await.unwrap() });
    let result = reqwest::Client::new().get(format!(
        "http://{api_addr}/api/v1/buildings/Simulation%20Hall/story?date=2026-11-14&time=14:30&weeks=8&window_minutes=15"
    )).send().await.unwrap();
    let status = result.status();
    let body: Value = result.json().await.unwrap();
    api_task.abort();
    db_task.abort();
    (body, state, status)
}

#[tokio::test]
async fn simulated_story_api_uses_ai_query_for_constructed_date() {
    let (body, mock, status) = call_story_endpoint(Some(MockAi::Valid)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["date"], "2026-11-14");
    assert_eq!(body["time_local"], "14:30");
    assert_eq!(body["current"]["observations"], 42);
    assert_eq!(body["metric"], "location_observations");
    assert_eq!(body["weekday_average"], 14.0);
    assert_eq!(body["difference_vs_weekday_average_pct"], 200.0);
    assert_eq!(body["story_source"], "databricks_ai_query");
    assert!(body["story"].as_str().unwrap().contains("200%"));
    assert_mobile_sentence(body["story"].as_str().unwrap());
    assert_eq!(mock.ai_calls.load(Ordering::SeqCst), 1);
    assert_eq!(mock.sql_calls.load(Ordering::SeqCst), 1);
    let prompts = mock.prompts.lock().unwrap();
    assert_eq!(prompts.len(), 1);
    assert!(prompts[0].contains("2026-11-14"));
    assert!(prompts[0].contains("14:30"));
    assert!(prompts[0].contains("42"));
    assert!(prompts[0].contains("200%"));
    assert!(prompts[0].contains("reported location activity"));
    println!("\n=== CONSTRUCTED DATE, AI SUCCESS ===\n{}", serde_json::to_string_pretty(&body).unwrap());
}

#[tokio::test]
async fn simulated_story_api_accepts_grounded_ai_paraphrase() {
    let (body, mock, status) = call_story_endpoint(Some(MockAi::Paraphrase)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["story"], "Simulation Hall is 200% higher than normal.");
    assert_eq!(body["story_source"], "databricks_ai_query");
    assert_eq!(mock.ai_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn simulated_story_api_falls_back_if_databricks_ai_fails() {
    let (body, mock, status) = call_story_endpoint(Some(MockAi::Failed)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["difference_vs_weekday_average_pct"], 200.0);
    assert_eq!(body["story_source"], "databricks_sql");
    assert_eq!(body["story"], "Simulation Hall is 200% busier than usual.");
    assert_eq!(mock.ai_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn simulated_story_api_rejects_ungrounded_ai_text() {
    let (body, mock, status) = call_story_endpoint(Some(MockAi::Ungrounded)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["story_source"], "databricks_sql");
    assert_eq!(body["story"], "Simulation Hall is 200% busier than usual.");
    assert_eq!(mock.ai_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn simulated_story_api_falls_back_on_empty_ai_text() {
    let (body, mock, status) = call_story_endpoint(Some(MockAi::Empty)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["story_source"], "databricks_sql");
    assert_eq!(mock.ai_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn simulated_story_api_without_ai_endpoint_is_still_available() {
    let (body, mock, status) = call_story_endpoint(None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["current"]["observations"], 42);
    assert_eq!(body["metric"], "location_observations");
    assert_eq!(body["story_source"], "databricks_sql");
    assert_eq!(mock.ai_calls.load(Ordering::SeqCst), 0);
    assert_eq!(mock.sql_calls.load(Ordering::SeqCst), 1);
}
