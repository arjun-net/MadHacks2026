//! Optional live smoke test for the real Rust API and Databricks SQL/AI.
//! Requires a running server and previously seeded `__DEMO__ Story Lab` data.
//! Unlike src/story_fixture_tests.rs, this can incur Databricks SQL / AI charges.

use serde_json::Value;

#[tokio::test]
#[ignore = "requires a running API, Lakebase seed data, and Databricks SQL; optionally AI"]
async fn real_story_endpoint_with_constructed_date() -> Result<(), Box<dyn std::error::Error>> {
    // Fixed historical date/time gives reproducible comparisons. The provided
    // synthetic SQL seed should contain 42 devices on this Saturday and 14
    // devices on average on the four previous Saturdays.
    let base = std::env::var("STORY_TEST_BASE_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:8000".into());
    let mut url = reqwest::Url::parse(&base)?;
    {
        // Let the URL library encode the building name as a single path segment.
        let mut path = url.path_segments_mut().expect("STORY_TEST_BASE_URL must be a base HTTP URL");
        path.clear().extend(&["api", "v1", "buildings", "__DEMO__ Story Lab", "story"]);
    }
    url.query_pairs_mut()
        .append_pair("date", "2026-11-14")
        .append_pair("time", "14:30")
        .append_pair("weeks", "8")
        .append_pair("window_minutes", "15");

    let response = reqwest::Client::new().get(url).send().await?;
    let status = response.status();
    let raw = response.text().await?;
    assert!(status.is_success(), "Story endpoint returned HTTP {status}: {raw}");
    let story: Value = serde_json::from_str(&raw)?;
    assert_eq!(story["building"], "__DEMO__ Story Lab");
    assert_eq!(story["date"], "2026-11-14");
    assert_eq!(story["time_local"], "14:30");
    assert_eq!(story["current"]["reporting_devices"], 42,
        "Seed the synthetic example data in your Lakebase branch first");
    assert_eq!(story["weekday_average"], 14.0);
    assert_eq!(story["difference_vs_weekday_average_pct"], 200.0);
    let mobile_story = story["story"].as_str().expect("mobile story");
    assert!(mobile_story.chars().count() <= 96, "story too long: {mobile_story}");
    assert_eq!(mobile_story.chars().filter(|&c| c == '.').count(), 1);
    assert!(mobile_story.ends_with('.'));

    let source = story["story_source"].as_str().unwrap_or("");
    assert!(source == "databricks_sql" || source == "databricks_ai_query");
    if std::env::var("STORY_TEST_REQUIRE_AI").as_deref() == Ok("1") {
        assert_eq!(source, "databricks_ai_query",
            "DATABRICKS_AI_ENDPOINT must be set and the model must return verified text");
    }
    println!("\n=== LIVE DATABRICKS STORY (2026-11-14) ===\n{}",
        serde_json::to_string_pretty(&story)?);
    Ok(())
}
