//! Live smoke test; requires the Rust backend, a Databricks SQL warehouse,
//! and optional synthetic data in Lakebase. No credentials are printed.
use serde_json::Value;

#[tokio::test]
#[ignore = "Calls a live Databricks SQL warehouse; requires seeded sample history"]
async fn live_historical_prediction_for_constructed_date() -> Result<(), Box<dyn std::error::Error>> {
    let base = std::env::var("PREDICTION_TEST_API_URL")
        .unwrap_or_else(|_| "http://localhost:8000".to_owned());
    let url = format!("{}/api/v1/buildings/__DEMO__%20Forecast%20Hall/prediction", base.trim_end_matches('/'));
    let response = reqwest::Client::new()
        .get(url)
        .query(&[("date", "2026-11-21"), ("time", "14:30"), ("weeks", "8")])
        .send().await?;
    let status = response.status();
    let body: Value = response.json().await?;
    assert!(status.is_success(), "HTTP {status}: {}", body.get("detail").and_then(Value::as_str).unwrap_or("no details"));
    assert_eq!(body["target_date"], "2026-11-21");
    assert_eq!(body["source"], "databricks_sql");
    assert_eq!(body["prediction"]["status"], "available", "seed the demo dataset before testing: {body}");
    assert_eq!(body["prediction"]["rounded_reporting_devices"], 14);
    assert_eq!(body["outliers_excluded"], 1);
    let summary = body["summary"].as_str().expect("mobile prediction summary");
    assert!(summary.chars().count() <= 96, "summary too long: {summary}");
    assert_eq!(summary.chars().filter(|&c| c == '.').count(), 1);
    assert!(summary.ends_with('.'));
    println!("{}", serde_json::to_string_pretty(&body)?);
    Ok(())
}
