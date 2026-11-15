//! Opt-in end-to-end test for the Rust /story API, Databricks SQL, and optional AI.
//!
//! Works with both a fixed synthetic fixture and existing *real* observations.
//! Real data is never expected to contain exactly 42 observations or a 200% spike.
//!
//! Example for an existing building (PowerShell):
//!   $env:STORY_TEST_BUILDING = "morgridge_institute"
//!   $env:STORY_TEST_DATE = "2026-11-15"
//!   $env:STORY_TEST_TIME = "02:30"
//!   $env:STORY_TEST_WINDOW_MINUTES = "15"
//!   $env:STORY_TEST_REQUIRE_AI = "1"
//!   cargo test --test live_story_ai -- --ignored --nocapture
//!
//! The date and clock time are campus-local (CAMPUS_TIMEZONE on the server).
//! Requires a running backend, a configured Databricks SQL warehouse, and
//! observations for the exact building and time window. May incur charges.

use serde_json::Value;
use std::env;

fn nonempty_var(name: &str) -> Option<String> {
    env::var(name).ok().map(|value| value.trim().to_owned()).filter(|value| !value.is_empty())
}

#[tokio::test]
#[ignore = "needs a running API and Databricks SQL; optional AI model"]
async fn real_story_endpoint_with_constructed_date() -> Result<(), Box<dyn std::error::Error>> {
    let building = nonempty_var("STORY_TEST_BUILDING")
        .unwrap_or_else(|| "__DEMO__ Story Lab".to_owned());
    let demo_fixture = building == "__DEMO__ Story Lab";

    // Real data needs its own known date and time; otherwise an unrelated
    // hardcoded fixture window would always return no_data.
    let date = nonempty_var("STORY_TEST_DATE")
        .or_else(|| demo_fixture.then(|| "2026-11-14".to_owned()))
        .expect("Set STORY_TEST_DATE=YYYY-MM-DD for a real building (campus-local date)");
    let time = nonempty_var("STORY_TEST_TIME")
        .or_else(|| demo_fixture.then(|| "14:30".to_owned()))
        .expect("Set STORY_TEST_TIME=HH:MM for a real building (24-hour campus-local time)");
    let weeks = nonempty_var("STORY_TEST_WEEKS").unwrap_or_else(|| "8".to_owned());
    let window_minutes = nonempty_var("STORY_TEST_WINDOW_MINUTES")
        .unwrap_or_else(|| "15".to_owned());

    let base = nonempty_var("STORY_TEST_BASE_URL")
        .unwrap_or_else(|| "http://127.0.0.1:8000".to_owned());
    let mut url = reqwest::Url::parse(&base)?;
    {
        let mut segments = url.path_segments_mut()
            .expect("STORY_TEST_BASE_URL must be an HTTP(S) base URL");
        segments.clear().extend(&["api", "v1", "buildings", &building, "story"]);
    }
    url.query_pairs_mut()
        .append_pair("date", &date)
        .append_pair("time", &time)
        .append_pair("weeks", &weeks)
        .append_pair("window_minutes", &window_minutes);

    println!("Querying {building:?} on {date} at {time} (±{window_minutes} min)");
    let response = reqwest::Client::new().get(url.clone()).send().await?;
    let http_status = response.status();
    let body = response.text().await?;
    assert!(http_status.is_success(), "GET {url}: HTTP {http_status}: {body}");

    let story: Value = serde_json::from_str(&body)?;
    // Print the response *before* assertions, so no_data/suppressed cases can be diagnosed.
    println!("\n=== LIVE DATABRICKS STORY ===\n{}", serde_json::to_string_pretty(&story)?);

    assert_eq!(story["building"].as_str(), Some(building.as_str()));
    assert_eq!(story["date"].as_str(), Some(date.as_str()));
    assert_eq!(story["time_local"].as_str(), Some(time.as_str()));
    assert_eq!(story["metric"], "location_observations",
        "The API may be running an older binary; restart with cargo run --bin madhacks-backend");

    let activity_status = story["current"]["status"].as_str().unwrap_or("missing");
    assert_eq!(activity_status, "available",
        "No visible observations for {building:?} on {date} at {time} ±{window_minutes} min (status={activity_status}). \
         For no_data, inspect the EXACT building name and recorded local timestamps in Lakebase, \
         then set STORY_TEST_DATE/TIME accordingly. For suppressed, set STORY_MIN_OBSERVATIONS=1 \
         on the API server in a development environment and restart it.");

    let observations = story["current"]["observations"].as_i64()
        .expect("available response must contain current.observations as an integer");
    assert!(observations > 0, "Expected at least one observation, got {observations}");
    assert_eq!(story["current"]["reporting_devices"].as_i64(), Some(observations),
        "The legacy alias should match the raw observation count");

    // Optional independent check: provide a COUNT(*) result from Lakebase/Databricks SQL.
    // Without this, the test validates the response contract and data availability,
    // not the correctness of counting SQL against an independent database query.
    if let Some(expected) = nonempty_var("STORY_TEST_EXPECTED_OBSERVATIONS") {
        let expected = expected.parse::<i64>()?;
        assert_eq!(observations, expected,
            "API count differs from the independently queried COUNT(*) for this window");
    } else if demo_fixture && date == "2026-11-14" && time == "14:30" && window_minutes == "15" {
        assert_eq!(observations, 42, "The documented demo fixture should contain 42 rows");
        assert_eq!(story["weekday_average"], 14.0);
        assert_eq!(story["difference_vs_weekday_average_pct"], 200.0);
    }

    let mobile_story = story["story"].as_str().expect("mobile story must be a string");
    assert!(!mobile_story.is_empty());
    assert!(mobile_story.chars().count() <= 96, "mobile story too long: {mobile_story}");
    assert!(!mobile_story.contains('\n') && mobile_story.ends_with('.'),
        "mobile story must be a one-line, complete sentence: {mobile_story}");

    let source = story["story_source"].as_str().unwrap_or("");
    assert!(source == "databricks_sql" || source == "databricks_ai_query",
        "unexpected story source: {source}");
    if nonempty_var("STORY_TEST_REQUIRE_AI").as_deref() == Some("1") {
        assert_eq!(source, "databricks_ai_query",
            "AI text was not accepted. Check API server logs for model errors or validator rejection; \
             ensure DATABRICKS_AI_ENDPOINT is configured on the RUNNING API server");
    }

    println!("PASS: {observations} raw location observations; story_source={source}; story={mobile_story}");
    Ok(())
}
