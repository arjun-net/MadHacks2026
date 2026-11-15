//! Opt-in live regression that proves /story and /prediction do NOT deduplicate
//! by device_id. Run scripts/seed_observation_count_demo.sql first in Lakebase.
//! Requires running Rust API and Databricks SQL warehouse.
use serde_json::Value;

#[tokio::test]
#[ignore = "needs a running backend, Databricks warehouse, and observation-count demo seed"]
async fn live_endpoints_count_rows_not_device_ids() -> Result<(), Box<dyn std::error::Error>> {
    let base = std::env::var("STORY_TEST_BASE_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:8000".to_owned());
    let client = reqwest::Client::new();
    for (route, date, expected) in [
        ("story", "2026-11-14", 42_i64),
        ("prediction", "2026-11-21", 14_i64),
    ] {
        let mut url = reqwest::Url::parse(&base)?;
        {
            let mut p = url.path_segments_mut().expect("STORY_TEST_BASE_URL must be a base URL");
            p.clear().extend(&["api", "v1", "buildings", "__DEMO__ Observation Lab", route]);
        }
        url.query_pairs_mut()
            .append_pair("date", date)
            .append_pair("time", "14:30")
            .append_pair("weeks", "8")
            .append_pair("window_minutes", "15");
        let response = client.get(url).send().await?;
        let status = response.status();
        let raw = response.text().await?;
        assert!(status.is_success(), "{route}: HTTP {status}: {raw}");
        let value: Value = serde_json::from_str(&raw)?;
        assert_eq!(value["metric"], "location_observations", "{route}: {raw}");
        if route == "story" {
            assert_eq!(value["current"]["observations"], expected,
                "42 rows share one ID; if null, confirm branch, catalog, date, and threshold: {raw}");
            assert_eq!(value["weekday_average"], 14.0);
            assert_eq!(value["difference_vs_weekday_average_pct"], 200.0);
        } else {
            assert_eq!(value["prediction"]["rounded_observations"], expected,
                "Expected normal baseline of 14 observations: {raw}");
            assert_eq!(value["outliers_excluded"], 1);
        }
        println!("=== {route} ===\n{}", serde_json::to_string_pretty(&value)?);
    }
    Ok(())
}
